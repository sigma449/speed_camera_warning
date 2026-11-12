#!/usr/bin/env python3
"""依完整路線區分未經過與漏事件；每個必驗項目仍須有實際覆蓋。"""
from __future__ import annotations

import argparse
from collections import defaultdict
import json
import math
from pathlib import Path
import sys

MARKER = "REPLAY1108 "
BEIYI_CASES = {f"北宜{number}{direction}": f"beiyi-{number}-{suffix}"
               for number in range(1, 5) for direction, suffix in (("去程", "f"), ("回程", "r"))}
REQUIRED_CASES = ("去程01", "去程02", "去程03", "去程04", *BEIYI_CASES,
                  "回程01", "回程02", "回程03", "回程04", "折返01", "折返02",
                  "語音01", "歸零01", "補測01", "補測02", "補測03", "補測04",
                  "補測05", "補測06", "補測07", "補測08", "補測09")
# 126156 方向別官方門架；不以 log 自報的 gateLat/gateLon 當作正確位置。
GATES = {
    "beiyi-2-f": ((24.9504174, 121.6477995), (24.9429879, 121.6708659), 5835.3),
    "beiyi-2-r": ((24.9430715, 121.6708954), (24.9503516, 121.6478697), 5830.5),
}
SECTION_POINTS = {
    "beiyi-1-f": ((24.953133, 121.5981016), (24.9570178, 121.6236044)),
    "beiyi-1-r": ((24.9569297, 121.6236371), (24.9531792, 121.5981891)),
    **{sid: gates[:2] for sid, gates in GATES.items()},
    "beiyi-3-f": ((24.938322, 121.6772214), (24.9359628, 121.7036968)),
    "beiyi-3-r": ((24.9360445, 121.7035178), (24.9384678, 121.6770967)),
    "beiyi-4-f": ((24.866288, 121.774148), (24.850314, 121.795001)),
    "beiyi-4-r": ((24.850314, 121.795001), (24.866288, 121.774148)),
    "ntpc-huanhe-f": ((24.9718199, 121.5292394), (24.9641247, 121.5367909)),
    "ntpc-huanhe-r": ((24.9639108, 121.5369783), (24.9712441, 121.5309406)),
}
SECTION_CASES = BEIYI_CASES | {
    "去程04": "ntpc-huanhe-f", "回程02": "ntpc-huanhe-r",
    "補測06": "ntpc-huanhe-f", "補測07": "ntpc-huanhe-r",
}
CITY_CAMERA = (25.052633, 121.53678)
NEAR_CAMERA = (24.95302, 121.544846)
SHUIYUAN_ENTRY = (25.02047, 121.52266)
SHUIYUAN_CONFIRMATION = (25.01833, 121.52381)
INSTRUCTION_CASES = ("去程02", "補測01", "補測05")
SECTION_SPEED_EVENTS = {"section_overspeed_started", "section_beep"}
HINT_POINTS = {
    "jianguo-descent": ((25.025132, 121.537556), "jianguo-shida-descent", "下高架 往師大路", "沿建國快速道路下高架，往師大路"),
    "shida-underpass": ((25.021279, 121.530923), "shida-underpass", "下地下道 往師大路", "沿主線下地下道，往師大路"),
    "shuiyuan-south-exit": ((24.991865, 121.533267), "shuiyuan-south-huanhe", "下匝道 不上秀朗橋", "下水源快速道路，靠右往環河路，不上秀朗橋"),
    "xiulang-fork": ((24.991587, 121.533042), "shuiyuan-south-huanhe", "下匝道 不上秀朗橋", "下水源快速道路，靠右往環河路，不上秀朗橋"),
    "huanhe-underpass": ((24.963436, 121.536824), "huanhe-underpass", "中間車道 下地下道", "走中間車道下地下道，往北宜路"),
    "shuiyuan-north-entry": ((24.991771, 121.533305), "shuiyuan-north-entry", "上匝道 水源快速道路", "上匝道，接水源快速道路"),
}
CONTINUOUS_HINT_CASES = {"補測01": tuple(HINT_POINTS)[:5], "補測02": ("shuiyuan-north-entry",)}
FIXED_HINT_CASES = {
    "去程03": ("shuiyuan-south-exit", "xiulang-fork"),
    "回程03": ("shuiyuan-north-entry",),
    "補測03": ("huanhe-underpass",),
    "補測04": ("jianguo-descent", "shida-underpass"),
}
HINT_CASES = CONTINUOUS_HINT_CASES | FIXED_HINT_CASES
# 以獨立的有序路形證據判斷分支，不能拿核心 matched=false 當成沒經過。
HINT_BRANCHES = {
    "jianguo-shida-descent": ((25.025132, 121.537556), (25.0224723, 121.535033), 181.7, 15),
    "shida-underpass": ((25.021279, 121.530923), (25.020242, 121.5298171), 227.2, 15),
    "shuiyuan-south-huanhe": ((24.991587, 121.533042), (24.9893841, 121.5312799), 217.1, 15),
    "huanhe-underpass": ((24.963436, 121.536824), (24.9614239, 121.5373825), 171.4, 12),
    "shuiyuan-north-entry": ((24.991771, 121.533305), (24.9923184, 121.5336896), 32.5, 15),
}
ADDRESS_QUERY = "台北市中山區長春路128號"
STORE_QUERY = "坪林 7-ELEVEN"


def is_number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def distance(a: tuple, b: tuple) -> float:
    lat1, lat2 = math.radians(a[0]), math.radians(b[0])
    dlat, dlon = lat2 - lat1, math.radians(b[1] - a[1])
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * 6371008.8 * math.asin(min(1, math.sqrt(h)))


def bearing(a, b):
    a_lat, b_lat = math.radians(a[0]), math.radians(b[0])
    dlon = math.radians(b[1] - a[1])
    return math.degrees(math.atan2(math.sin(dlon) * math.cos(b_lat),
                                  math.cos(a_lat) * math.sin(b_lat)
                                  - math.sin(a_lat) * math.cos(b_lat) * math.cos(dlon))) % 360


class RouteGeometry:
    def __init__(self, points):
        self.points = points
        self.segments = []
        self.length = 0.0
        for a, b in zip(points, points[1:]):
            length = distance(a, b)
            if length > 0:
                self.segments.append((a, b, self.length, length, bearing(a, b)))
                self.length += length

    def projections(self, point, heading=None):
        result = []
        for a, b, start, length, course in self.segments:
            if heading is not None and abs((course - heading + 180) % 360 - 180) > 45:
                continue
            scale = 6371008.8 * math.pi / 180
            dx, dy = (b[1] - a[1]) * scale * math.cos(math.radians(a[0])), (b[0] - a[0]) * scale
            px, py = (point[1] - a[1]) * scale * math.cos(math.radians(a[0])), (point[0] - a[0]) * scale
            ratio = max(0, min(1, (px * dx + py * dy) / (dx * dx + dy * dy)))
            result.append((start + ratio * length, math.hypot(px - ratio * dx, py - ratio * dy)))
        return result

    def nearest(self, point):
        return min(self.projections(point), key=lambda projection: projection[1])

    def passes(self, point, heading, *, before=0, after=60, max_before=math.inf):
        return any(lateral <= 30 and before <= along <= min(max_before, self.length - after)
                   for along, lateral in self.projections(point, heading))

    def follows(self, entry, confirmation, *, radius=30, heading=None,
                before=0, after=0, max_span=math.inf, unique=False):
        entries = [(along, lateral) for along, lateral in self.projections(entry, heading)
                   if lateral <= radius and along >= before]
        exits = [(along, lateral) for along, lateral in self.projections(confirmation)
                 if lateral <= radius and along <= self.length - after]
        pairs = [(a, b, da + db) for a, da in entries for b, db in exits if 20 <= b - a <= max_span]
        if not pairs:
            return None
        best = min(pairs, key=lambda pair: pair[2])
        if unique and any(abs(a - best[0]) > radius * 2 for a, _, _ in pairs):
            return None
        return best[:2]


def spoken_distance(meters: float) -> str:
    if meters >= 1000:
        km = math.floor(meters / 100 + 0.5) / 10
        return f"{km:g}公里"
    return f"{max(10, math.floor(meters / 10 + 0.5) * 10)}公尺"


def check_records(records: list[dict], *, information: list[str] | None = None) -> list[str]:
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
        require(rows[0]["event"] == "case_start" and rows[-1]["event"] == "case_end",
                f"{name} 事件落在案例起訖之外")
        require([r["t"] for r in rows] == sorted(r["t"] for r in rows), f"{name} 時間倒退")
        if not name.startswith(("折返01 ", "折返02 ")):
            require(not any(r["event"] == "section_aborted" for r in rows), f"{name} 非折返案例卻中途離開")
        active = None
        for r in rows:
            if r["event"] == "section_entered":
                require(active is None, f"{name} 尚未結束 {active} 就進入其他區間")
                active = r.get("id")
                require(isinstance(active, str) and bool(active), f"{name} 進入區間缺少 id")
            elif r["event"] in {"section_completed", "section_aborted"}:
                require(active is not None and r.get("id") == active, f"{name} 沒有對應進入事件的 {r['event']}")
                active = None
            elif r["event"] in SECTION_SPEED_EVENTS | {"section_status", "section_zero", "section_remaining"}:
                require(active is not None and r.get("id") == active, f"{name} 未進入或結束後仍有 {r['event']}")
            elif r["event"] == "case_end":
                require(r.get("sectionStillActive") is (active is not None), f"{name} 結束時仍在追蹤或缺少結束事件")
                if not name.startswith(("補測01 ", "補測02 ")):
                    require(active is None, f"{name} 結束時仍在追蹤")
    start = [r for r in records if r["event"] == "run_start"]
    end = [r for r in records if r["event"] == "run_end"]
    require(len(start) == len(end) == 1, "缺少唯一 run_start/run_end，log 可能不完整或混了多次執行")
    if len(end) == 1:
        require(end[0].get("failed") == 0, "replay 有路線規劃失敗")
        require(end[0].get("succeeded") == len(groups) == len(REQUIRED_CASES), "成功案例數和完整案例清單不符")
        require(records[0]["event"] == "run_start" and records[-1]["event"] == "run_end", "事件落在 run_start/run_end 之外")
        require(is_number(end[0].get("totalManeuvers")) and end[0]["totalManeuvers"] > 0
                and end[0].get("correctManeuvers") == end[0]["totalManeuvers"], "轉彎動作點有不相符或未驗到")

    def events(prefix, key, sid=None):
        return [r for r in selected[prefix] if r["event"] == key and (sid is None or r.get("id") == sid)]

    geometries, apple_steps = {}, {}
    for prefix in REQUIRED_CASES:
        reports = events(prefix, "route_geometry")
        require(len(reports) == 1, f"{prefix} 缺少唯一完整路線／Apple 原文證據，無法區分沒經過與漏事件")
        if len(reports) != 1:
            continue
        header = reports[0]
        parts = events(prefix, "route_geometry_part")
        count, chunks = header.get("pointCount"), header.get("chunkCount")
        valid_parts = all(isinstance(value, int) and not isinstance(value, bool) for value in (count, chunks))
        valid_parts = valid_parts and count >= 2 and 1 <= chunks <= count and len(parts) == chunks and all(
            isinstance(part.get("index"), int) and not isinstance(part["index"], bool)
            and isinstance(part.get("points"), list) and bool(part["points"]) for part in parts)
        valid_parts = valid_parts and sorted(part["index"] for part in parts) == list(range(chunks))
        require(valid_parts, f"{prefix} 完整路線分段缺失、重複或索引無效")
        if not valid_parts:
            continue
        points = [point for part in sorted(parts, key=lambda part: part["index"]) for point in part["points"]]
        valid = len(points) == count and all(
            isinstance(point, list) and len(point) == 2 and all(is_number(v) for v in point)
            and -90 <= point[0] <= 90 and -180 <= point[1] <= 180 for point in points)
        require(valid, f"{prefix} 完整路線座標無效")
        if not valid:
            continue
        geometry = RouteGeometry(points)
        require(geometry.length > 0, f"{prefix} 完整路線沒有長度")
        if geometry.length <= 0:
            continue
        geometries[prefix] = geometry
        steps = header.get("appleSteps")
        valid_steps = isinstance(steps, list) and bool(steps) and all(
            isinstance(step, dict) and step.get("index") == index
            and all(isinstance(step.get(key), str) for key in ("text", "corrected", "shortText"))
            and all(is_number(step.get(key)) for key in ("start", "end"))
            and 0 <= step["start"] <= step["end"] <= geometry.length + 1
            for index, step in enumerate(steps))
        require(valid_steps, f"{prefix} 缺少有效 Apple 原文、校正與動作點")
        if valid_steps:
            require(abs(steps[0]["start"]) <= 1 and abs(steps[-1]["end"] - geometry.length) <= 1
                    and all(abs(a["end"] - b["start"]) <= 1 for a, b in zip(steps, steps[1:])),
                    f"{prefix} Apple 步驟位置與完整路線不連續")
            apple_steps[prefix] = steps

    required_coverage, covered_items = set(), set()

    def expect_route(prefix, item, condition):
        required_coverage.add(item)
        if prefix not in geometries:
            return False
        if not condition:
            if information is not None:
                information.append(f"{prefix} 未經過「{item}」所需方向／完整判定範圍；仍須其他案例實際驗到")
            return False
        covered_items.add(item)
        return True

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
    for prefix in ("去程01", "補測09"):
        geometry = geometries.get(prefix)
        if expect_route(prefix, "市區照相預告與通過",
                        geometry is not None and geometry.passes(CITY_CAMERA, 180, before=150)):
            require(bool(events(prefix, "camera_pre", "fdb06e9709c2"))
                    and bool(events(prefix, "camera_passed", "fdb06e9709c2")),
                    f"{prefix} 真正的市區照相提醒消失，不能以關閉全部提醒修正國道誤報")

    eligible_sections = set()
    for prefix, sid in SECTION_CASES.items():
        geometry = geometries.get(prefix)
        is_huanhe = sid.startswith("ntpc-huanhe-")
        if expect_route(prefix, f"{sid} 完整生命週期", geometry is not None and geometry.follows(
                *SECTION_POINTS[sid], radius=60, before=250 if is_huanhe else 60, after=60) is not None):
            eligible_sections.add((prefix, sid))
            keys = ("section_approach", "section_entered", "section_completed") if is_huanhe else (
                "section_entered", "section_completed")
            sequence(prefix, sid, keys)
        if not is_huanhe:
            continue
        for r in selected[prefix]:
            if r["event"] in {"camera_pre", "camera_near"}:
                address = r.get("address", "")
                require(r.get("id") != "685b30491485" and not ("中央路" in address and "白馬寺" in address),
                        f"{prefix} IKEA 仍被當成固定照相提醒")

    for prefix, sid in (("北宜2去程", "beiyi-2-f"), ("北宜2回程", "beiyi-2-r")):
        if (prefix, sid) not in eligible_sections:
            continue
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
        beeps = events(prefix, "section_beep", sid)
        require(len(beeps) >= 2, f"{prefix} 區間超速嗶聲不足兩次，未驗到節流")
        for a, b in zip(beeps, beeps[1:]):
            require(b["t"] - a["t"] >= 15, f"{prefix} 區間超速嗶聲間隔 {b['t'] - a['t']:g} 秒，小於 15 秒")

    for prefix in ("折返01", "折返02"):
        geometry = geometries.get(prefix)
        gates = geometry.follows(*SECTION_POINTS["beiyi-1-f"], radius=60, before=60) if geometry else None
        start_rows = events(prefix, "case_start")
        if start_rows:
            require(start_rows[0].get("turnaroundAtMeters") == 1400
                    and start_rows[0].get("waitAtTurnaroundSeconds") == (350 if prefix == "折返02" else 0),
                    f"{prefix} 沒有保留原折返／停等情境")
        if not expect_route(prefix, f"{prefix} 區間內折返",
                            gates is not None and gates[0] + 60 < 1400 < gates[1]):
            continue
        aborted = events(prefix, "section_aborted")
        require(len(aborted) == 1, f"{prefix} 預期一次中途離開，實際 {len(aborted)} 次")
        for r in events(prefix, "case_end"):
            require(r.get("sectionStillActive") is False, f"{prefix} 結束時仍在追蹤")
        if len(aborted) == 1:
            require(not any(r["t"] > aborted[0]["t"] and r.get("id") == aborted[0].get("id")
                            and r["event"] in SECTION_SPEED_EVENTS for r in selected[prefix]),
                    f"{prefix} 中止後仍有舊區間超速事件")

    for prefix in ("折返02", "歸零01"):
        geometry = geometries.get(prefix)
        gates = geometry.follows(*SECTION_POINTS["beiyi-1-f"], radius=60, before=60, after=60) if geometry else None
        if prefix == "歸零01":
            start_rows = events(prefix, "case_start")
            if start_rows:
                require(start_rows[0].get("pauseAtMeters") == 1400 and start_rows[0].get("pauseSeconds") == 350,
                        "歸零01 沒有保留原同向停等情境")
        if not expect_route(prefix, f"{prefix} 歸零後狀態",
                            gates is not None and gates[0] + 60 < 1400 < gates[1]):
            continue
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
        if prefix == "歸零01":
            sequence(prefix, "beiyi-1-f", ("section_entered", "section_zero", "section_completed"))
    require(not events("歸零01", "section_aborted"), "歸零01 同向繼續卻中途離開，不能藉中止掩蓋歸零政策")

    for name, rows in groups.items():
        voices = defaultdict(list)
        section_beeps = defaultdict(list)
        for r in rows:
            if r["event"] == "section_overspeed_started":
                voices[r.get("id")].append(r["t"])
            if r["event"] == "section_beep":
                section_beeps[r.get("id")].append(r["t"])
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
        for times in section_beeps.values():
            for a, b in zip(times, times[1:]):
                require(b - a >= 15, f"{name} 區間超速嗶聲間隔 {b-a:g} 秒，小於 15 秒")

    geometry = geometries.get("語音01")
    if expect_route("語音01", "首次近距完整語音", geometry is not None
                    and geometry.passes(NEAR_CAMERA, 90, max_before=100)):
        first = events("語音01", "camera_near", "3de5c6fd4567")
        require(bool(first), "語音01 沒有驗到北宜路1段246號的首次近距")
        for r in first:
            speeches = r.get("speeches")
            require(r.get("afterPre") is False and isinstance(speeches, list) and bool(speeches)
                    and speeches[0] == "前方100公尺，測速照相，速限50", "語音01 首次近距不應改成短句")
    for prefix in ("去程04", "補測08"):
        geometry = geometries.get(prefix)
        if expect_route(prefix, "已預告且持續超速近距短句", geometry is not None
                        and geometry.passes(NEAR_CAMERA, 90, before=150)):
            near = events(prefix, "camera_near", "3de5c6fd4567")
            require(any(r.get("afterPre") is True and r.get("overspeed") is True
                        and r.get("speeches") == ["100公尺，超速"] for r in near),
                    f"{prefix} 未驗到已預告且持續超速的「100公尺，超速」")

    for prefix in INSTRUCTION_CASES:
        geometry = geometries.get(prefix)
        passage = geometry.follows(SHUIYUAN_ENTRY, SHUIYUAN_CONFIRMATION,
                                   heading=250, max_span=650, unique=True) if geometry else None
        if not expect_route(prefix, "水源南向入口路形", passage is not None):
            continue
        candidates = [step for step in apple_steps.get(prefix, [])
                      if abs(step["end"] - passage[0]) <= 40 and "上高速公路" in step["text"]]
        required_coverage.add("水源上高速公路原文校正")
        if not candidates:
            if information is not None:
                information.append(f"{prefix} 經過水源入口，但 Apple 沒有提供「上高速公路」原文；不算校正驗收")
            continue
        covered_items.add("水源上高速公路原文校正")
        if prefix == "補測05":
            require(passage[0] >= 400, "補測05 匝道前不足約 500 m，未保留提前觀察範圍")
        for step in candidates:
            expected = step["text"].replace("上高速公路", "上水源快速道路")
            require(step["corrected"] == expected, f"{prefix} 水源入口原文沒有正確校正")
            displays = [r for r in events(prefix, "nav_display")
                        if is_number(r.get("maneuverAlong")) and abs(r["maneuverAlong"] - step["end"]) <= 20]
            expected_short = "左轉 上水源快速道路" if step["text"].startswith("左轉") else "上水源快速道路"
            require(bool(displays) and all(expected_short in r.get("text", "") and r.get("instruction") == expected
                                           for r in displays), f"{prefix} 畫面沒有正確的「{expected_short}」")
            indices = {r["stepIndex"] for r in displays if isinstance(r.get("stepIndex"), int)}
            spoken = [r for r in events(prefix, "nav_speech") if r.get("stepIndex") in indices]
            require(bool(spoken) and all(r.get("text", "").endswith(expected) for r in spoken),
                    f"{prefix} 語音沒有正確的「{expected}」")

    covered_points = set()
    for prefix, ids in HINT_CASES.items():
        rows = selected[prefix]
        reports = events(prefix, "hint_check")
        require(sorted(r.get("id", "") for r in reports) == sorted(ids), f"{prefix} 缺少或重複提示點報告")
        starts = events(prefix, "case_start")
        if len(starts) == 1:
            require(sorted(starts[0].get("hintCheckIDs", [])) == sorted(ids), f"{prefix} 未宣告完整提示點清單")
        for r in reports:
            previous_errors = len(errors)
            if r.get("id") not in HINT_POINTS:
                require(False, f"{prefix} 未知提示點 {r.get('id')}")
                continue
            point, hint_id, short, instruction = HINT_POINTS[r["id"]]
            require(distance((r["lat"], r["lon"]), point) <= 1, f"{prefix} {r['id']} 不是使用者提供的位置")
            route_distance, along = r.get("routeDistance"), r.get("along")
            require(is_number(route_distance) and route_distance >= 0 and is_number(along) and along >= 0,
                    f"{prefix} {r['id']} 缺少路線最近距離／沿路位置")
            require(r.get("hintID") == hint_id, f"{prefix} {r['id']} 提示 ID 不符")
            require(r.get("shortText") == short, f"{prefix} {r['id']} 短句不符")
            require(r.get("instruction") == instruction, f"{prefix} {r['id']} 語音全文不符")
            context = r.get("appleSteps")
            require(isinstance(context, list) and bool(context) and all(
                isinstance(step, dict) and isinstance(step.get("text"), str)
                and is_number(step.get("start")) and is_number(step.get("end")) for step in context),
                f"{prefix} {r['id']} 缺少 Apple 原文與前後步驟位置")
            require(isinstance(r.get("displayAtPoint"), str) and bool(r["displayAtPoint"]),
                    f"{prefix} {r['id']} 缺少經過當時的下一步")
            coverage = r.get("coverage")
            geometry = geometries.get(prefix)
            if geometry is None:
                continue
            actual_along, actual_distance = geometry.nearest(point)
            require(is_number(route_distance) and abs(route_distance - actual_distance) <= 5
                    and is_number(along) and abs(along - actual_along) <= 5,
                    f"{prefix} {r['id']} 報告位置與完整路線證據不符")
            entry, confirmation, heading, radius = HINT_BRANCHES[hint_id]
            branch = geometry.follows(entry, confirmation, radius=radius, heading=heading,
                                      max_span=max(100, distance(entry, confirmation) * 2 + radius * 2),
                                      unique=True)
            if actual_distance > 30 or branch is None:
                expected_coverage = "not_on_route" if actual_distance > 30 else "different_branch"
                require(coverage == expected_coverage and r.get("matched") is False and r.get("triggered") is False,
                        f"{prefix} {r['id']} 未涵蓋狀態與距離／分支證據不符")
                require(not any(event["event"] in {"nav_hint", "nav_speech"} and event.get("hintID") == hint_id
                                for event in rows), f"{prefix} {r['id']} 未經過卻發出提示")
                if information is not None:
                    offset = f"{route_distance:.1f} m" if is_number(route_distance) else repr(route_distance)
                    information.append(f"{prefix} {r['id']} 未經過（{expected_coverage}，最近 {offset}）；仍須其他案例涵蓋")
                continue
            require(coverage not in {"not_on_route", "different_branch"},
                    f"{prefix} {r['id']} 未涵蓋狀態與距離／分支證據不符；完整路線確實經過")
            if prefix in FIXED_HINT_CASES:
                require(is_number(along) and along >= 500, f"{prefix} {r['id']} 定向案例起點距提示點不足 500 m")
            require(r.get("coverage") == "covered" and is_number(route_distance) and route_distance <= 30,
                    f"{prefix} {r['id']} 未涵蓋：{r.get('coverage')}，路線最近距離 {route_distance!r} m；不能當成通過")
            require(r.get("hintID") == hint_id and r.get("matched") is True and r.get("triggered") is True,
                    f"{prefix} {r['id']} 沒有在正確分支觸發提示")
            require(r.get("displayedHint") == r.get("liveActivityHint") == short,
                    f"{prefix} {r['id']} 手機／Live Activity 短句不符")
            if not is_number(along):
                continue
            windows = [event for event in rows if event["event"] == "nav_hint" and event.get("hintID") == hint_id]
            require(any(event.get("text") == short and is_number(event.get("along"))
                        and abs(event["along"] - along) <= 300 for event in windows),
                    f"{prefix} {r['id']} 沒有實際 300m 內 navHint 事件，不能只信報告自稱顯示")
            spoken = [event for event in rows if event["event"] == "nav_speech" and event.get("hintID") == hint_id
                      and is_number(event.get("along")) and abs(event["along"] - along) <= 300]
            require(any(event.get("text", "").endswith(instruction) for event in spoken),
                    f"{prefix} {r['id']} 前後300m沒有對應的實際導航語音候選")
            speeches = r.get("speeches")
            require(isinstance(speeches, list) and bool(speeches), f"{prefix} {r['id']} 沒有前後300m語音清單")
            if isinstance(speeches, list):
                for event in spoken:
                    require(any(isinstance(speech, dict) and speech.get("text") == event.get("text")
                                and speech.get("hintID") == hint_id and speech.get("t") == event["t"] for speech in speeches),
                            f"{prefix} {r['id']} 語音清單遺漏實際事件")
            if len(errors) == previous_errors:
                covered_points.add(r["id"])
        by_hint = defaultdict(list)
        for r in rows:
            if r["event"] == "nav_speech" and r.get("hintID"):
                by_hint[r["hintID"]].append(r)
        for hint_id, spoken in by_hint.items():
            markers = [r.get("announcement") for r in spoken]
            require(all(is_number(marker) for marker in markers) and len(markers) == len(set(markers)),
                    f"{prefix} {hint_id} 同一點重複播報相同距離門檻")

    for key in HINT_POINTS:
        require(key in covered_points, f"提示點 {key} 所有案例都沒有通過實際覆蓋檢查")
    for item in sorted(required_coverage):
        require(item in covered_items, f"必驗項目「{item}」沒有任何案例實際涵蓋並驗到，不能宣稱通過")

    endpoints = []
    for prefix, expected in (("補測01", (ADDRESS_QUERY, STORE_QUERY)), ("補測02", (STORE_QUERY, ADDRESS_QUERY))):
        starts = events(prefix, "case_start")
        if len(starts) != 1:
            continue
        start = starts[0]
        require((start.get("fromQuery"), start.get("toQuery")) == expected, f"{prefix} 不是使用者的實際起終點搜尋")
        require(all(is_number(start.get(key)) for key in ("fromLat", "fromLon", "toLat", "toLon")),
                f"{prefix} 缺少實際搜尋結果座標")
        require(all(isinstance(start.get(key), str) and bool(start[key]) for key in ("fromName", "toName")),
                f"{prefix} 缺少實際門市／地址名稱")
        endpoints.append(start)
    if len(endpoints) == 2 and all(all(is_number(r.get(key)) for key in ("fromLat", "fromLon", "toLat", "toLon")) for r in endpoints):
        a, b = endpoints
        require(distance((a["fromLat"], a["fromLon"]), (b["toLat"], b["toLon"])) <= 1
                and distance((a["toLat"], a["toLon"]), (b["fromLat"], b["fromLon"])) <= 1,
                "不中斷去回程不是同一對搜尋結果反向")
    return errors


def check_text(text: str, *, information: list[str] | None = None) -> list[str]:
    records, errors = [], []
    for line_number, line in enumerate(text.splitlines(), 1):
        if MARKER not in line:
            continue
        try:
            records.append(json.loads(line.split(MARKER, 1)[1]))
        except ValueError as exc:
            errors.append(f"log 第 {line_number} 行 JSON 損壞：{exc}")
    return errors + check_records(records, information=information)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    args = parser.parse_args(argv)
    information = []
    try:
        raw = args.log.read_bytes()
        encoding = "utf-16" if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
        errors = check_text(raw.decode(encoding), information=information)
    except (OSError, UnicodeError) as exc:
        print(f"[失敗] 無法讀取 log：{exc}", file=sys.stderr)
        return 1
    for message in information:
        print(f"[資訊] {message}")
    for error in errors:
        print(f"[失敗] {error}", file=sys.stderr)
    if errors:
        return 1
    print("11/08 核心與資料 replay 檢查通過；不代表實機播放或 UI 驗收")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
