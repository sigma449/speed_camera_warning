"""區間測速資料：由人工維護的 manual/sections.csv 提供。

CSV 欄位（# 開頭的行會被忽略）：
id,name,start_lat,start_lon,end_lat,end_lon,length_m,speed_limit,note,road,start_km,end_km,bidirectional,forward_label,reverse_label

起終點有兩種寫法，擇一即可：
1. 直接填座標：start_lat、start_lon、end_lat、end_lon
2. 填省道里程：road（例如「台9」）、start_km、end_km（例如 19、23.1）
   程式會用公路局「省道里程坐標」資料把里程換算成座標，並在 log 印出結果；
   確認無誤後可以把座標填回 CSV，之後就不必每次下載里程牌資料。

- length_m：官方公告的區間長度（公尺）。留空時：
  - 有填里程 → 用里程差計算（例如 23.1K − 19K = 4,100 m）
  - 只有座標 → 用直線距離 × 1.15 估算，標示 lengthEstimated=true（App 會再用 Apple 地圖修正）
- bidirectional：填 yes／是／1 表示雙向取締，會產生兩段（順向與反向）。
- forward_label／reverse_label：兩個方向的名稱（例如「往宜蘭」「往台北」），會加在區間名稱後面。
- forward_heading／reverse_heading：進入區間時的道路方向（方位角，選填）。
  有填里程時會自動用起點附近 100 m 的里程牌計算；山路彎曲時，比用起終點直線方向準確得多。
"""
from __future__ import annotations

import csv
import io
import math
from typing import Callable, Optional

from .normalize import in_taiwan, parse_float

R = 6371008.8
ESTIMATE_FACTOR = 1.15
TRUE_WORDS = {"yes", "y", "true", "1", "是", "雙向"}

# (道路, 公里) → (緯度, 經度)；找不到回傳 None
Resolver = Callable[[str, float], Optional[tuple]]


def bearing(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def _local_heading(resolver: Optional[Resolver], road: str, km: float, toward_km: float) -> Optional[float]:
    """從 km 往 toward_km 方向前進 100 m 的道路方位角（用里程牌座標計算）。"""
    if resolver is None:
        return None
    step = 0.1 if toward_km > km else -0.1
    a, b = resolver(road, km), resolver(road, round(km + step, 4))
    if a is None or b is None:
        return None
    return round(bearing(a[0], a[1], b[0], b[1]), 1)


def haversine(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R * math.asin(min(1.0, math.sqrt(a)))


class SectionError(ValueError):
    pass


def _rows(text: str) -> list[dict]:
    lines = [ln for ln in text.splitlines() if ln.strip() and not ln.lstrip().startswith("#")]
    if not lines:
        return []
    return [dict(r) for r in csv.DictReader(io.StringIO("\n".join(lines)))]


def needs_mileposts(text: str) -> bool:
    """CSV 裡是否有只填里程、還沒有座標的區間。"""
    for row in _rows(text):
        has_coords = all(parse_float(row.get(k)) is not None for k in ("start_lat", "start_lon", "end_lat", "end_lon"))
        has_km = (row.get("road") or "").strip() and parse_float(row.get("start_km")) is not None
        if not has_coords and has_km:
            return True
    return False


def parse_sections_csv(text: str, resolver: Optional[Resolver] = None, log=print) -> list[dict]:
    sections: list[dict] = []
    seen = set()
    for i, row in enumerate(_rows(text), start=2):
        sid = (row.get("id") or "").strip()
        if not sid:
            raise SectionError(f"第 {i} 行缺少 id")
        if sid in seen:
            raise SectionError(f"id 重複：{sid}")
        seen.add(sid)
        name = (row.get("name") or sid).strip()

        coords = {k: parse_float(row.get(k)) for k in ("start_lat", "start_lon", "end_lat", "end_lon")}
        road = (row.get("road") or "").strip()
        start_km, end_km = parse_float(row.get("start_km")), parse_float(row.get("end_km"))
        has_km = bool(road) and start_km is not None and end_km is not None

        if any(v is None for v in coords.values()):
            if not has_km:
                raise SectionError(f"{sid}：起終點座標不完整（也沒有填 road／start_km／end_km）")
            if resolver is None:
                raise SectionError(f"{sid}：需要里程牌資料才能換算座標")
            a, b = resolver(road, start_km), resolver(road, end_km)
            if a is None or b is None:
                raise SectionError(f"{sid}：里程牌資料找不到 {road} {start_km}K 或 {end_km}K")
            coords = {"start_lat": a[0], "start_lon": a[1], "end_lat": b[0], "end_lon": b[1]}
            log(f"區間 {sid}（{name}）：{road} {start_km}K → {a[0]:.6f},{a[1]:.6f}；"
                f"{end_km}K → {b[0]:.6f},{b[1]:.6f}")

        if not (in_taiwan(coords["start_lat"], coords["start_lon"]) and in_taiwan(coords["end_lat"], coords["end_lon"])):
            raise SectionError(f"{sid}：座標不在台灣範圍內")
        limit = parse_float(row.get("speed_limit"))
        if limit is None or not (10 <= limit <= 130):
            raise SectionError(f"{sid}：速限不合理")

        length: Optional[float] = parse_float(row.get("length_m"))
        estimated = False
        if length is None or length <= 0:
            if has_km:
                length = abs(end_km - start_km) * 1000
            else:
                length = haversine(coords["start_lat"], coords["start_lon"],
                                   coords["end_lat"], coords["end_lon"]) * ESTIMATE_FACTOR
                estimated = True

        start = {"lat": round(coords["start_lat"], 6), "lon": round(coords["start_lon"], 6)}
        end = {"lat": round(coords["end_lat"], 6), "lon": round(coords["end_lon"], 6)}
        base = {"lengthMeters": round(length, 1), "speedLimit": int(limit), "lengthEstimated": estimated}

        fwd_heading = parse_float(row.get("forward_heading"))
        rev_heading = parse_float(row.get("reverse_heading"))
        if has_km:
            if fwd_heading is None:
                fwd_heading = _local_heading(resolver, road, start_km, end_km)
            if rev_heading is None:
                rev_heading = _local_heading(resolver, road, end_km, start_km)
            if fwd_heading is not None or rev_heading is not None:
                log(f"  {sid} 進入方向：順向 {fwd_heading}°、反向 {rev_heading}°")

        def with_heading(d: dict, h: Optional[float]) -> dict:
            if h is not None:
                d["startHeading"] = h
            return d

        if (row.get("bidirectional") or "").strip().lower() in TRUE_WORDS:
            fwd = (row.get("forward_label") or "順向").strip()
            rev = (row.get("reverse_label") or "反向").strip()
            sections.append(with_heading({"id": f"{sid}-f", "name": f"{name}（{fwd}）",
                                          "start": start, "end": end, **base}, fwd_heading))
            sections.append(with_heading({"id": f"{sid}-r", "name": f"{name}（{rev}）",
                                          "start": end, "end": start, **base}, rev_heading))
        else:
            sections.append(with_heading({"id": sid, "name": name, "start": start, "end": end, **base}, fwd_heading))
    return sections


def load_sections(path: str, log=print, fetch_index=None) -> list[dict]:
    """讀取 sections.csv。需要換算里程時才下載里程牌資料；下載失敗時略過那些區間並警告。"""
    try:
        with open(path, encoding="utf-8-sig") as f:
            text = f.read()
    except FileNotFoundError:
        return []

    resolver: Optional[Resolver] = None
    if needs_mileposts(text):
        try:
            if fetch_index is None:
                from .mileposts import fetch_index as fetch_index  # 延遲載入，避免不需要時連網
            index = fetch_index(log=log)
            resolver = index.resolve
        except Exception as exc:  # noqa: BLE001
            log(f"[警告] 里程牌資料無法取得，只填里程的區間會被略過：{exc}")

    sections: list[dict] = []
    for row_text in _split_rows(text):
        try:
            sections += parse_sections_csv(row_text, resolver=resolver, log=log)
        except SectionError as exc:
            if resolver is None and "里程牌" in str(exc):
                log(f"[警告] 略過：{exc}")
                continue
            raise
    ids = [s["id"] for s in sections]
    dup = sorted({i for i in ids if ids.count(i) > 1})
    if dup:
        raise SectionError(f"id 重複：{', '.join(dup)}")
    return sections


def uses_mileposts(path: str) -> bool:
    """CSV 裡是否有以省道里程定義的區間（用來決定要不要標示里程牌資料的出處）。"""
    try:
        with open(path, encoding="utf-8-sig") as f:
            return any((row.get("road") or "").strip() for row in _rows(f.read()))
    except FileNotFoundError:
        return False


def _split_rows(text: str) -> list[str]:
    """把 CSV 拆成「表頭＋單一資料列」的小段，讓單一區間失敗時不影響其他區間。"""
    lines = [ln for ln in text.splitlines() if ln.strip() and not ln.lstrip().startswith("#")]
    if len(lines) < 2:
        return []
    header = lines[0]
    return [header + "\n" + ln for ln in lines[1:]]
