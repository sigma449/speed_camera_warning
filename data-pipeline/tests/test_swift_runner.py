import importlib.util
from ci_contract_helpers import ROOT


def runner():
    spec = importlib.util.spec_from_file_location("swift_runner", ROOT / "scripts" / "swift-test.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_swift_runner_keeps_source_resources_arguments_and_exit_status(monkeypatch):
    module = runner()
    calls = []

    def run(command, *, env):
        calls.append((command, env))
        return 42

    monkeypatch.setattr(module.subprocess, "call", run)
    assert module.main(["--filter", "ModelsTests", "--parallel"]) == 42
    command, environment = calls[0]
    assert command[-5:] == ["swift", "test", "--filter", "ModelsTests", "--parallel"]
    assert f"{ROOT / 'Packages' / 'SpeedCamCore'}:/pkg" in command
    assert f"{ROOT / 'SpeedCam' / 'Resources'}:/SpeedCam/Resources:ro" in command
    mount = command[command.index("--mount") + 1]
    assert mount.startswith("type=volume,source=")
    assert ",target=/pkg/.build,volume-nocopy" in mount
    assert environment["MSYS_NO_PATHCONV"] == "1"


def test_swift_cache_is_stable_and_separate_for_each_checkout(monkeypatch, tmp_path):
    module = runner()
    mounts = []

    def run(command, *, env):
        mounts.append(command[command.index("--mount") + 1])
        return 0

    monkeypatch.setattr(module.subprocess, "call", run)
    for checkout in ("first", "first", "second"):
        monkeypatch.setattr(module, "__file__", str(tmp_path / checkout / "scripts" / "swift-test.py"))
        assert module.main([]) == 0
    assert mounts[0] == mounts[1]
    assert mounts[0] != mounts[2]
