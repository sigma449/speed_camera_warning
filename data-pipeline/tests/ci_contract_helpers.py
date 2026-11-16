import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def shell_workspace(tmp_path, *, wait_seconds=0):
    shutil.copytree(ROOT / "scripts" / "ci", tmp_path / "scripts" / "ci")
    tools = tmp_path / "bin"
    tools.mkdir()
    env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
               HOME=str(tmp_path), MSYS_NO_PATHCONV="1", PYTHONUTF8="1",
               BASH_ENV=(tools / "functions.sh").as_posix(),
               CI_CONTRACT_WAIT_SECONDS=str(wait_seconds))
    executable = Path(sys.executable).as_posix()
    tool(tools, "python3", f'exec "{executable}" "$@"')
    tool(tools, "sleep", 'if [[ "${CI_CONTRACT_WAIT_SECONDS:-0}" != 0 ]]; then\n'
                        '  command -p sleep "${CI_CONTRACT_WAIT_SECONDS}"\n'
                        'fi')
    return tools, env


def tool(directory, name, body):
    path = directory / name
    path.write_text("#!/usr/bin/env bash\n" + body + "\n", encoding="utf-8", newline="\n")
    path.chmod(0o755)
    # 同一個替身也供 Bash 函式呼叫，避免 Windows 每次再啟動兩層 Bash。
    with (directory / "functions.sh").open("a", encoding="utf-8", newline="\n") as functions:
        functions.write(f"\n{name}() (\n{body}\n)\n")
    return path


def bash(script, *args, cwd, env, timeout=60):
    executable = shutil.which("bash")
    assert executable, "CI shell 契約測試需要 bash"
    return subprocess.run([executable, str(script), *map(str, args)], cwd=cwd, env=env,
                          capture_output=True, encoding="utf-8", errors="replace", timeout=timeout)


def fake_simulator(tmp_path, scenario):
    tools, env = shell_workspace(tmp_path)
    fake = ROOT / "data-pipeline" / "tests" / "fixtures" / "ci" / "fake_simctl.py"
    executable = Path(sys.executable).as_posix()
    tool(tools, "xcrun", f'exec "{executable}" "{fake.as_posix()}" "$@"')
    tool(tools, "find", "exit 0")
    env.update(FAKE_SIM_SCENARIO=scenario, FAKE_SIM_STATE=str(tmp_path / "sim-state.json"))
    return env
