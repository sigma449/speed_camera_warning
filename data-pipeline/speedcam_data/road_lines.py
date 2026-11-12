"""國道和白牌不走的道路的線形：從 OpenStreetMap 取得，App 用來判斷路線有沒有走到這些路。

只取主線，不取匝道：快速道路常和國道共用交流道，把匝道算進去會誤判成走國道。
"""
from __future__ import annotations

import csv
import io
import json
import math
import urllib.parse
import urllib.request
from typing import Iterable

from .sections import simplify_path
from .sources import USER_AGENT

OVERPASS_URL = "https://overpass-api.de/api/interpreter"
_BBOX = "21.8,119.9,25.4,122.1"
OVERPASS_QUERY = (
    "[out:json][timeout:240];("
    f'way["highway"~"^(motorway|trunk)$"]({_BBOX});'
    f'way["highway"="primary"]["name"="安朔高架橋"]({_BBOX});'
    ");out tags geom;"
)
ATTRIBUTION = "國道線形：© OpenStreetMap 貢獻者（ODbL，openstreetmap.org/copyright）"

# OSM 把國道標成 highway=motorway，編號放在 ref。高雄港聯外高架也是 motorway，但不是國道（沒有 ref）。
FREEWAY_REFS = {"1", "2", "2甲", "3", "3甲", "4", "5", "6", "8", "10"}
# 少於這個數量就當作下載的資料有問題（目前約 2,100 km）
MIN_FREEWAY_KM = 1_500


def fetch_elements(timeout: float = 280) -> list[dict]:
    body = urllib.parse.urlencode({"data": OVERPASS_QUERY}).encode()
    req = urllib.request.Request(OVERPASS_URL, data=body, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310（固定網址）
        return json.loads(resp.read().decode("utf-8"))["elements"]


def is_freeway(tags: dict) -> bool:
    return tags.get("highway") == "motorway" and tags.get("ref", "").strip() in FREEWAY_REFS


def is_restricted(tags: dict, restricted_names: set[str]) -> bool:
    """白牌不走的路。同一條路有些路段開放機車（OSM 標示 motorcycle=yes），那些路段不算。"""
    return tags.get("name") in restricted_names and tags.get("motorcycle") not in ("yes", "designated")


def parse_restricted_names(text: str) -> set[str]:
    """manual/white_plate_restricted.csv 的道路名稱（# 開頭的行會被忽略）。"""
    lines = [line for line in text.splitlines() if line.strip() and not line.lstrip().startswith("#")]
    return {row["name"].strip() for row in csv.DictReader(io.StringIO("\n".join(lines))) if row.get("name", "").strip()}


def _segment_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    dy = (b[0] - a[0]) * 110_950
    dx = (b[1] - a[1]) * 111_320 * math.cos(math.radians(a[0]))
    return math.hypot(dx, dy)


def line_length_km(line: list[tuple[float, float]]) -> float:
    return sum(_segment_m(a, b) for a, b in zip(line, line[1:])) / 1000


def _way_points(element: dict) -> list[tuple[float, float]]:
    return [(g["lat"], g["lon"]) for g in element.get("geometry", [])]


def merge_lines(lines: Iterable[list[tuple[float, float]]]) -> list[list[tuple[float, float]]]:
    """把頭尾相接的線段接成一條，簡化後的點比較少，也不會在接點斷開。"""
    pending = [list(line) for line in lines if len(line) >= 2]
    by_start: dict[tuple[float, float], list[int]] = {}
    for i, line in enumerate(pending):
        by_start.setdefault(line[0], []).append(i)
    has_previous = set()
    for line in pending:
        for j in by_start.get(line[-1], []):
            has_previous.add(j)

    used = set()
    merged = []

    def walk(start: int) -> None:
        used.add(start)
        chain = list(pending[start])
        while True:
            following = [j for j in by_start.get(chain[-1], []) if j not in used]
            if not following:
                break
            used.add(following[0])
            chain += pending[following[0]][1:]
        merged.append(chain)

    for i in range(len(pending)):
        if i not in has_previous and i not in used:
            walk(i)
    # 剩下的是繞回自己的環
    for i in range(len(pending)):
        if i not in used:
            walk(i)
    return merged


def _rounded(line: list[tuple[float, float]]) -> list[list[float]]:
    # 小數 5 位約 1 m，比對的容許距離是 30 m，夠用
    return [[round(lat, 5), round(lon, 5)] for lat, lon in line]


def build_road_lines(elements: list[dict], restricted_names: set[str], generated_at: str,
                     tolerance_m: float = 3.0, log=print) -> dict:
    """tolerance_m 要遠小於 App 判斷「貼著線形」的 10 m（RoadMatcher.closeOffset），不然簡化本身就會造成偏差。"""
    freeways, restricted = [], []
    named: dict[tuple[str, str | None], list] = {}
    found_names = set()
    for el in elements:
        if el.get("type") != "way":
            continue
        tags = el.get("tags", {})
        points = _way_points(el)
        if is_freeway(tags):
            freeways.append(points)
        elif is_restricted(tags, restricted_names):
            found_names.add(tags["name"])
            restricted.append(points)
        if len(points) >= 2:
            if is_freeway(tags):
                ref = tags["ref"].strip()
                named.setdefault((f"國道{ref}號", ref), []).append(points)
            elif tags.get("name") and tags.get("highway") in ("motorway", "trunk"):
                named.setdefault((tags["name"], None), []).append(points)

    missing = restricted_names - found_names
    if missing:
        log(f"[警告] OSM 找不到這些白牌限制道路：{sorted(missing)}")

    def finish(lines: list) -> list[list[list[float]]]:
        return [_rounded(simplify_path(line, tolerance_m)) for line in merge_lines(lines)]

    result = {
        "generatedAt": generated_at,
        "attribution": ATTRIBUTION,
        "freeways": finish(freeways),
        "whitePlateRestricted": finish(restricted),
        "namedRoads": [dict(name=name, lines=finish(lines), **({"freewayRef": ref} if ref else {}))
                       for (name, ref), lines in sorted(named.items(), key=lambda item: (item[0][0], item[0][1] or ""))],
    }
    freeway_km = sum(line_length_km([tuple(p) for p in line]) for line in result["freeways"])
    restricted_km = sum(line_length_km([tuple(p) for p in line]) for line in result["whitePlateRestricted"])
    points = sum(len(line) for key in ("freeways", "whitePlateRestricted") for line in result[key])
    log(f"國道 {freeway_km:.0f} km（{len(result['freeways'])} 條線），"
        f"白牌限制道路 {restricted_km:.0f} km（{len(result['whitePlateRestricted'])} 條線），共 {points} 個點")
    return result


def dumps(data: dict) -> str:
    """一條線一行，有變動時 diff 看得懂，也不會有多餘的空白。"""

    def lines_json(lines: list) -> str:
        if not lines:
            return "[]"
        body = ",\n".join("  " + json.dumps(line, ensure_ascii=False, separators=(",", ":")) for line in lines)
        return "[\n" + body + "\n ]"

    return (
        "{\n"
        f' "generatedAt": {json.dumps(data["generatedAt"])},\n'
        f' "attribution": {json.dumps(data["attribution"], ensure_ascii=False)},\n'
        f' "freeways": {lines_json(data["freeways"])},\n'
        f' "whitePlateRestricted": {lines_json(data["whitePlateRestricted"])},\n'
        f' "namedRoads": {json.dumps(data["namedRoads"], ensure_ascii=False, separators=(",", ":"))}\n'
        "}\n"
    )
