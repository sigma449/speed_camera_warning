import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

import pytest
import yaml

from ci_contract_helpers import ROOT

WORKFLOWS = ROOT / ".github" / "workflows"


def workflow(name):
    path = WORKFLOWS / name
    assert path.exists(), f"缺少共用 workflow：{name}"
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def events(document):
    return document.get("on", document.get(True, {}))


def script(name):
    path = ROOT / "scripts" / "ci" / name
    assert path.exists(), f"缺少正式 CI 入口：{name}"
    spec = importlib.util.spec_from_file_location(name.removesuffix(".py").replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.mark.parametrize("paths,expected", [
    (["README.md", "docs/SETUP.md", "CLAUDE.md"], False),
    (["docs/ci.md", "SpeedCam/Resources/cameras.json"], True),
    (["scripts/ci/note.md"], True),
    (["project.yml"], True),
    (["Packages/SpeedCamCore/Sources/SpeedCamCore/Models.swift"], True),
    (["data-pipeline/speedcam_data/sources.py"], True),
    (["Shared/SpeedCamActivityView.swift"], True),
    ([".github/workflows/ci.yml"], True),
    (["new-unknown-file"], True),
    ([], True),
])
def test_cross_layer_changes_cannot_skip_ios(paths, expected):
    assert script("classify-changes.py").needs_full_ci(paths) is expected


@pytest.mark.parametrize("path,profile", [
    ("Shared/SpeedCamActivityView.swift", "full"),
    ("SpeedCam/Resources/cameras.json", "full"),
    ("Packages/SpeedCamCore/Tests/SpeedCamCoreTests/ModelsTests.swift", "smoke"),
])
def test_ui_or_resource_changes_expand_capture_profile(path, profile):
    assert script("classify-changes.py").capture_profile([path]) == profile
    caller = workflow("ci.yml")["jobs"]["ios-build"]["with"]["screenshots"]
    assert "needs.changes.outputs.screenshots" in caller

def test_manual_full_override_and_classifier_output(tmp_path):
    module = script("classify-changes.py")
    paths = tmp_path / "paths.json"
    paths.write_text(json.dumps(["docs/SETUP.md"]), encoding="utf-8")
    output = tmp_path / "output.txt"
    environment = dict(os.environ, GITHUB_OUTPUT=str(output), PYTHONUTF8="1")
    for override in ([], ["--full"]):
        output.write_text("", encoding="utf-8")
        result = subprocess.run([sys.executable, module.__file__, "--paths-json", str(paths), *override],
                                capture_output=True, encoding="utf-8", env=environment)
        assert result.returncode == 0, result.stdout + result.stderr
        assert f"full={'true' if override else 'false'}" in output.read_text(encoding="utf-8")


def test_all_workflow_yaml_and_local_call_inputs_are_valid():
    documents = {path.name: workflow(path.name) for path in WORKFLOWS.glob("*.yml")}
    for name, document in documents.items():
        assert document.get("jobs"), name
        for job in document["jobs"].values():
            used = job.get("uses", "")
            if not used.startswith("./.github/workflows/"):
                continue
            child = documents[Path(used).name]
            declared = events(child)["workflow_call"].get("inputs", {})
            supplied = job.get("with", {})
            assert supplied.keys() <= declared.keys(), (name, supplied.keys() - declared.keys())
            assert {key for key, value in declared.items() if value.get("required")} <= supplied.keys(), name
            assert set(job.get("needs", [])) <= document["jobs"].keys(), name


def test_registered_ipa_entry_can_start_branch_acceptance():
    document = workflow("build-ipa.yml")
    assert events(document)["workflow_dispatch"]["inputs"]["acceptance"]["type"] == "boolean"
    acceptance = document["jobs"]["acceptance"]
    assert acceptance["uses"] == "./.github/workflows/_acceptance.yml"
    assert "inputs.acceptance" in acceptance["if"]


def test_only_one_linux_data_bundle_is_used_by_macos_and_tests():
    prepare = workflow("_prepare-data.yml")
    assert prepare["jobs"]["prepare"]["runs-on"] == "ubuntu-latest"
    assert "manifest-sha" in events(prepare)["workflow_call"]["outputs"]
    for name in ("_macos.yml", "_tests.yml"):
        document = workflow(name)
        for job in document["jobs"].values():
            steps = job["steps"]
            assert any(step.get("uses", "").startswith("actions/download-artifact@") for step in steps)
            runs = "\n".join(step.get("run", "") for step in steps)
            assert "data-bundle.py verify" in runs
            assert "build_cameras.py" not in runs
            assert any(step.get("with", {}).get("ref") == "${{ github.sha }}" for step in steps)


def test_ios_waits_for_both_linux_test_jobs():
    document = workflow("ci.yml")
    assert "tests" in document["jobs"]["ios-build"]["needs"]
    tests = workflow("_tests.yml")["jobs"]
    assert {"core-tests", "pipeline-tests"} <= tests.keys()
    assert "SPEEDCAM_CURRENT_DATABASE_REQUIRED" in json.dumps(tests["core-tests"])
    assert "probe-deadline.swift" in json.dumps(tests["core-tests"])
    assert "changes" in document["jobs"]["data"]["needs"]


def test_ci_python_job_overrides_local_fast_selection():
    steps = workflow("_tests.yml")["jobs"]["pipeline-tests"]["steps"]
    command = next(step["run"] for step in steps if "python -m pytest" in step.get("run", ""))
    arguments = shlex.split(command)
    assert arguments[arguments.index("-m", arguments.index("pytest")) + 1] == "slow or not slow"
    assert "data-pipeline" in arguments


def test_acceptance_ipa_requires_every_independent_gate():
    jobs = workflow("_acceptance.yml")["jobs"]
    required = {"data", "tests", "ios26", "ios15", "replay-1108", "replay-1107", "replay-tunnels"}
    assert required <= set(jobs["ipa"]["needs"])
    assert "always()" not in jobs["ipa"].get("if", "")
    for name in ("ios26", "ios15", "replay-1108", "replay-1107", "replay-tunnels"):
        assert {"data", "tests"} <= set(jobs[name]["needs"])
    assert "always()" in jobs["summary"]["if"]
    assert required | {"ipa"} <= set(jobs["summary"]["needs"])
    assert len({jobs[name]["with"]["cases"] for name in ("replay-1108", "replay-1107", "replay-tunnels")}) == 3


def test_manual_workflows_have_non_colliding_concurrency():
    for name in ("build-ipa.yml", "route-probe.yml", "ios15-test.yml", "search-stress.yml", "data.yml"):
        document = workflow(name)
        assert "github.ref" in document["concurrency"]["group"], name
    group = workflow("route-probe.yml")["concurrency"]["group"]
    assert "inputs.cases" in group and "inputs.mode" in group
    assert "tag" in str(workflow("build-ipa.yml")["concurrency"]["cancel-in-progress"])
    assert "concurrency" not in workflow("_macos.yml"), "子 workflow 不可與 caller 互相取消"


def test_exploratory_plans_do_not_wait_for_camera_downloads():
    jobs = workflow("route-probe.yml")["jobs"]
    assert jobs["data"]["if"] == "inputs.mode == 'replay'"
    assert "inputs.mode != 'replay'" in jobs["probe"]["if"]
    assert "needs.data.result == 'success'" in jobs["probe"]["if"]
    steps = workflow("_macos.yml")["jobs"]["run"]["steps"]
    download = next(step for step in steps if step.get("uses", "").startswith("actions/download-artifact@"))
    assert "inputs.mode == 'replay'" in download["if"]


def test_artifacts_survive_failure_and_base64_is_opt_in():
    document = workflow("_macos.yml")
    assert events(document)["workflow_call"]["inputs"]["print-screenshots"]["default"] is False
    steps = document["jobs"]["run"]["steps"]
    evidence = next(step for step in steps if step.get("with", {}).get("name") == "${{ inputs.label }}-evidence")
    assert "always()" in evidence["if"]
    print_step = next(step for step in steps if "print-screenshots.sh" in step.get("run", ""))
    assert "inputs.print-screenshots" in print_step["if"]
    assert any("ci-results.py record" in step.get("run", "") and "always()" in step.get("if", "") for step in steps)


def test_weekly_pr_uses_current_multisource_report():
    steps = workflow("data.yml")["jobs"]["refresh"]["steps"]
    pr = next(step for step in steps if step.get("uses", "").startswith("peter-evans/create-pull-request@"))
    assert pr["with"].get("body-path") == "build/data-pr-body.md"
    assert any("data-pr-body.py" in step.get("run", "") for step in steps)
