#!/usr/bin/env python3
"""診斷查詢失敗會留退出碼及警告；此步驟不替代程序存活、搜尋或 replay 閘門。"""
import argparse
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", required=True)
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[a-z0-9-]+", args.label):
        parser.error("無效工作名稱")
    out = Path("build/evidence") / args.label
    out.mkdir(parents=True, exist_ok=True)
    (out / "platform.txt").write_text(platform.platform() + "\nPython " + platform.python_version(), encoding="utf-8")
    commands = {
        "xcode-version": ["xcodebuild", "-version"],
        "swift-version": ["xcrun", "swift", "--version"],
        "simulator-list": ["xcrun", "simctl", "list", "-j"],
    }
    udid_file = Path("screenshots/simulator-udid.txt")
    if udid_file.exists():
        udid = udid_file.read_text().strip()
        commands["simulator-processes"] = ["xcrun", "simctl", "spawn", udid, "launchctl", "list"]
        commands["app-log"] = ["xcrun", "simctl", "spawn", udid, "log", "show", "--last", "2h",
                               "--style", "json", "--info", "--debug", "--predicate", 'subsystem == "tw.speedcammap.app"']
    statuses = {}
    for name, command in commands.items():
        try:
            result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
            (out / f"{name}.log").write_bytes(result.stdout)
            statuses[name] = result.returncode
        except subprocess.TimeoutExpired as error:
            statuses[name] = str(error)
            partial = error.output or b""
            if isinstance(partial, str):
                partial = partial.encode("utf-8")
            (out / f"{name}.log").write_bytes(partial + b"\n" + str(error).encode("utf-8"))
        except OSError as error:
            statuses[name] = str(error)
            (out / f"{name}.log").write_text(str(error), encoding="utf-8")
        if statuses[name] != 0:
            print(f"::warning::診斷 {name} 無法完整取得：{statuses[name]}")
    (out / "diagnostic-status.json").write_text(json.dumps(statuses, ensure_ascii=False, indent=2), encoding="utf-8")
    for root in (Path.home() / "Library/Logs/DiagnosticReports", Path("/Library/Logs/DiagnosticReports")):
        if root.exists():
            for path in root.iterdir():
                if path.is_file() and path.name.startswith(("SpeedCam", "RouteProbe")) and path.suffix in (".ips", ".crash"):
                    destination = out / "crashes" / ("user" if root.is_relative_to(Path.home()) else "system")
                    destination.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(path, destination / path.name)
    simulator_log = Path.home() / "Library/Logs/CoreSimulator/CoreSimulator.log"
    if simulator_log.exists():
        shutil.copy2(simulator_log, out / simulator_log.name)
    for name in ("manifest.json", "sources.json", "data-build.log"):
        source = Path("build/ci-data") / name
        if source.exists():
            shutil.copy2(source, out / name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
