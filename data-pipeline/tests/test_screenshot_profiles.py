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
