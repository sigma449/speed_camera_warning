import json

import pytest

from ci_contract_helpers import bash, fake_simulator


def run_liveness(tmp_path, script, scenario):
    env = fake_simulator(tmp_path, scenario)
    common = tmp_path / "scripts" / "ci" / "simulator-checks.sh"
    if common.exists():
        function = "source scripts/ci/simulator-checks.sh"
    else:
        source = (tmp_path / "scripts" / "ci" / script).read_text(encoding="utf-8")
        function = "assert_running() {" + source.split("assert_running() {", 1)[1].split("\n}", 1)[0] + "\n}"
    command = (
        'set -euo pipefail\nUDID=test-device\nBUNDLE_ID=tw.speedcammap.app\n'
        'APP_PID=1001\nOUT=screenshots\nmkdir -p "$OUT"\n'
        'xcrun simctl launch "$UDID" "$BUNDLE_ID"\n'
        'xcrun simctl io "$UDID" screenshot "$OUT/proof-is-not-liveness.png"\n'
        + function + '\nassert_running "契約測試"\n')
    return bash("-c", command, cwd=tmp_path, env=env)


@pytest.mark.parametrize("scenario", [
    "dies", pytest.param("old-pid", marks=pytest.mark.slow),
    pytest.param("old-time", marks=pytest.mark.slow),
    pytest.param("log-error", marks=pytest.mark.slow),
    pytest.param("unfinished", marks=pytest.mark.slow), "replaced",
    pytest.param("bad-time", marks=pytest.mark.slow),
    pytest.param("old-offset", marks=pytest.mark.slow),
    pytest.param("bad-json", marks=pytest.mark.slow),
])
def test_stress_rejects_missing_current_process_completion(tmp_path, scenario):
    env = fake_simulator(tmp_path, scenario)
    result = bash("scripts/ci/search-stress.sh", "SpeedCam.app", "2", cwd=tmp_path, env=env)
    assert result.returncode != 0, result.stdout
    assert (tmp_path / "screenshots" / "stress-1.png").exists()


@pytest.mark.parametrize("scenario", ["good", "large", "transient", "offset-time"])
@pytest.mark.slow
def test_stress_accepts_current_round_without_pipefail_false_negative(tmp_path, scenario):
    env = fake_simulator(tmp_path, scenario)
    result = bash("scripts/ci/search-stress.sh", "SpeedCam.app", "2", cwd=tmp_path, env=env)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "0／2" in result.stdout


@pytest.mark.slow
def test_stress_separates_successful_query_json_from_simulator_stderr(tmp_path):
    env = fake_simulator(tmp_path, "stderr-warning")
    result = bash("scripts/ci/search-stress.sh", "SpeedCam.app", "2", cwd=tmp_path, env=env)
    assert result.returncode == 0, result.stdout + result.stderr
    directory = tmp_path / "screenshots"
    rows = json.loads((directory / "search-1.json").read_text(encoding="utf-8"))
    assert rows[0]["eventMessage"] == "typing test finished"
    assert "getpwuid_r" in (directory / "search-1-query-stderr.txt").read_text(encoding="utf-8")


@pytest.mark.parametrize("scenario", ["stderr-warning-unfinished", "empty-log"])
def test_stress_keeps_query_evidence_without_promoting_missing_completion(tmp_path, scenario):
    env = fake_simulator(tmp_path, scenario)
    result = bash("scripts/ci/search-stress.sh", "SpeedCam.app", "1", cwd=tmp_path, env=env)
    assert result.returncode != 0, result.stdout + result.stderr
    assert "完成證據" in result.stdout
    assert (tmp_path / "screenshots" / "search-1-query-status.txt").read_text(encoding="utf-8").strip() == "0"
    if scenario == "empty-log":
        assert "stdout=0 bytes" in result.stdout + result.stderr
    else:
        assert "getpwuid_r" in result.stdout + result.stderr


@pytest.mark.parametrize("entry", [
    pytest.param("screenshots.sh", marks=pytest.mark.slow), "ios15-run.sh",
])
def test_screenshot_search_entries_accept_json_with_separate_query_diagnostics(tmp_path, entry):
    env = fake_simulator(tmp_path, "stderr-warning")
    result = bash(f"scripts/ci/{entry}", "SpeedCam.app", "search", cwd=tmp_path, env=env)
    assert result.returncode == 0, result.stdout + result.stderr
    queries = list((tmp_path / "screenshots").glob("search-*.json"))
    assert len(queries) == 1
    assert json.loads(queries[0].read_text(encoding="utf-8"))[0]["eventMessage"] == "typing test finished"


def test_failed_search_query_retains_its_real_exit_status(tmp_path):
    env = fake_simulator(tmp_path, "log-error")
    result = bash("scripts/ci/search-stress.sh", "SpeedCam.app", "1", cwd=tmp_path, env=env)
    assert result.returncode != 0
    assert "exit=74 stdout=0 bytes" in result.stdout
    assert "simctl 無法讀取 log" in result.stderr
    assert (tmp_path / "screenshots" / "search-1-query-status.txt").read_text(encoding="utf-8").strip() == "74"


def test_stress_rejects_a_process_that_stops_after_the_completion_query(tmp_path):
    env = fake_simulator(tmp_path, "query-then-dies")
    result = bash("scripts/ci/search-stress.sh", "SpeedCam.app", "1", cwd=tmp_path, env=env)
    assert result.returncode != 0
    assert "已停止或被替換" in result.stdout
    rows = json.loads((tmp_path / "screenshots" / "search-1.json").read_text(encoding="utf-8"))
    assert rows[0]["eventMessage"] == "typing test finished"


@pytest.mark.parametrize("runs", ["0", "-1", "abc", "1.5"])
def test_stress_rejects_invalid_round_count(tmp_path, runs):
    env = fake_simulator(tmp_path, "good")
    result = bash("scripts/ci/search-stress.sh", "SpeedCam.app", runs, cwd=tmp_path, env=env)
    assert result.returncode != 0, result.stdout


@pytest.mark.parametrize("script", ["screenshots.sh", "ios15-run.sh"])
@pytest.mark.parametrize("scenario", ["unknown", "dies", "replaced"])
def test_screenshot_is_not_proof_of_process_liveness(tmp_path, script, scenario):
    result = run_liveness(tmp_path, script, scenario)
    assert result.returncode != 0, result.stdout
    assert list((tmp_path / "screenshots").glob("*.png")), "失敗仍須保留診斷圖片"


@pytest.mark.parametrize("script", ["screenshots.sh", "ios15-run.sh"])
def test_transient_liveness_query_is_retried(tmp_path, script):
    result = run_liveness(tmp_path, script, "transient")
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads((tmp_path / "sim-state.json").read_text())["queries"] == 3
