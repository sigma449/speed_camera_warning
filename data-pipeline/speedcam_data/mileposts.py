"""省道里程牌座標：把「台9線 19.0K」這類里程換算成經緯度。

資料來源：公路局「省道里程坐標(里程牌標誌)」（政府資料開放平臺資料集 7040），
包含整公里、半公里、百公尺里程牌，每月由公路基本資料庫匯出。
欄位名稱可能隨版本調整，所以用關鍵字辨識欄位，並在 log 印出欄位名稱方便除錯。
"""
from __future__ import annotations

import re
from typing import Iterable, Optional

from . import sources
from .normalize import in_taiwan, parse_float

MILEPOST_DATASET_ID = "7040"
ATTRIBUTION = "交通部公路局「省道里程坐標(里程牌標誌)」，政府資料開放授權條款－第1版（https://data.gov.tw/license）"


def normalize_road(text: Optional[str]) -> Optional[str]:
    """「臺9線」「台009」「省道台9線」「9」→「台9」；保留甲乙丙丁等支線字尾。"""
    if not text:
        return None
    s = re.sub(r"\s+", "", str(text)).replace("臺", "台")
    m = re.search(r"(?:台)?0*(\d{1,3})([甲乙丙丁戊己庚辛壬癸]?)", s)
    if not m:
        return None
    return f"台{int(m.group(1))}{m.group(2)}"


def parse_km(text: Optional[str]) -> Optional[float]:
    """「019K+100」「19K+100」「19+100」「19.1」「19K」「19.1K」→ 19.1（公里）。"""
    if text is None:
        return None
    s = re.sub(r"\s+", "", str(text)).upper()
    m = re.fullmatch(r"0*(\d+(?:\.\d+)?)K?\+0*(\d+(?:\.\d+)?)M?", s)
    if m:
        return round(float(m.group(1)) + float(m.group(2)) / 1000, 4)
    m = re.fullmatch(r"0*(\d+(?:\.\d+)?)K?M?", s)
    if m:
        return round(float(m.group(1)), 4)
    return None


def _find_column(headers: list[str], *candidates: Iterable[str]) -> Optional[str]:
    """依序嘗試每組關鍵字：欄位名稱包含該組所有關鍵字（不分大小寫）即採用。"""
    lowered = {h: h.lower() for h in headers}
    for group in candidates:
        for h, low in lowered.items():
            if all(k.lower() in low for k in group):
                return h
    return None


class MilepostIndex:
    """(道路, 公里) → (緯度, 經度)。同一里程有多筆（例如道路兩側）時取平均。"""

    def __init__(self) -> None:
        self._points: dict[str, dict[float, list[tuple[float, float]]]] = {}

    def add(self, road: str, km: float, lat: float, lon: float) -> None:
        self._points.setdefault(road, {}).setdefault(round(km, 3), []).append((lat, lon))

    def roads(self) -> list[str]:
        return sorted(self._points)

    def count(self) -> int:
        return sum(len(v) for v in self._points.values())

    def _sorted(self, road: str) -> list[tuple[float, float, float]]:
        out = []
        for km, pts in self._points.get(road, {}).items():
            lat = sum(p[0] for p in pts) / len(pts)
            lon = sum(p[1] for p in pts) / len(pts)
            out.append((km, lat, lon))
        out.sort()
        return out

    def resolve(self, road: str, km: float, max_gap_km: float = 1.0) -> Optional[tuple[float, float]]:
        """找出里程的座標；沒有剛好的里程牌時，用前後最近的兩支（間距 ≤ 1 公里）線性內插。"""
        pts = self._sorted(road)
        if not pts:
            return None
        for k, lat, lon in pts:
            if abs(k - km) < 0.0005:
                return (lat, lon)
        before = [p for p in pts if p[0] < km]
        after = [p for p in pts if p[0] > km]
        if not before or not after:
            return None
        k1, lat1, lon1 = before[-1]
        k2, lat2, lon2 = after[0]
        if k2 - k1 > max_gap_km:
            return None
        t = (km - k1) / (k2 - k1)
        return (lat1 + (lat2 - lat1) * t, lon1 + (lon2 - lon1) * t)


def build_index(rows: list[dict], log=print) -> MilepostIndex:
    index = MilepostIndex()
    if not rows:
        return index
    headers = [h.replace("﻿", "").strip() for h in rows[0].keys() if h is not None]
    road_col = _find_column(headers, ("公路編號",), ("路線編號",), ("公路",), ("路線",), ("road",))
    km_col = _find_column(headers, ("起點樁號",), ("樁號",), ("里程",), ("牌面",), ("km",), ("mile",))
    # 實際欄位（2026-11）：坐標-E-WGS84（經度）、坐標-N-WGS84（緯度）
    lon_col = _find_column(headers, ("wgs84", "-e"), ("wgs84", "x"), ("wgs84", "經度"), ("wgs84", "lon"),
                           ("經度",), ("lon",))
    lat_col = _find_column(headers, ("wgs84", "-n"), ("wgs84", "y"), ("wgs84", "緯度"), ("wgs84", "lat"),
                           ("緯度",), ("lat",))
    log(f"里程牌欄位：{headers}")
    log(f"  採用：道路={road_col}、里程={km_col}、經度={lon_col}、緯度={lat_col}")
    for sample in rows[:3]:
        clean = {(k or "").replace("\ufeff", "").strip(): v for k, v in sample.items()}
        log(f"  範例：{ {c: clean.get(c) for c in (road_col, km_col, lon_col, lat_col) if c} }")
    if not all([road_col, km_col, lon_col, lat_col]):
        raise ValueError("里程牌資料找不到必要欄位")
    skipped = 0
    for raw in rows:
        row = {(k or "").replace("﻿", "").strip(): v for k, v in raw.items()}
        road = normalize_road(row.get(road_col))
        km = parse_km(row.get(km_col))
        lat, lon = parse_float(row.get(lat_col)), parse_float(row.get(lon_col))
        if lat is not None and lon is not None and not in_taiwan(lat, lon) and in_taiwan(lon, lat):
            lat, lon = lon, lat
        if road is None or km is None or lat is None or lon is None or not in_taiwan(lat, lon):
            skipped += 1
            continue
        index.add(road, km, lat, lon)
    log(f"  里程牌 {index.count()} 處（{len(index.roads())} 條道路），略過 {skipped} 筆")
    return index


def fetch_index(log=print) -> MilepostIndex:
    """下載資料集 7040 並建立索引。依序嘗試 CSV／JSON 下載連結。"""
    errors = []
    for url, fmt in sources.dataset_download_urls(MILEPOST_DATASET_ID):
        if fmt.upper() not in ("CSV", "JSON") and not url.lower().endswith((".csv", ".json")):
            continue
        try:
            log(f"下載里程牌資料 {url}")
            rows = sources.parse_payload(sources.http_get(url, timeout=120), fmt or url)
            index = build_index(rows, log=log)
            if index.count() > 0:
                return index
        except Exception as exc:  # noqa: BLE001
            errors.append(f"{url}: {exc}")
            log(f"  失敗：{exc}")
    raise RuntimeError("里程牌資料下載失敗：\n" + "\n".join(errors))
