import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def shell_workspace(tmp_path):
    shutil.copytree(ROOT / "scripts" / "ci", tmp_path / "scripts" / "ci")
    tools = tmp_path / "bin"
    tools.mkdir()
    env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
               HOME=str(tmp_path), MSYS_NO_PATHCONV="1", PYTHONUTF8="1")
    executable = Path(sys.executable).as_posix()
    tool(tools, "python3", f'exec "{executable}" "$@"')
    tool(tools, "sleep", "exit 0")
    return tools, env


def tool(directory, name, body):
    path = directory / name
    path.write_text("#!/usr/bin/env bash\n" + body + "\n", encoding="utf-8", newline="\n")
    path.chmod(0o755)
    return path


def bash(script, *args, cwd, env):
    executable = shutil.which("bash")
    assert executable, "CI shell 契約測試需要 bash"
    return subprocess.run([executable, str(script), *map(str, args)], cwd=cwd, env=env,
                          capture_output=True, encoding="utf-8", errors="replace", timeout=60)


def fake_simulator(tmp_path, scenario):
    tools, env = shell_workspace(tmp_path)
    fake = ROOT / "data-pipeline" / "tests" / "fixtures" / "ci" / "fake_simctl.py"
    tool(tools, "xcrun", f'exec python3 "{fake.as_posix()}" "$@"')
    tool(tools, "find", "exit 0")
    env.update(FAKE_SIM_SCENARIO=scenario, FAKE_SIM_STATE=str(tmp_path / "sim-state.json"))
    return env
