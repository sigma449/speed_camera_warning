"""把各種格式的測速照相原始資料整理成 App 使用的統一格式。

政府開放資料的欄位名稱並不一致：全國版（警政署「測速執法設置點」）使用英文欄位
CityName / RegionName / Address / DeptNm / BranchNm / Longitude / Latitude / direct / limit，
各縣市版本則常用中文欄位（設置地點、座標經度、拍攝方向、速限…）。這裡統一處理。
"""
from __future__ import annotations

import hashlib
import math
import re
from dataclasses import dataclass, field
from typing import Iterable, Optional

# ---------------------------------------------------------------------------
# 欄位對應
# ---------------------------------------------------------------------------
FIELD_ALIASES: dict[str, list[str]] = {
    "city": ["CityName", "縣市", "設置縣市", "縣市別", "縣市名稱"],
    "district": ["RegionName", "行政區", "設置市區鄉鎮", "鄉鎮市區", "鄉鎮市區名稱"],
    "address": ["Address", "設置地址", "設置地點", "地點", "位置", "設置位置", "地址"],
    "lon": ["Longitude", "經度", "座標經度", "lon", "Lon", "X", "TWD97經度"],
    "lat": ["Latitude", "緯度", "座標緯度", "lat", "Lat", "Y", "TWD97緯度"],
    "direction": ["direct", "Direct", "拍攝方向", "方向", "取締方向", "行車方向"],
    "limit": ["limit", "Limit", "速限", "限速", "速限(公里)"],
    "kind": ["取締項目", "類型", "設備類型", "執法項目", "type"],
}


def _clean_key(k: str) -> str:
    return k.replace("﻿", "").strip()


def pick(row: dict, logical: str) -> Optional[str]:
    """依別名找出欄位值（去除前後空白），找不到回傳 None。"""
    cleaned = {_clean_key(k): v for k, v in row.items() if k is not None}
    for alias in FIELD_ALIASES[logical]:
        if alias in cleaned and cleaned[alias] is not None:
            value = str(cleaned[alias]).strip()
            if value != "":
                return value
    return None


# ---------------------------------------------------------------------------
# 座標
# ---------------------------------------------------------------------------
# (min_lat, max_lat, min_lon, max_lon)
TAIWAN_BOXES = [
    (21.8, 25.4, 119.3, 122.1),   # 台灣本島、澎湖、綠島、蘭嶼
    (24.3, 24.6, 118.1, 118.5),   # 金門
    (25.9, 26.4, 119.8, 120.6),   # 馬祖
]


def in_taiwan(lat: float, lon: float) -> bool:
    return any(a <= lat <= b and c <= lon <= d for a, b, c, d in TAIWAN_BOXES)


def parse_float(value: Optional[str]) -> Optional[float]:
    if value is None:
        return None
    try:
        f = float(str(value).strip().replace(",", ""))
    except ValueError:
        return None
    return f if math.isfinite(f) else None


def parse_coordinates(lat_raw: Optional[str], lon_raw: Optional[str]) -> Optional[tuple[float, float]]:
    """解析經緯度；如果經緯度欄位填反了會自動對調；不在台灣範圍內回傳 None。"""
    lat, lon = parse_float(lat_raw), parse_float(lon_raw)
    if lat is None or lon is None:
        return None
    if not in_taiwan(lat, lon) and in_taiwan(lon, lat):
        lat, lon = lon, lat
    if not in_taiwan(lat, lon):
        return None
    return lat, lon


# ---------------------------------------------------------------------------
# 方向
# ---------------------------------------------------------------------------
COMPASS = {"北": 0, "東北": 45, "東": 90, "東南": 135, "南": 180, "西南": 225, "西": 270, "西北": 315}
_C = "(東北|東南|西北|西南|東|西|南|北)"
_BOTH_WORDS = ("雙向", "往返", "雙方向", "兩向", "全向")


def parse_direction(text: Optional[str]) -> Optional[float]:
    """把「北向南」「南下」「往東」「西向」之類的文字轉成車輛行進的方位角。

    無法判斷或雙向時回傳 None（App 端會改用「照相點在前方」的判斷）。
    """
    if not text:
        return None
    s = re.sub(r"\s+", "", str(text))
    s = s.replace("方向", "").replace("車道", "").replace("行駛", "行")
    if any(w in s for w in _BOTH_WORDS):
        return None

    # 同一欄出現多個方向（例如「東向西、西向東」）→ 視為雙向
    pairs = re.findall(_C + "(?:向|往|至|到|→|->)" + _C, s)
    if len(pairs) > 1 and len({p[1] for p in pairs}) > 1:
        return None
    if pairs:
        return float(COMPASS[pairs[0][1]])

    m = re.search("(?:往|向|朝)" + _C, s)          # 往北、向南
    if m:
        return float(COMPASS[m.group(1)])
    m = re.search(_C + "(?:上|下|行|向|側往|bound)", s)  # 北上、南下、東行、北向
    if m:
        return float(COMPASS[m.group(1)])
    m = re.fullmatch(_C, s)                          # 只寫「北」
    if m:
        return float(COMPASS[m.group(1)])
    return None


def parse_axis(text: Optional[str]) -> Optional[float]:
    """雙向照相若註明「南北雙向」「東西雙向」，回傳取締的道路軸向（0 = 南北、90 = 東西）。

    App 會用它排除橫向道路的車（例如開在東西向道路時，不提醒南北向道路上的照相）。
    """
    if not text:
        return None
    s = re.sub(r"\s+", "", str(text))
    if "南北" in s or "北南" in s:
        return 0.0
    if "東西" in s or "西東" in s:
        return 90.0
    return None


# ---------------------------------------------------------------------------
# 速限與類型
# ---------------------------------------------------------------------------
def parse_limit(text: Optional[str]) -> Optional[int]:
    """取出速限數字；有多個數字時（例如「大型車60/小型車70」）取較小值，比較保守。"""
    if not text:
        return None
    nums = [int(n) for n in re.findall(r"\d{2,3}", str(text))]
    nums = [n for n in nums if 10 <= n <= 130]
    return min(nums) if nums else None


def detect_type(kind: Optional[str], address: Optional[str], direction: Optional[str] = None) -> str:
    # 方向欄位有時也會註明「(區間測速)」「(超速闖紅燈)」，一併納入判斷。
    text = f"{kind or ''} {address or ''} {direction or ''}"
    if "區間" in text:
        return "section"
    if "闖紅燈" in text and ("測速" in text or "超速" in text):
        return "redLightSpeed"
    if "闖紅燈" in text:
        return "redLight"
    if any(w in text for w in ("科技執法", "不停讓", "違規轉彎", "違規停車", "未依標誌")):
        return "tech"
    if "流動" in text:
        return "mobile"
    return "fixed"


# ---------------------------------------------------------------------------
# 高架／平面
# ---------------------------------------------------------------------------
# App 只用經緯度判斷，分不出高架和下面的平面道路，兩邊的照相點會互相誤報。
# 先在資料裡標出來，提醒時說「高架測速照相」「平面測速照相」，讓駕駛自己判斷。
_SURFACE_WORDS = ("高架下", "高架橋下", "平面道路", "平面車道", "(平面)", "（平面）")
_ELEVATED_UNSURE = ("高架橋前", "高架前")   # 在高架入口前的平面路段，不標示
SURFACE_NEAR_ELEVATED_M = 350


def parse_level(address: Optional[str]) -> Optional[str]:
    """從地址判斷照相點在高架（elevated）還是平面（surface）；看不出來回傳 None。

    - 「市民高架道下建國南路」是高架上的照相點（「下」指往建國南路的下匝道），不是高架下方。
    - 「台65線高架下」才是高架下方的平面道路。
    """
    if not address:
        return None
    s = re.sub(r"\s+", "", address)
    if any(w in s for w in _SURFACE_WORDS):
        return "surface"
    if "高架" in s and not any(w in s for w in _ELEVATED_UNSURE):
        return "elevated"
    return None


def _distance_m(a_lat: float, a_lon: float, b_lat: float, b_lon: float) -> float:
    p1, p2 = math.radians(a_lat), math.radians(b_lat)
    dp, dl = p2 - p1, math.radians(b_lon - a_lon)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * 6371008.8 * math.asin(min(1.0, math.sqrt(h)))


def mark_surface_near_elevated(cameras: list, radius_m: float = SURFACE_NEAR_ELEVATED_M) -> int:
    """高架照相點附近（radius_m 內）沒有標示的照相點，視為下方或旁邊的平面道路。回傳標示的數量。"""
    elevated = [c for c in cameras if c.level == "elevated"]
    count = 0
    for c in cameras:
        if c.level is None and any(_distance_m(c.lat, c.lon, e.lat, e.lon) <= radius_m for e in elevated):
            c.level = "surface"
            count += 1
    return count


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
@dataclass
class Camera:
    id: str
    type: str
    lat: float
    lon: float
    heading: Optional[float]
    speedLimit: Optional[int]
    address: str
    city: Optional[str] = None
    district: Optional[str] = None
    # 雙向照相的道路軸向（0 = 南北、90 = 東西），有 heading 時不使用
    axis: Optional[float] = None
    # 高架（elevated）或平面（surface）；只在兩者可能混淆的地方標示
    level: Optional[str] = None

    def to_json(self) -> dict:
        d = {
            "id": self.id,
            "type": self.type,
            "lat": round(self.lat, 6),
            "lon": round(self.lon, 6),
            "address": self.address,
        }
        if self.heading is not None:
            d["heading"] = self.heading
        elif self.axis is not None:
            d["axis"] = self.axis
        if self.speedLimit is not None:
            d["speedLimit"] = self.speedLimit
        if self.city:
            d["city"] = self.city
        if self.district:
            d["district"] = self.district
        if self.level:
            d["level"] = self.level
        return d


@dataclass
class NormalizeReport:
    total_rows: int = 0
    kept: int = 0
    skipped_no_coords: int = 0
    duplicates_merged: int = 0
    unknown_direction: int = 0
    axis_known: int = 0
    elevated: int = 0
    surface: int = 0
    by_type: dict = field(default_factory=dict)
    # 診斷用：無法解析的方向原文（含空白）與區間照相點
    unknown_direction_texts: dict = field(default_factory=dict)
    section_cameras: list = field(default_factory=list)

    def diagnostics(self, top: int = 30) -> str:
        lines = []
        if self.unknown_direction_texts:
            lines.append(f"無法解析的方向原文（前 {top} 名，共 {len(self.unknown_direction_texts)} 種）：")
            ranked = sorted(self.unknown_direction_texts.items(), key=lambda kv: (-kv[1], kv[0]))
            for text, n in ranked[:top]:
                lines.append(f"  {n:4d}  {text!r}")
        if self.section_cameras:
            lines.append(f"區間照相點 {len(self.section_cameras)} 筆：")
            for c in self.section_cameras:
                lines.append(f"  {c}")
        return "\n".join(lines)

    def summary(self) -> str:
        types = ", ".join(f"{k}={v}" for k, v in sorted(self.by_type.items()))
        return (f"原始 {self.total_rows} 筆 → 保留 {self.kept} 筆；"
                f"座標無效 {self.skipped_no_coords}、合併重複 {self.duplicates_merged}、"
                f"沒有單一方向 {self.unknown_direction}（其中已知南北／東西軸向 {self.axis_known}）；"
                f"高架 {self.elevated}、平面 {self.surface}；類型：{types}")


def dedupe_key(lat: float, lon: float, heading: Optional[float]) -> tuple:
    """約 11 m 內、同方向視為同一支照相機。"""
    return (round(lat, 4), round(lon, 4), heading)


def make_id(lat: float, lon: float, heading: Optional[float]) -> str:
    """由位置與方向產生穩定的 ID：資料順序或地址文字改變都不影響。"""
    k = dedupe_key(lat, lon, heading)
    raw = f"{k[0]:.4f},{k[1]:.4f},{k[2] if k[2] is not None else '-'}"
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()[:12]


_TYPE_PRIORITY = {"section": 5, "redLightSpeed": 4, "fixed": 3, "mobile": 2, "redLight": 1, "tech": 0}

# 資料的方向欄位不一定是行車方向：過港隧道寫的「南向」「北向」其實是管道名稱（南孔、北孔）。
# 南孔是旗津往前鎮（往東北），北孔是前鎮往旗津（往西南）。角度來自 OSM 的隧道線形。
_HEADING_FROM_ADDRESS = (("旗津往前鎮", 52.0), ("前鎮往旗津", 232.0))


def heading_from_address(address: str) -> Optional[float]:
    """地址寫明行車方向、而且方向欄位不可靠的照相點。"""
    for words, heading in _HEADING_FROM_ADDRESS:
        if words in address:
            return heading
    return None


def normalize_rows(rows: Iterable[dict], report: Optional[NormalizeReport] = None) -> list[Camera]:
    report = report or NormalizeReport()
    merged: dict[tuple, Camera] = {}
    for row in rows:
        report.total_rows += 1
        coords = parse_coordinates(pick(row, "lat"), pick(row, "lon"))
        if coords is None:
            report.skipped_no_coords += 1
            continue
        lat, lon = coords
        address = pick(row, "address") or ""
        direction_text = pick(row, "direction")
        heading = heading_from_address(address)
        if heading is None:
            heading = parse_direction(direction_text)
        axis = parse_axis(direction_text) if heading is None else None
        if axis is not None:
            report.axis_known += 1
        if heading is None:
            report.unknown_direction += 1
            raw = pick(row, "direction") or "(空白)"
            report.unknown_direction_texts[raw] = report.unknown_direction_texts.get(raw, 0) + 1
        cam = Camera(
            id=make_id(lat, lon, heading),
            type=detect_type(pick(row, "kind"), address, direction_text),
            lat=lat,
            lon=lon,
            heading=heading,
            axis=axis,
            speedLimit=parse_limit(pick(row, "limit")),
            address=address,
            city=pick(row, "city"),
            district=pick(row, "district"),
            level=parse_level(address),
        )
        if cam.type == "section":
            report.section_cameras.append(
                f"{cam.city or ''}{cam.district or ''} {cam.address}｜{lat:.5f},{lon:.5f}｜方向 {pick(row, 'direction')!r}｜速限 {cam.speedLimit}")
        key = dedupe_key(lat, lon, heading)
        if key in merged:
            report.duplicates_merged += 1
            old = merged[key]
            if _TYPE_PRIORITY[cam.type] > _TYPE_PRIORITY[old.type]:
                old.type = cam.type
            if cam.speedLimit is not None and (old.speedLimit is None or cam.speedLimit < old.speedLimit):
                old.speedLimit = cam.speedLimit
            if len(cam.address) > len(old.address):
                old.address = cam.address
            old.level = old.level or cam.level
            continue
        merged[key] = cam

    cameras = sorted(merged.values(), key=lambda c: c.id)
    mark_surface_near_elevated(cameras)
    report.kept = len(cameras)
    report.elevated = sum(1 for c in cameras if c.level == "elevated")
    report.surface = sum(1 for c in cameras if c.level == "surface")
    report.by_type = {}
    for c in cameras:
        report.by_type[c.type] = report.by_type.get(c.type, 0) + 1
    return cameras
