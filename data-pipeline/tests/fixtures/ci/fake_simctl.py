"""只供 subprocess 契約測試使用，不啟動模擬器。"""
import datetime as dt
import json
import os
from pathlib import Path
import re
import sys

args = sys.argv[1:]
state_path = Path(os.environ["FAKE_SIM_STATE"])
state = json.loads(state_path.read_text()) if state_path.exists() else {"round": 0, "queries": 0}
scenario = os.environ["FAKE_SIM_SCENARIO"]


def save():
    state_path.write_text(json.dumps(state), encoding="utf-8")


if args[:4] == ["simctl", "list", "devices", "available"]:
    print(json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
        {"name": "iPhone 17", "udid": "test-device"}]}}))
elif args[:2] == ["simctl", "create"]:
    print("test-device")
elif args[:2] == ["simctl", "launch"]:
    state["round"] += 1
    save()
    for arg in args:
        if arg.startswith("--stderr="):
            (state_path.parent / "screenshots" / Path(arg.split("=", 1)[1]).name).write_text("", encoding="utf-8")
    print(f"tw.speedcammap.app: {1000 + state['round']}")
elif "launchctl" in args:
    state["queries"] += 1
    save()
    if scenario == "unknown" or (scenario == "transient" and state["queries"] < 3):
        print("simctl 無法查詢 launchctl", file=sys.stderr)
        sys.exit(70)
    pid = 1000 + state["round"] + (1 if scenario == "replaced" else 0)
    if scenario != "dies":
        print(f"{pid}\t0\tUIKitApplication:tw.speedcammap.app[test]")
elif "log" in args and "show" in args:
    predicate = args[args.index("--predicate") + 1] if "--predicate" in args else ""
    if 'category == "search"' in predicate:
        if scenario == "log-error":
            print("simctl 無法讀取 log", file=sys.stderr)
            sys.exit(74)
        pid = 1000 + state["round"] - (1 if scenario == "old-pid" else 0)
        timestamp = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")
        if scenario == "old-time":
            timestamp = "2020-01-01 00:00:00.000000"
        message = "typing test finished" if scenario != "unfinished" else "typing test started"
        rows = [{"processID": pid, "timestamp": timestamp, "eventMessage": message}]
        match = re.search(r"processID\s*==\s*(\d+)", predicate)
        if match and pid != int(match[1]):
            rows = []
        if "--start" in args and timestamp < args[args.index("--start") + 1]:
            rows = []
        if scenario == "large":
            rows += [{"processID": pid, "timestamp": timestamp, "eventMessage": "x" * 1000}] * 1000
        if "--style" in args and args[args.index("--style") + 1] == "json":
            print(json.dumps(rows))
        else:
            for row in rows:
                print(f"{row['timestamp']} SpeedCam[{row['processID']}] {row['eventMessage']}")
elif "screenshot" in args:
    Path(args[-1]).write_bytes(b"fake-png")
