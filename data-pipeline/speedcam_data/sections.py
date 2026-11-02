"""區間測速資料：目前由人工維護的 manual/sections.csv 提供。

CSV 欄位：
id,name,start_lat,start_lon,end_lat,end_lon,length_m,speed_limit,note
- length_m 留空時，會用起終點直線距離 × 1.15 估算，並標示 lengthEstimated=true
  （App 會再用 Apple 地圖的道路距離修正）。
- 以 # 開頭的行會被忽略。
"""
from __future__ import annotations

import csv
import io
import math
from typing import Optional

from .normalize import in_taiwan, parse_float

R = 6371008.8
ESTIMATE_FACTOR = 1.15


def haversine(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R * math.asin(min(1.0, math.sqrt(a)))


class SectionError(ValueError):
    pass


def parse_sections_csv(text: str) -> list[dict]:
    lines = [ln for ln in text.splitlines() if ln.strip() and not ln.lstrip().startswith("#")]
    if not lines:
        return []
    reader = csv.DictReader(io.StringIO("\n".join(lines)))
    sections = []
    seen = set()
    for i, row in enumerate(reader, start=2):
        sid = (row.get("id") or "").strip()
        if not sid:
            raise SectionError(f"第 {i} 行缺少 id")
        if sid in seen:
            raise SectionError(f"id 重複：{sid}")
        seen.add(sid)
        vals = {k: parse_float(row.get(k)) for k in ("start_lat", "start_lon", "end_lat", "end_lon")}
        if any(v is None for v in vals.values()):
            raise SectionError(f"{sid}：起終點座標不完整")
        if not (in_taiwan(vals["start_lat"], vals["start_lon"]) and in_taiwan(vals["end_lat"], vals["end_lon"])):
            raise SectionError(f"{sid}：座標不在台灣範圍內")
        limit = parse_float(row.get("speed_limit"))
        if limit is None or not (10 <= limit <= 130):
            raise SectionError(f"{sid}：速限不合理")
        length: Optional[float] = parse_float(row.get("length_m"))
        estimated = False
        if length is None or length <= 0:
            length = haversine(vals["start_lat"], vals["start_lon"], vals["end_lat"], vals["end_lon"]) * ESTIMATE_FACTOR
            estimated = True
        sections.append({
            "id": sid,
            "name": (row.get("name") or sid).strip(),
            "start": {"lat": vals["start_lat"], "lon": vals["start_lon"]},
            "end": {"lat": vals["end_lat"], "lon": vals["end_lon"]},
            "lengthMeters": round(length, 1),
            "speedLimit": int(limit),
            "lengthEstimated": estimated,
        })
    return sections


def load_sections(path: str) -> list[dict]:
    try:
        with open(path, encoding="utf-8-sig") as f:
            return parse_sections_csv(f.read())
    except FileNotFoundError:
        return []
