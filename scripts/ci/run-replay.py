#!/usr/bin/env python3
"""保存真正的 producer 輸出並執行適用檢查；任一層失敗都不得通過。"""
from __future__ import annotations

import argparse
from collections import defaultdict
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys

MARKER = "REPLAY1108 "
SECTION_CASES_1107 = {
    "秀朗橋 → 台64（往西）→ 板橋文化路": "tai64-zhonghe-west",
    "中和 → 台64（往東）→ 秀朗橋": "tai64-zhonghe-east",
    "至善路 → 自強隧道（往南）→ 北安路": "ziqiang-tunnel-r",
    "辛亥路 → 辛亥隧道（往南）→ 木柵": "xinhai-tunnel-r",
    "木柵 → 辛亥隧道（往北）→ 辛亥路": "xinhai-tunnel-f",
}


def basic_checks(text, cases, suite):
    rows, errors = [], []
    for number, line in enumerate(text.splitlines(), 1):
        if MARKER not in line:
            continue
        try:
            row = json.loads(line.split(MARKER, 1)[1])
        except ValueError as exc:
            errors.append(f"第 {number} 行 JSON 損壞：{exc}")
            continue
        if not isinstance(row, dict) or row.get("schema") != 1 or not isinstance(row.get("case"), str) \
                or not isinstance(row.get("event"), str) or not isinstance(row.get("t"), (int, float)) \
                or isinstance(row["t"], bool) or not math.isfinite(row["t"]) or row["t"] < 0:
            errors.append(f"第 {number} 行結構化事件無效")
            continue
        rows.append(row)

    def require(condition, message):
        if not condition:
            errors.append(message)

    starts = [r for r in rows if r["event"] == "run_start"]
    ends = [r for r in rows if r["event"] == "run_end"]
    require(len(starts) == len(ends) == 1, "必須有唯一 run_start／run_end；不能接受截斷 log")
    if len(ends) == 1:
        end = ends[0]
        require(end.get("failed") == 0 and end.get("succeeded") == len(cases), "案例規劃沒有全部成功")
        correct, total = end.get("correctManeuvers"), end.get("totalManeuvers")
        require(type(total) is int and total > 0 and type(correct) is int and correct == total,
                f"導航動作點不相符：{correct}／{total}")
        require(rows and rows[-1] is end, "run_end 不是最後事件")
    by_case = defaultdict(list)
    for row in rows:
        if row["case"]:
            by_case[row["case"]].append(row)
    require(set(by_case) == {case["name"] for case in cases}, "實際案例與指定清單不同或缺案")
    for case in cases:
        name = case["name"]
        events = by_case[name]
        kinds = [r["event"] for r in events]
        require(kinds.count("case_start") == kinds.count("case_end") == 1, f"{name} 缺少唯一開始／結束")
        require(bool(kinds) and kinds[0] == "case_start" and kinds[-1] == "case_end", f"{name} 案例事件順序錯誤")
        require(all(a["t"] <= b["t"] for a, b in zip(events, events[1:])), f"{name} 事件時間倒退")
        require(not any(r.get("sectionStillActive") is not False for r in events if r["event"] == "case_end"),
                f"{name} 結束仍在區間或缺少狀態")
        lifecycle = defaultdict(list)
        for event in events:
            if event["event"] in ("section_entered", "section_completed", "section_aborted"):
                lifecycle[event.get("id")].append(event["event"])
        for sid, sequence in lifecycle.items():
            require(bool(sid) and sequence == ["section_entered", "section_completed"],
                    f"{name} {sid} 區間生命週期不完整或中途離開：{sequence}")
        required = SECTION_CASES_1107.get(name) if suite == "1107" else (
            "xinhai-tunnel-r" if suite == "tunnels" and name.startswith("辛亥隧道") else None)
        if required:
            require(lifecycle[required] == ["section_entered", "section_completed"],
                    f"{name} 缺少必要區間 {required} 的進入／完成")
        if suite == "tunnels":
            tunnel = name.split("（", 1)[0]
            alerts = [r for r in events if r["event"] in ("camera_pre", "camera_near")
                      and r.get("estimated") is True and tunnel in r.get("address", "")]
            pre = {r.get("id") for r in alerts if r["event"] == "camera_pre" and r.get("speeches")}
            require(len(pre - {None, ""}) >= (8 if tunnel == "雪山隧道" else 1),
                    f"{name} 缺少必要的隧道推算預告／語音")
            if tunnel != "雪山隧道":
                require(any(r["event"] == "camera_near" and r.get("speeches") for r in alerts),
                        f"{name} 缺少隧道推算近距／語音")
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", required=True, type=Path)
    parser.add_argument("--data-log", required=True, type=Path)
    parser.add_argument("--directory", type=Path, default=Path("build/route-probe"))
    parser.add_argument("producer", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.producer[1:] if args.producer[:1] == ["--"] else args.producer
    if not command:
        parser.error("必須指定 producer")
    command[0] = shutil.which(command[0]) or command[0]
    args.directory.mkdir(parents=True, exist_ok=True)
    replay_log = args.directory / "replay.log"
    with replay_log.open("wb") as saved, subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as process:
        for line in process.stdout:
            saved.write(line)
            saved.flush()
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
        producer_exit = process.wait()
    errors = []
    suite = args.cases.stem.removeprefix("route-replay-")
    try:
        data_text = args.data_log.read_text(encoding="utf-8-sig")
        if not data_text.strip():
            raise ValueError("資料建置報告為空")
        text = replay_log.read_text(encoding="utf-8-sig")
        combined = args.directory / "acceptance.log"
        combined.write_text(data_text + "\n" + text, encoding="utf-8")
        if suite == "1108":
            checked = subprocess.run([sys.executable, str(Path(__file__).with_name("check-replay-1108.py")),
                                      str(combined)], capture_output=True, encoding="utf-8")
            checker_text = checked.stdout + checked.stderr
            if checked.returncode:
                errors.append("1108 嚴格檢查器拒絕本次回放")
        else:
            cases = json.loads(args.cases.read_text(encoding="utf-8"))
            errors.extend(basic_checks(text, cases, suite))
            checker_text = "\n".join("[失敗] " + error for error in errors)
    except (OSError, UnicodeError, ValueError) as exc:
        errors.append(f"無法驗收：{exc}")
        checker_text = str(exc)
    if producer_exit:
        errors.append(f"producer 退出碼 {producer_exit}")
    conclusion = "failure" if errors else "success"
    report = dict(suite=suite, conclusion=conclusion, producerExit=producer_exit, errors=errors)
    (args.directory / "checker-result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                                                         encoding="utf-8")
    (args.directory / "checker.log").write_text(checker_text + "\n", encoding="utf-8")
    print(checker_text)
    for error in errors:
        print(f"::error::{error}")
    print(f"{suite} 檢查器：{conclusion}；不代表實機播放、手勢或 CarPlay 驗收")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
