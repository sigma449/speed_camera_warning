from pathlib import Path
import shlex
import sys

import pytest

from ci_contract_helpers import bash, shell_workspace, tool


@pytest.mark.parametrize("invocation", ["probe", "command probe"])
def test_shell_tools_preserve_arguments_diagnostics_and_child_exit(tmp_path, invocation):
    tools, environment = shell_workspace(tmp_path)
    program = ('import sys; [print("<" + arg + ">") for arg in sys.argv[1:]]; '
               'print("diagnostic", file=sys.stderr); sys.exit(23)')
    executable = shlex.quote(Path(sys.executable).as_posix())
    tool(tools, "probe", f'exec {executable} -c {shlex.quote(program)} "$@"; echo unreachable')
    result = bash("-c", f'{invocation} "two words" "*"; status=$?; echo parent-alive; exit "$status"',
                  cwd=tmp_path, env=environment)
    assert result.returncode == 23
    assert result.stdout == "<two words>\n<*>\nparent-alive\n"
    assert result.stderr == "diagnostic\n"
