import hashlib
import json
import subprocess

import pytest

from ci_contract_helpers import ROOT, bash, shell_workspace, tool
from test_additional_sources import douliu_milepost_index
from test_data_release_contract import production_input, real_build, load_bundle
from test_workflow_contract import script


@pytest.fixture
def acceptance_evidence(production_input, monkeypatch, tmp_path):
    directory = tmp_path / "summary"
    bundle = load_bundle()
    real_build(directory / "ci-data", production_input)
    with (directory / "ci-data" / "data-build.log").open("a", encoding="utf-8") as log:
        log.write("[警告] 合成回退案例：13940 改用 repo 官方快照（非即時）\n")
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    manifest = bundle.create_manifest(directory / "ci-data", commit)
    sha = bundle.sha256(directory / "ci-data" / "manifest.json")
    module = script("ci-results.py")
    needs = {job: {"result": "success"} for job in module.FULL_JOBS}
    for job in module.FULL_RECORDS:
        destination = directory / "evidence" / job
        destination.mkdir(parents=True)
        (destination / "job-result.json").write_text(json.dumps({
            "job": job, "status": "success", "commit": commit, "manifestSHA256": sha,
            "screenshots": "full", "acceptance": True,
        }), encoding="utf-8")
    for suite in ("1108", "1107", "tunnels"):
        (directory / "evidence" / f"replay-{suite}" / "checker-result.json").write_text(json.dumps({
            "suite": suite, "conclusion": "success", "producerExit": 0, "errors": [],
        }), encoding="utf-8")
    (directory / "evidence" / "ipa" / "ipa-manifest.json").write_text(json.dumps({
        "commit": commit, "manifestSHA256": sha, "dataSHA256": manifest["hashes"]["cameras.json"],
        "ipaSHA256": "f" * 64,
    }), encoding="utf-8")
    monkeypatch.setenv("COMMIT", commit)
    monkeypatch.setenv("MANIFEST_SHA", sha)
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(tmp_path / "step-summary.md"))
    monkeypatch.setenv("PYTHONUTF8", "1")
    return module, directory, needs


@pytest.mark.parametrize("fault", ["none", "skipped", "checker", "missing-checker", "duplicate-checker",
                                   "commit", "bundle", "ipa-metadata", "standalone"])
def test_summary_never_promotes_missing_or_failed_gates(acceptance_evidence, monkeypatch, fault):
    module, directory, needs = acceptance_evidence
    if fault == "skipped":
        needs["ios15"]["result"] = "skipped"
    if fault in ("checker", "missing-checker", "duplicate-checker"):
        path = directory / "evidence" / "replay-1108" / "checker-result.json"
        report = json.loads(path.read_text(encoding="utf-8"))
        if fault == "checker":
            report["conclusion"] = "failure"
            report["errors"] = ["導航 99/100"]
            path.write_text(json.dumps(report), encoding="utf-8")
        elif fault == "missing-checker":
            path.unlink()
        else:
            copy = directory / "extra"
            copy.mkdir()
            (copy / path.name).write_text(json.dumps(report), encoding="utf-8")
    if fault == "commit":
        path = directory / "evidence" / "core-tests" / "job-result.json"
        row = json.loads(path.read_text(encoding="utf-8"))
        row["commit"] = "0" * 40
        path.write_text(json.dumps(row), encoding="utf-8")
    if fault == "standalone":
        path = directory / "evidence" / "ipa" / "job-result.json"
        row = json.loads(path.read_text(encoding="utf-8"))
        row["acceptance"] = False
        path.write_text(json.dumps(row), encoding="utf-8")
    if fault == "bundle":
        with (directory / "ci-data" / "cameras.json").open("ab") as output:
            output.write(b"changed")
    if fault == "ipa-metadata":
        path = directory / "evidence" / "ipa" / "ipa-manifest.json"
        row = json.loads(path.read_text(encoding="utf-8"))
        row["dataSHA256"] = "0" * 64
        path.write_text(json.dumps(row), encoding="utf-8")
    monkeypatch.setenv("NEEDS_JSON", json.dumps(needs))
    assert module.main(["summary", "--scope", "acceptance", "--directory", str(directory)]) == (0 if fault == "none" else 1)
    report = json.loads((directory / "acceptance-result.json").read_text(encoding="utf-8"))
    assert report["conclusion"] == ("success" if fault == "none" else "failure")
    assert report["ipaArtifact"] == ("SpeedCam-ipa" if fault == "none" else None)


def test_docs_only_summary_does_not_claim_build_or_replay(monkeypatch, tmp_path, capsys):
    module = script("ci-results.py")
    monkeypatch.setenv("COMMIT", "a" * 40)
    monkeypatch.setenv("NEEDS_JSON", json.dumps({
        "changes": {"result": "success", "outputs": {"full": "false"}},
        "data": {"result": "skipped"}, "tests": {"result": "skipped"}, "ios-build": {"result": "skipped"},
    }))
    assert module.main(["summary", "--scope", "ci", "--directory", str(tmp_path)]) == 0
    assert "只有文件變更" in capsys.readouterr().out


def test_weekly_pr_body_preserves_multisource_license_counts_and_fallback(acceptance_evidence, monkeypatch):
    _, directory, _ = acceptance_evidence
    monkeypatch.setenv("PYTHONIOENCODING", "utf-8")
    manifest = directory / "ci-data" / "manifest.json"
    output = directory / "body.md"
    module = script("data-pr-body.py")
    commit = json.loads(manifest.read_text(encoding="utf-8"))["commit"]
    assert module.main(["--directory", str(manifest.parent), "--output", str(output),
                        "--commit", commit, "--manifest-sha", hashlib.sha256(manifest.read_bytes()).hexdigest()]) == 0
    body = output.read_text(encoding="utf-8")
    assert "ODbL" in body and "地方公告" in body and "斗六" in body
    assert "| douliu-mobile |" in body and "13940 改用 repo 官方快照" in body
    assert "507 點／72" in body and "不是只有警政署" in body


def test_failed_xcode_producer_is_nonzero_and_keeps_complete_log(tmp_path):
    tools, environment = shell_workspace(tmp_path)
    for name in ("brew", "xcodegen"):
        tool(tools, name, "exit 0")
    tool(tools, "xcodebuild", "printf 'FULL-FIRST\\nwarning: middle\\nerror: expected\\nFULL-LAST\\n'; exit 42")
    environment.update(CI_TASK="ios26", CI_LABEL="build-contract", CAPTURE_SCENARIOS="none")
    result = bash("scripts/ci/macos-job.sh", cwd=tmp_path, env=environment)
    assert result.returncode == 42, result.stdout + result.stderr
    log = (tmp_path / "build" / "evidence" / "build-contract" / "build.log").read_text(encoding="utf-8")
    assert log.startswith("FULL-FIRST\n") and log.endswith("FULL-LAST\n") and "error: expected" in log


def test_diagnostic_timeout_keeps_partial_output(monkeypatch, tmp_path):
    module = script("collect-diagnostics.py")
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(module.Path, "home", staticmethod(lambda: tmp_path))
    monkeypatch.setattr(module.platform, "platform", lambda: "fixture")
    (tmp_path / "screenshots").mkdir()
    (tmp_path / "screenshots" / "simulator-udid.txt").write_text("fixture-udid", encoding="utf-8")
    commands = []

    def run(command, **kwargs):
        commands.append(command)
        if command[0] == "xcodebuild":
            raise subprocess.TimeoutExpired(command, 90, output=b"PARTIAL-FIRST\nPARTIAL-LAST\n")
        return subprocess.CompletedProcess(command, 0, stdout=b"complete\n")

    monkeypatch.setattr(module.subprocess, "run", run)
    assert module.main(["--label", "timeout-contract"]) == 0
    directory = tmp_path / "build" / "evidence" / "timeout-contract"
    log = (directory / "xcode-version.log").read_text(encoding="utf-8")
    assert log.startswith("PARTIAL-FIRST\nPARTIAL-LAST\n") and "timed out" in log
    statuses = json.loads((directory / "diagnostic-status.json").read_text(encoding="utf-8"))
    assert "timed out" in statuses["xcode-version"] and statuses["simulator-list"] == 0
    app_query = next(command for command in commands if "show" in command)
    assert app_query[3] == "fixture-udid" and "--info" in app_query and "--debug" in app_query
    assert (directory / "app-log.log").read_bytes() == b"complete\n"
