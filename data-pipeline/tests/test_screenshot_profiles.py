import pytest

from ci_contract_helpers import ROOT, bash, fake_simulator, shell_workspace


@pytest.mark.parametrize("profile,entry", [
    pytest.param("smoke", "screenshots.sh", marks=pytest.mark.slow),
    ("smoke", "ios15-run.sh"),
    pytest.param("full", "screenshots.sh", marks=pytest.mark.slow),
    pytest.param("full", "ios15-run.sh", marks=pytest.mark.slow),
    ("none", "screenshots.sh"), ("none", "ios15-run.sh"),
    ("invalid", "screenshots.sh"), ("invalid", "ios15-run.sh"),
])
def test_real_screenshot_entry_honors_selected_profile(tmp_path, entry, profile):
    environment = fake_simulator(tmp_path, "good")
    result = bash(f"scripts/ci/{entry}", "Fake.app", profile, cwd=tmp_path, env=environment,
                  timeout=180 if profile == "full" else 60)
    images = list((tmp_path / "screenshots").glob("*.png"))
    assert result.returncode == (64 if profile == "invalid" else 0), result.stdout + result.stderr
    assert "未取得畫面狀態" not in result.stdout, result.stdout
    if profile == "smoke":
        assert 1 <= len(images) <= 5, "日常 smoke 不能仍拍全套"
        assert not any("-route-" in path.name or "3d" in path.name for path in images)
    elif profile == "full":
        assert len(images) > 5
        assert not any(path.name.startswith(("35-", "36-", "37-", "38-", "ios15-14-", "ios15-16-")) for path in images)
        prefix = "ios15-17-user-camera" if entry == "ios15-run.sh" else "47-user-camera"
        scenarios = ("place", "fixed", "fixed-current", "redLight", "redLight-current", "both",
                     "official", "added", "modified", "settings", "empty")
        for scenario in scenarios:
            for text in ("normal", "large-text"):
                assert (tmp_path / "screenshots" / f"{prefix}-{scenario}-{text}-375.png").exists()
        for text in ("normal", "large-text"):
            for section in ("modified", "hidden"):
                assert (tmp_path / "screenshots" / f"{prefix}-settings-{section}-{text}-375.png").exists()
        for scenario in ("fixed", "fixed-current", "redLight", "redLight-current", "both", "modified"):
            assert (tmp_path / "screenshots" / f"{prefix}-{scenario}-bottom-large-text-375.png").exists()
    else:
        assert not images


@pytest.mark.parametrize("profile,styles", [("full", False), ("all", True), ("styles", True), ("gallery", False)])
def test_profiles_include_internal_styles_only_when_explicit(tmp_path, profile, styles):
    tools, environment = shell_workspace(tmp_path)
    script = ROOT / "scripts" / "ci" / "capture-groups.sh"
    assert script.exists(), "尚未拆出正式情境選擇器"
    result = bash("-c", 'source scripts/ci/capture-groups.sh; configure_capture "$1"; selected styles',
                  "profiles", profile, cwd=tmp_path, env=environment)
    assert result.returncode == (0 if styles else 1), result.stdout + result.stderr


@pytest.mark.parametrize("failed_size", ["large", "accessibility-large"])
def test_user_camera_capture_does_not_claim_large_text_if_setting_the_size_fails(tmp_path, failed_size):
    _, environment = shell_workspace(tmp_path)
    environment["FAILED_SIZE"] = failed_size
    result = bash("-c", '''
set -euo pipefail
source scripts/ci/user-camera-screenshots.sh
UDID=test-device
launch_app() { :; }
sleep() { :; }
shot() { printf '%s\\n' "$1"; }
xcrun() { [[ "${!#}" != "${FAILED_SIZE}" ]]; }
capture_user_camera_edits probe
''', cwd=tmp_path, env=environment)
    assert result.returncode != 0, result.stdout + result.stderr
    assert "無法設定我的照相點截圖的文字大小" in result.stdout
    assert "-large-text-375" not in result.stdout
