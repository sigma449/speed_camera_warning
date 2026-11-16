import pytest

from ci_contract_helpers import ROOT, bash, shell_workspace, tool


@pytest.mark.parametrize("entry", ["screenshots.sh", "ios15-run.sh"])
@pytest.mark.parametrize("profile", ["smoke", "full", "none", "invalid"])
def test_real_screenshot_entry_honors_selected_profile(tmp_path, entry, profile):
    tools, environment = shell_workspace(tmp_path)
    environment.update(FAKE_SIM_SCENARIO="good", FAKE_SIM_STATE=str(tmp_path / "state"))
    fake = (ROOT / "data-pipeline" / "tests" / "fixtures" / "ci" / "fake_simctl.py").as_posix()
    tool(tools, "xcrun", f'exec python3 "{fake}" "$@"')
    result = bash(f"scripts/ci/{entry}", "Fake.app", profile, cwd=tmp_path, env=environment,
                  timeout=180 if profile == "full" else 60)
    images = list((tmp_path / "screenshots").glob("*.png"))
    assert result.returncode == (64 if profile == "invalid" else 0), result.stdout + result.stderr
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
