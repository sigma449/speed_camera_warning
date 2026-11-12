"""已查核官方來源的座標校正、方向別區間及建置稽核。"""
from __future__ import annotations

import re
import unicodedata

from .normalize import Camera, parse_coordinates, parse_direction, parse_float, parse_limit, pick
from .sections import SectionError, bearing, haversine, project_path

_NUMBERS = {"一": "1", "二": "2", "三": "3", "四": "4", "五": "5", "六": "6",
            "七": "7", "八": "8", "九": "9", "十": "10"}


def _text(value: str) -> str:
    return re.sub(r"\s+", "", unicodedata.normalize("NFKC", value)).replace("臺", "台")


def freeway_ref(address: str) -> str | None:
    match = re.search(r"國道([一二三四五六七八九十]|\d+)(?:號)?(甲)?", _text(address))
    if not match:
        return None
    return _NUMBERS.get(match[1], match[1]) + (match[2] or "")


def _camera_key(row: dict) -> tuple[str, float | None]:
    address = _text(pick(row, "address") or "")
    address = re.sub(r"國道([一二三四五六七八九十])號",
                     lambda m: "國道" + _NUMBERS[m[1]] + "號", address)
    return address, parse_direction(pick(row, "direction"))


def validate_freeway_rows(rows: list[dict]) -> None:
    required = {"設置地點", "座標緯度", "座標經度", "拍攝方向", "速限"}
    if not rows or not required <= rows[0].keys():
        raise ValueError("13940 缺少設置地點／座標／拍攝方向／速限欄位")
    if not any(freeway_ref(pick(r, "address") or "")
               and parse_coordinates(pick(r, "lat"), pick(r, "lon")) for r in rows):
        raise ValueError("13940 沒有可用的國道座標")


def apply_freeway_coordinates(rows: list[dict], official: list[dict], log=print) -> list[dict]:
    """只校正同名、同行向的國道點；沒有對應的主來源資料不刪除，也不擴充非測速類型。"""
    authority: dict[tuple, tuple] = {}
    ambiguous = set()
    for row in official:
        address = pick(row, "address") or ""
        if freeway_ref(address) is None:
            continue
        coords = parse_coordinates(pick(row, "lat"), pick(row, "lon"))
        if coords is None:
            log(f"[警告] 13940 座標無效，保留主來源：{address}｜{pick(row, 'lat')},{pick(row, 'lon')}")
            continue
        key = _camera_key(row)
        if key in authority and authority[key] != coords:
            ambiguous.add(key)
            log(f"[警告] 13940 同名同行向有多組座標，不自動校正：{address}")
        authority[key] = coords
    result = []
    corrected = 0
    for row in rows:
        key = _camera_key(row)
        if key not in authority or key in ambiguous:
            result.append(row)
            continue
        coords = authority[key]
        old = parse_coordinates(pick(row, "lat"), pick(row, "lon"))
        if old is None or haversine(*old, *coords) >= 1:
            log(f"國道來源衝突：{pick(row, 'address')}｜主來源 {old} → 13940 {coords}"
                + (f"（相差 {haversine(*old, *coords):.1f} m）" if old else ""))
            corrected += 1
        result.append(dict(row, Latitude=str(coords[0]), Longitude=str(coords[1])))
    log(f"13940 國道座標：校正 {corrected} 筆；沒有同名同行向對應的點保留主來源")
    return result


# 126156 只有北宜前三段，56.6–68.6K 不在此資料集，不能用里程牌冒充門架。
_NTPC_TARGETS = [
    ("台9線19K至23.1K", "beiyi-1", "北宜 19K–23.1K", "台9", 19, 23.1,
     [("往新店方向", "-r", "往台北"), ("往宜蘭方向", "-f", "往宜蘭")]),
    ("台9線26.2K至32.2K", "beiyi-2", "北宜 26.2K–32.2K", "台9", 26.2, 32.2,
     [("往新店方向", "-r", "往台北"), ("往宜蘭方向", "-f", "往宜蘭")]),
    ("台9線33.3K至37.2K", "beiyi-3", "北宜 33.3K–37.2K（坪林段）", "台9", 33.3, 37.2,
     [("往新店方向", "-r", "往台北"), ("往宜蘭方向", "-f", "往宜蘭")]),
    ("環河路(中央路至白馬寺", "ntpc-huanhe", "新店環河路 中央路至白馬寺", None, None, None,
     [("往碧潭方向", "-f", "往碧潭"), ("往台北方向", "-r", "往臺北")]),
    ("壽山路(北118線0K至1.2K)", "ntpc-shoushan", "新莊壽山路 北118線0K–1.2K", None, None, None,
     [("", "", "往新莊")]),
]


def parse_ntpc_sections(rows: list[dict]) -> list[dict]:
    result = []
    for needle, sid, name, road, start_km, end_km, directions in _NTPC_TARGETS:
        matches = [r for r in rows if needle in _text(r.get("location") or "")]
        if len(matches) != 1:
            raise SectionError(f"126156 {needle} 預期一列，實際 {len(matches)} 列")
        row = matches[0]
        count = len(directions)
        columns = [str(row.get(k) or "").split()
                   for k in ("start latitude", "start longitude", "end latitude", "end longitude")]
        if any(len(c) != count for c in columns):
            raise SectionError(f"126156 {needle} 雙端座標數量與方向不符，不能猜測配對")
        limit = parse_limit(row.get("limit"))
        if limit is None:
            raise SectionError(f"126156 {needle} 缺少速限")
        length_text = _text(row.get("length") or "")
        direction_map = {d[0]: d for d in directions}
        if count > 1:
            lengths = list(re.finditer(r"(往[^:]+方向):(\d+(?:\.\d+)?)公尺", length_text))
            if len(lengths) != count or {m[1] for m in lengths} != direction_map.keys():
                raise SectionError(f"126156 {needle} 公告長度無法配對方向")
            ordered = [(direction_map[m[1]], parse_float(m[2])) for m in lengths]
        else:
            length_match = re.fullmatch(r"(\d+(?:\.\d+)?)公尺", length_text)
            ordered = [(directions[0], parse_float(length_match[1]) if length_match else None)]
        for i, ((label, suffix, display), length) in enumerate(ordered):
            a = parse_coordinates(columns[0][i], columns[1][i])
            b = parse_coordinates(columns[2][i], columns[3][i])
            if not a or not b or not length or length <= 0 or a == b:
                raise SectionError(f"126156 {needle} {display} 座標或公告長度無效")
            section = {"id": sid + suffix, "name": f"{name}（{display}）",
                       "start": {"lat": a[0], "lon": a[1]}, "end": {"lat": b[0], "lon": b[1]},
                       "lengthMeters": length, "lengthEstimated": False, "speedLimit": limit,
                       "startHeading": round(bearing(*a, *b), 1)}
            if road:
                km_from, km_to = (end_km, start_km) if suffix == "-r" else (start_km, end_km)
                section.update(road=road, startKm=km_from, endKm=km_to)
            result.append(section)
    return result


def validate_ntpc_rows(rows: list[dict]) -> None:
    parse_ntpc_sections(rows)


def apply_ntpc_sections(sections: list[dict], official: list[dict], log=print) -> list[dict]:
    if not official:
        return sections
    replacements = {s["id"]: s for s in parse_ntpc_sections(official)}
    result = []
    for old in sections:
        new = replacements.pop(old["id"], None)
        if new:
            # 沒有里程牌路形時，保留已查核的局部進入方向，不用彎曲山路的起終點直線方位。
            if "startHeading" in old:
                new["startHeading"] = old["startHeading"]
            result.append(new)
        else:
            result.append(old)
    result += list(replacements.values())
    log("126156：套用北宜前 3 段各方向門架與公告長度，補新店環河路雙向及新莊壽山路")
    log("[警告] 126156 沒有北宜第 4 段 56.6K–68.6K 的門架；保留原里程牌端點，待官方雙端資料")
    return result


def _point(section: dict, key: str) -> tuple[float, float]:
    return section[key]["lat"], section[key]["lon"]


def _distance_to_path(point: tuple, path: list) -> float:
    return project_path(point, path)[1]


def audit_cameras(cameras: list[Camera], sections: list[dict], road_data: dict, log=print) -> None:
    groups = {re.sub(r"-[fr]$", "", s["id"]) for s in sections}
    for camera in cameras:
        if camera.type == "section" and camera.address == "蘇花改中仁隧道" and "zhongren-tunnel" in groups:
            camera.sectionGroupID = "zhongren-tunnel"
    uncovered = [c for c in cameras if c.type == "section" and c.sectionGroupID not in groups
                 and not any(_distance_to_path((c.lat, c.lon), s.get("path") or
                                               [_point(s, "start"), _point(s, "end")]) <= 300 for s in sections)]
    log(f"區間照相機沒有對應區間：{len(uncovered)} 處（保留固定照相提醒）")
    for c in uncovered:
        log(f"  [待查] id={c.id} {c.address}｜{c.lat:.6f},{c.lon:.6f}")

    named = road_data.get("namedRoads", [])
    for c in cameras:
        ref = freeway_ref(c.address)
        if ref is None:
            continue
        paths = [line for road in named if road.get("freewayRef") == ref for line in road["lines"]]
        if not paths:
            log(f"  [警告] 國道座標無法稽核：id={c.id} {c.address}｜缺少國道{ref}線形")
        else:
            distance = min(_distance_to_path((c.lat, c.lon), p) for p in paths)
            if distance > 150:
                log(f"  [警告] 國道座標異常：id={c.id} {c.address}｜{c.lat:.6f},{c.lon:.6f}"
                    f"｜離國道{ref}主線 {distance:.1f} m，需人工確認（不自動刪除）")
