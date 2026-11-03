"""從區間測速的文字描述自動產生區間。

警政署開放資料（以及立法院附件等清單）把區間寫在「設置地點」欄位，例如：
- 台9線68k+600m至56k+600m
- 台3線82.2公里至84.3公里
- 台3線103.2公里至108公里及台3線114.3公里至123.6公里   （一筆多段，用「及」「/」「；」分隔）
- 台13甲線8.3公里至9.5公里及9.8公里至11公里             （後段省略路名，沿用前段）
- 臺21線53.8K至51.1K(北向)/臺21線51.1K至53.9K(南向)    （每段各自的方向）
- 南澳鄉台9線110k+960m至蘇澳鎮台9線108k+224m             （中間夾地名、重複路名）
- 台三線31.8k至30.5k、台七乙線12.1k至8.2k               （中文數字路名）

只處理省道（台／臺 + 數字 + 線），因為里程牌資料只涵蓋省道。縣道、市道、
只寫隧道名稱或路口名稱的區間會被略過，並回報原因。

方向規則：
- 段落或方向欄寫「雙向」→ 兩個方向各一段。
- 寫了單一方向（北向、南向北、東往西、往高雄、北上…）→ 只有一段，行駛方向就是文字中「A 至 B」的順序。
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Optional

from .normalize import pick

CN_DIGIT = {"零": 0, "〇": 0, "一": 1, "二": 2, "兩": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9}
BRANCH = "甲乙丙丁戊己庚辛"


def cn_number(text: str) -> Optional[int]:
    """中文數字（最多兩位數）：三→3、十→10、十一→11、二十→20、六十一→61。也接受阿拉伯數字。"""
    if text.isdigit():
        return int(text)
    if not text or any(ch not in CN_DIGIT and ch != "十" for ch in text):
        return None
    if "十" not in text:
        value = 0
        for ch in text:
            value = value * 10 + CN_DIGIT[ch]
        return value
    tens, _, ones = text.partition("十")
    if len(tens) > 1 or len(ones) > 1 or "十" in ones:
        return None
    t = CN_DIGIT[tens] if tens else 1
    o = CN_DIGIT[ones] if ones else 0
    return t * 10 + o


ROAD_RE = re.compile(r"(?:省道)?[台臺]\s*([0-9]{1,3}|[一二三四五六七八九十〇零兩]{1,3})\s*([" + BRANCH + r"]?)\s*線")
_NUM = r"(\d+(?:\.\d+)?)"
_UNIT = r"(?:\s*[kK]\s*\+\s*(\d+(?:\.\d+)?)\s*[mM]?|\s*[kK](?![a-zA-Z])|\s*公里)?"
RANGE_RE = re.compile(
    _NUM + _UNIT
    + r"\s*(?:[（(][^）)]{0,15}[）)])?\s*(?:主線|處)?\s*(?:至|－|-|~|～|到)\s*"
    + r"[^\d\s（）()]{0,10}?"
    + _NUM + _UNIT
)
SPLIT_RE = re.compile(r"及|／|/|；|;")

ONE_WAY_RE = re.compile(r"[東西南北][向往][東西南北]|[東西南北]向|往[^\s（）()]{1,6}|北上|南下|順向|逆向")
BOTH_WAY_RE = re.compile(r"雙向")


@dataclass
class TextSegment:
    """從文字解析出的一段區間（尚未換算座標）。"""
    road: str
    start_km: float
    end_km: float
    bidirectional: bool
    speed_limit: Optional[int]
    source_text: str
    city: str = ""
    point: Optional[tuple] = None     # 開放資料提供的照相點座標（用來檢查換算結果）
    travel_bearing: Optional[float] = None   # 單向區間文字寫的行駛方向（北 0、東 90…），用來校正起訖順序
    group: int = -1                          # 同一筆原始資料的段落共用同一個編號（一筆只有一個照相點座標）

    @property
    def key(self) -> tuple:
        """去重用：同一條路、同一個里程範圍（雙向不分起訖）。"""
        a, b = round(self.start_km, 2), round(self.end_km, 2)
        return (self.road, min(a, b), max(a, b), self.bidirectional) if self.bidirectional \
            else (self.road, a, b, False)


@dataclass
class TextParseReport:
    parsed: list = field(default_factory=list)
    skipped: list = field(default_factory=list)      # (原文, 原因)


def normalize_road_token(m: re.Match) -> Optional[str]:
    num = cn_number(m.group(1))
    if num is None or num == 0:
        return None
    return f"台{num}{m.group(2)}"


def _km(num: str, meters: Optional[str]) -> float:
    value = float(num)
    if meters:
        value += float(meters) / 1000
    return round(value, 4)


COMPASS_DEG = {"北": 0.0, "東": 90.0, "南": 180.0, "西": 270.0}


def travel_bearing_of(text: str) -> Optional[float]:
    """從「西向」「南向北」「東往西」「北上」「南下」讀出行駛方向；「往○○（地名）」讀不出來回傳 None。"""
    if not text:
        return None
    m = re.search(r"([東西南北])[向往]([東西南北])", text)
    if m:
        return COMPASS_DEG[m.group(2)]
    m = re.search(r"([東西南北])向", text)
    if m:
        return COMPASS_DEG[m.group(1)]
    if "北上" in text:
        return 0.0
    if "南下" in text:
        return 180.0
    return None


def _direction_mode(segment_text: str, column_part: Optional[str]) -> Optional[bool]:
    """回傳 True = 雙向、False = 單向、None = 看不出來。"""
    if BOTH_WAY_RE.search(segment_text):
        return True
    if ONE_WAY_RE.search(segment_text):
        return False
    if column_part:
        if BOTH_WAY_RE.search(column_part):
            return True
        if ONE_WAY_RE.search(column_part):
            return False
    return None


def parse_section_text(address: str, direction: Optional[str], speed_limit: Optional[int],
                       city: str = "", point: Optional[tuple] = None) -> tuple[list[TextSegment], list[str]]:
    """解析一筆區間描述，回傳（解析出的段落, 略過原因清單）。"""
    text = re.sub(r"\s+", "", address or "")
    # 「80公里/小時」這類單位不是分段符號
    text = re.sub(r"公里\s*/\s*小時", "公里每小時", text)
    column = direction or ""
    parts = [p for p in SPLIT_RE.split(text) if p]
    column_parts = [p for p in re.split(r"\s+|/|／", column.strip()) if p]
    segments: list[TextSegment] = []
    problems: list[str] = []
    last_road: Optional[str] = None
    for idx, part in enumerate(parts):
        roads = [normalize_road_token(m) for m in ROAD_RE.finditer(part)]
        roads = [r for r in roads if r]
        if roads:
            last_road = roads[0]
        elif re.search(r"(縣道|市道|鄉道|區道|[北中南高]\d+線)", part):
            last_road = None   # 明確是非省道
        road = last_road
        stripped = ROAD_RE.sub("", part)
        m = RANGE_RE.search(stripped)
        if not m:
            problems.append(f"沒有里程範圍：{part}")
            continue
        has_unit = any(g for g in (m.group(2), m.group(4))) or re.search(r"[kK公]", m.group(0))
        if not has_unit:
            problems.append(f"里程沒有單位：{part}")
            continue
        if road is None:
            problems.append(f"不是省道（沒有里程牌資料）：{part}")
            continue
        start, end = _km(m.group(1), m.group(2)), _km(m.group(3), m.group(4))
        if abs(end - start) < 0.2 or abs(end - start) > 40:
            problems.append(f"里程範圍不合理（{start}–{end}）：{part}")
            continue
        col_part = column_parts[idx] if len(column_parts) == len(parts) else column
        mode = _direction_mode(part, col_part)
        if mode is None:
            mode = True   # 看不出方向時當作雙向，兩個方向都提醒
        bearing_hint = None
        if not mode:
            bearing_hint = travel_bearing_of(part)
            if bearing_hint is None:
                bearing_hint = travel_bearing_of(col_part or "")
        segments.append(TextSegment(road=road, start_km=start, end_km=end, bidirectional=mode,
                                    speed_limit=speed_limit, source_text=address, city=city, point=point,
                                    travel_bearing=bearing_hint))
    return segments, problems


def is_section_row(address: Optional[str], direction: Optional[str], kind: Optional[str] = None) -> bool:
    return "區間" in f"{address or ''}{direction or ''}{kind or ''}"


def extract_from_rows(rows: list[dict], report: Optional[TextParseReport] = None) -> list[TextSegment]:
    """從原始資料列（開放資料或補充 CSV）找出區間測速並解析。"""
    from .normalize import parse_coordinates, parse_limit

    report = report or TextParseReport()
    out: list[TextSegment] = []
    for row_index, row in enumerate(rows):
        address = pick(row, "address") or ""
        direction = pick(row, "direction")
        if not is_section_row(address, direction, pick(row, "kind")):
            continue
        coords = parse_coordinates(pick(row, "lat"), pick(row, "lon"))
        segs, problems = parse_section_text(address, direction, parse_limit(pick(row, "limit")),
                                            city=(pick(row, "city") or "") + (pick(row, "district") or ""),
                                            point=coords)
        for seg in segs:
            seg.group = row_index
        for p in problems:
            report.skipped.append((address, p))
        out += segs
    # 去重（例如同一段雙向寫成兩筆）
    unique: dict[tuple, TextSegment] = {}
    for s in out:
        unique.setdefault(s.key, s)
    report.parsed = list(unique.values())
    return report.parsed


# ---------------------------------------------------------------------------
# 換算成 App 使用的區間
# ---------------------------------------------------------------------------
COMPASS8 = ["北", "東北", "東", "東南", "南", "西南", "西", "西北"]


def compass(bearing_deg: float) -> str:
    return COMPASS8[int(((bearing_deg % 360) + 22.5) // 45) % 8]


def _fmt_km(km: float) -> str:
    return f"{km:g}"


def _point_to_chord_m(p: tuple, a: tuple, b: tuple) -> float:
    """點到 a–b 直線段的距離（公尺，局部平面近似）。"""
    import math
    lat0 = math.radians(a[0])
    k = 111_195.0
    ax, ay = 0.0, 0.0
    bx, by = (b[1] - a[1]) * k * math.cos(lat0), (b[0] - a[0]) * k
    px, py = (p[1] - a[1]) * k * math.cos(lat0), (p[0] - a[0]) * k
    l2 = bx * bx + by * by
    t = 0.0 if l2 == 0 else max(0.0, min(1.0, (px * bx + py * by) / l2))
    return math.hypot(px - t * bx, py - t * by)


def range_key(road: str, a: float, b: float) -> tuple:
    return (road, round(min(a, b), 1), round(max(a, b), 1))


def to_sections(segments: list[TextSegment], resolver, exclude: set = frozenset(),
                log=print, max_point_m: float = 3_000, sibling_max_m: float = 15_000) -> list[dict]:
    """換算座標並產生區間。exclude：已由人工資料定義的里程範圍（range_key），不重複產生。

    照相點距離檢查：一筆資料只有一個照相點座標，通常落在其中一段上。所以同一筆裡只要有一段
    離照相點 3 km 內，其他段放寬到 15 km（仍可擋下路名解析錯、跑到別的縣市的情況）。
    """
    from .sections import _local_heading, bearing, haversine

    def point_distance(s: TextSegment) -> Optional[float]:
        if s.point is None:
            return None
        a, b = resolver(s.road, s.start_km), resolver(s.road, s.end_km)
        if a is None or b is None:
            return None
        return min(haversine(s.point[0], s.point[1], a[0], a[1]),
                   haversine(s.point[0], s.point[1], b[0], b[1]),
                   _point_to_chord_m(s.point, a, b))

    distances = {i: point_distance(s) for i, s in enumerate(segments)}
    group_ok = {}
    for i, s in enumerate(segments):
        d = distances[i]
        if d is not None and d <= max_point_m:
            group_ok[s.group] = True

    out: list[dict] = []
    for i, s in enumerate(segments):
        rk = range_key(s.road, s.start_km, s.end_km)
        label = f"{s.road}線 {_fmt_km(s.start_km)}K–{_fmt_km(s.end_km)}K"
        if rk in exclude:
            log(f"  自動區間略過（人工資料已有）：{label}")
            continue
        if not s.speed_limit:
            log(f"  自動區間略過（沒有速限）：{label}｜{s.source_text}")
            continue
        a, b = resolver(s.road, s.start_km), resolver(s.road, s.end_km)
        if a is None or b is None:
            log(f"  自動區間略過（里程牌資料找不到）：{label}｜{s.source_text}")
            continue
        d = distances[i]
        if d is not None and d > max_point_m:
            if group_ok.get(s.group) and d <= sibling_max_m:
                log(f"  自動區間：{label} 離照相點 {d / 1000:.1f} km，但同一筆的另一段已通過檢查，接受")
            else:
                log(f"  自動區間略過（離照相點 {d / 1000:.1f} km，可能解析錯誤）：{label}｜{s.source_text}")
                continue
        start_km, end_km = s.start_km, s.end_km
        if not s.bidirectional and s.travel_bearing is not None:
            actual = bearing(a[0], a[1], b[0], b[1])
            diff = abs((actual - s.travel_bearing + 180) % 360 - 180)
            if diff > 90:
                # 文字順序跟寫的行駛方向相反（例如「西向1.6K至5.4K」但里程往東增加）→ 對調起訖
                a, b = b, a
                start_km, end_km = end_km, start_km
                log(f"  自動區間校正方向：{label} 寫的是往{compass(s.travel_bearing)}，改為 "
                    f"{_fmt_km(start_km)}K→{_fmt_km(end_km)}K")
        length = round(abs(s.end_km - s.start_km) * 1000, 1)
        start = {"lat": round(a[0], 6), "lon": round(a[1], 6)}
        end = {"lat": round(b[0], 6), "lon": round(b[1], 6)}
        place = f"{s.city} " if s.city else ""
        base_id = f"auto-{s.road}-{_fmt_km(s.start_km)}-{_fmt_km(s.end_km)}"
        directions = [(start, end, start_km, end_km, "f")]
        if s.bidirectional:
            directions.append((end, start, end_km, start_km, "r"))
        for st, en, k_from, k_to, suffix in directions:
            heading = _local_heading(resolver, s.road, k_from, k_to)
            toward = compass(bearing(st["lat"], st["lon"], en["lat"], en["lon"]))
            sec = {
                "id": f"{base_id}-{suffix}" if s.bidirectional else base_id,
                "name": f"{place}{label}（往{toward}）",
                "start": st, "end": en,
                "lengthMeters": length, "speedLimit": int(s.speed_limit), "lengthEstimated": False,
            }
            if heading is not None:
                sec["startHeading"] = heading
            out.append(sec)
        log(f"  自動區間：{place}{label}，速限 {s.speed_limit}，{'雙向' if s.bidirectional else '單向'}，"
            f"{start['lat']},{start['lon']} → {end['lat']},{end['lon']}")
    return out
