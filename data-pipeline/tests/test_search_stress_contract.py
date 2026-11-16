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


@pytest.mark.parametrize("scenario", ["dies", "old-pid", "old-time", "log-error", "unfinished", "replaced"])
def test_stress_rejects_missing_current_process_completion(tmp_path, scenario):
    env = fake_simulator(tmp_path, scenario)
    result = bash("scripts/ci/search-stress.sh", "SpeedCam.app", "2", cwd=tmp_path, env=env)
    assert result.returncode != 0, result.stdout
    assert (tmp_path / "screenshots" / "stress-1.png").exists()


@pytest.mark.parametrize("scenario", ["good", "large", "transient"])
def test_stress_accepts_current_round_without_pipefail_false_negative(tmp_path, scenario):
    env = fake_simulator(tmp_path, scenario)
    result = bash("scripts/ci/search-stress.sh", "SpeedCam.app", "2", cwd=tmp_path, env=env)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "0／2" in result.stdout


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
