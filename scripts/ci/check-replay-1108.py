#!/usr/bin/env python3
"""檢查 route-probe.swift 的 REPLAY1108 JSON log；舊 log、缺案例或未涵蓋一律失敗。"""
from __future__ import annotations

import argparse
from collections import defaultdict
import json
import math
from pathlib import Path
import sys

MARKER = "REPLAY1108 "
REQUIRED_CASES = ("去程01", "去程02", "去程04", "回程02", "北宜2去程", "北宜2回程",
                  "折返01", "折返02", "語音01", "歸零01")
# 126156 方向別官方門架；不以 log 自報的 gateLat/gateLon 當作正確位置。
GATES = {
    "beiyi-2-f": ((24.9504174, 121.6477995), (24.9429879, 121.6708659), 5835.3),
    "beiyi-2-r": ((24.9430715, 121.6708954), (24.9503516, 121.6478697), 5830.5),
}
SECTION_SPEED_EVENTS = {"section_overspeed_started", "section_beep"}


def is_number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def distance(a: tuple, b: tuple) -> float:
    lat1, lat2 = math.radians(a[0]), math.radians(b[0])
    dlat, dlon = lat2 - lat1, math.radians(b[1] - a[1])
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * 6371008.8 * math.asin(min(1, math.sqrt(h)))


def spoken_distance(meters: float) -> str:
    if meters >= 1000:
        km = math.floor(meters / 100 + 0.5) / 10
        return f"{km:g}公里"
    return f"{max(10, math.floor(meters / 10 + 0.5) * 10)}公尺"


def check_records(records: list[dict]) -> list[str]:
    errors = []

    def require(condition, message):
        if not condition:
            errors.append(message)

    for i, record in enumerate(records, 1):
        require(isinstance(record, dict), f"第 {i} 筆不是 JSON 物件")
        if not isinstance(record, dict):
            continue
        require(record.get("schema") == 1, f"第 {i} 筆 schema 不支援")
        require(isinstance(record.get("case"), str) and isinstance(record.get("event"), str),
                f"第 {i} 筆缺少 case/event")
        require(all(is_number(record.get(k)) for k in ("t", "lat", "lon")), f"第 {i} 筆時間／座標不是有限數值")
    if errors:
        return errors
    require(bool(records), "找不到新版 REPLAY1108 紀錄，不能用舊 log 宣稱通過")
    groups = defaultdict(list)
    for r in records:
        if r["case"]:
            groups[r["case"]].append(r)
    selected = {}
    for prefix in REQUIRED_CASES:
        names = [name for name in groups if name.startswith(prefix + " ")]
        require(len(names) == 1, f"{prefix} 缺少案例或名稱重複（找到 {len(names)} 個）")
        selected[prefix] = groups[names[0]] if len(names) == 1 else []
    for name, rows in groups.items():
        require(sum(r["event"] == "case_start" for r in rows) == 1, f"{name} 沒有唯一 case_start")
        require(sum(r["event"] == "case_end" for r in rows) == 1, f"{name} 沒有唯一 case_end")
        require([r["t"] for r in rows] == sorted(r["t"] for r in rows), f"{name} 時間倒退")
    start = [r for r in records if r["event"] == "run_start"]
    end = [r for r in records if r["event"] == "run_end"]
    require(len(start) == len(end) == 1, "缺少唯一 run_start/run_end，log 可能不完整或混了多次執行")
    if len(end) == 1:
        require(end[0].get("failed") == 0, "replay 有路線規劃失敗")
        require(is_number(end[0].get("totalManeuvers")) and end[0]["totalManeuvers"] > 0
                and end[0].get("correctManeuvers") == end[0]["totalManeuvers"], "轉彎動作點有不相符或未驗到")

    def events(prefix, key, sid=None):
        return [r for r in selected[prefix] if r["event"] == key and (sid is None or r.get("id") == sid)]

    def sequence(prefix, sid, keys):
        found = [events(prefix, key, sid) for key in keys]
        for key, matches in zip(keys, found):
            require(len(matches) == 1, f"{prefix} {sid} 預期一次 {key}，實際 {len(matches)} 次")
        if all(len(matches) == 1 for matches in found):
            times = [matches[0]["t"] for matches in found]
            require(times == sorted(times) and len(set(times)) == len(times), f"{prefix} {sid} 事件順序錯誤：{keys}")

    for r in selected["去程01"]:
        if r["event"] in {"camera_pre", "camera_near"}:
            require("國道一號南向279公里" not in r.get("address", "")
                    and "國道1號南向279公里" not in r.get("address", "")
                    and r.get("id") != "8cb3e650d46a", "去程01 仍提醒錯位的國道一號南向279公里")

    for prefix, sid in (("去程04", "ntpc-huanhe-f"), ("回程02", "ntpc-huanhe-r")):
        sequence(prefix, sid, ("section_approach", "section_entered", "section_completed"))
        for r in selected[prefix]:
            if r["event"] in {"camera_pre", "camera_near"}:
                address = r.get("address", "")
                require(r.get("id") != "685b30491485" and not ("中央路" in address and "白馬寺" in address),
                        f"{prefix} IKEA 仍被當成固定照相提醒")

    for prefix, sid in (("北宜2去程", "beiyi-2-f"), ("北宜2回程", "beiyi-2-r")):
        sequence(prefix, sid, ("section_entered", "section_completed"))
        gates = GATES[sid]
        for key, gate in (("section_entered", gates[0]), ("section_completed", gates[1])):
            for r in events(prefix, key, sid):
                offset = distance((r["lat"], r["lon"]), gate)
                require(offset <= 60, f"{prefix} {key} 離官方門架 {offset:.1f} m，超過 60 m")
                if all(is_number(r.get(k)) for k in ("gateLat", "gateLon")):
                    require(distance((r["gateLat"], r["gateLon"]), gate) <= 1, f"{prefix} 資料端點不是方向別官方門架")
                else:
                    require(False, f"{prefix} 缺少資料端點 gateLat/gateLon")
                if key == "section_entered":
                    require(is_number(r.get("length")) and abs(r["length"] - gates[2]) < 0.2,
                            f"{prefix} 沒有保留方向別公告長度")
        require(not events(prefix, "section_aborted"), f"{prefix} 正向髮夾彎被誤判中途離開")
        beeps = events(prefix, "section_beep", sid)
        require(len(beeps) >= 2, f"{prefix} 區間超速嗶聲不足兩次，未驗到節流")
        for a, b in zip(beeps, beeps[1:]):
            require(b["t"] - a["t"] >= 15, f"{prefix} 區間超速嗶聲間隔 {b['t'] - a['t']:g} 秒，小於 15 秒")

    for prefix in ("折返01", "折返02"):
        aborted = events(prefix, "section_aborted")
        require(len(aborted) == 1, f"{prefix} 預期一次中途離開，實際 {len(aborted)} 次")
        for r in events(prefix, "case_end"):
            require(r.get("sectionStillActive") is False, f"{prefix} 結束時仍在追蹤")
        if len(aborted) == 1:
            require(not any(r["t"] > aborted[0]["t"] and r.get("id") == aborted[0].get("id")
                            and r["event"] in SECTION_SPEED_EVENTS for r in selected[prefix]),
                    f"{prefix} 中止後仍有舊區間超速事件")

    for prefix in ("折返02", "歸零01"):
        zeros = events(prefix, "section_zero")
        require(len(zeros) == 1, f"{prefix} 未驗到唯一歸零事件")
        if len(zeros) == 1:
            zero = zeros[0]
            require(not any(r["t"] >= zero["t"] and r.get("id") == zero.get("id")
                            and r["event"] in SECTION_SPEED_EVENTS for r in selected[prefix]),
                    f"{prefix} 歸零後仍有區間超速語音或嗶聲事件")
            require(any(r["t"] >= zero["t"] and r.get("id") == zero.get("id")
                        and is_number(r.get("remaining")) and r["remaining"] <= 0
                        for r in events(prefix, "section_status")), f"{prefix} 沒有歸零後狀態，無法核對畫面")
    sequence("歸零01", "beiyi-1-f", ("section_entered", "section_zero", "section_completed"))
    require(not events("歸零01", "section_aborted"), "歸零01 同向繼續卻中途離開，不能藉中止掩蓋歸零政策")

    for name, rows in groups.items():
        voices = defaultdict(list)
        for r in rows:
            if r["event"] == "section_overspeed_started":
                voices[r.get("id")].append(r["t"])
            if r["event"] == "section_status":
                remaining = r.get("remaining")
                require(is_number(remaining), f"{name} 缺少剩餘秒數")
                if is_number(remaining) and remaining <= 0:
                    require(r.get("sectionOverspeed") is False, f"{name} 歸零後區間畫面仍顯示超速")
                require(r.get("presentationOverspeed") == (r.get("sectionOverspeed") is True or r.get("cameraOverspeed") is True),
                        f"{name} 畫面／Live Activity 超速狀態與核心不同")
            if r["event"] == "camera_near" and r.get("afterPre") is True:
                announced = r.get("announcedDistance")
                speeches = r.get("speeches")
                require(is_number(announced) and announced > 0 and isinstance(r.get("overspeed"), bool),
                        f"{name} 近距紀錄缺少距離或當下超速狀態")
                if is_number(announced):
                    expected = spoken_distance(announced) + ("，超速" if r.get("overspeed") else "")
                    require(speeches == [expected], f"{name} 已預告的近距語句應為「{expected}」，實際 {speeches!r}")
        for times in voices.values():
            for a, b in zip(times, times[1:]):
                require(b - a >= 30, f"{name} 區間超速語音間隔 {b-a:g} 秒，小於 30 秒")

    first = events("語音01", "camera_near", "3de5c6fd4567")
    require(bool(first), "語音01 沒有驗到北宜路1段246號的首次近距")
    for r in first:
        speeches = r.get("speeches")
        require(r.get("afterPre") is False and isinstance(speeches, list) and bool(speeches)
                and speeches[0] == "前方100公尺，測速照相，速限50", "語音01 首次近距不應改成短句")
    near = events("去程04", "camera_near", "3de5c6fd4567")
    require(any(r.get("afterPre") is True and r.get("overspeed") is True
                and r.get("speeches") == ["100公尺，超速"] for r in near),
            "去程04 未驗到已預告且持續超速的「100公尺，超速」")

    require(any("左轉 上水源快速道路" in r.get("text", "") for r in events("去程02", "nav_display")),
            "去程02 畫面沒有「左轉 上水源快速道路」")
    require(any("左轉上水源快速道路" in r.get("text", "") for r in events("去程02", "nav_speech")),
            "去程02 語音沒有「左轉上水源快速道路」")
    require(not any("左轉上高速公路" in r.get("text", "").replace(" ", "")
                    for r in selected["去程02"] if r["event"] in {"nav_display", "nav_speech"}),
            "去程02 水源動作仍說「上高速公路」")
    return errors


def check_text(text: str) -> list[str]:
    records, errors = [], []
    for line_number, line in enumerate(text.splitlines(), 1):
        if MARKER not in line:
            continue
        try:
            records.append(json.loads(line.split(MARKER, 1)[1]))
        except ValueError as exc:
            errors.append(f"log 第 {line_number} 行 JSON 損壞：{exc}")
    return errors + check_records(records)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    args = parser.parse_args(argv)
    try:
        raw = args.log.read_bytes()
        encoding = "utf-16" if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
        errors = check_text(raw.decode(encoding))
    except (OSError, UnicodeError) as exc:
        print(f"[失敗] 無法讀取 log：{exc}", file=sys.stderr)
        return 1
    for error in errors:
        print(f"[失敗] {error}", file=sys.stderr)
    if errors:
        return 1
    print("11/08 核心與資料 replay 檢查通過；不代表實機播放或 UI 驗收")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
