"""公告地址的嚴格定位：官方門牌／燈桿與同區 OSM 道路，不作模糊門牌或路段中心。"""
from __future__ import annotations

from dataclasses import dataclass, field
import math
import re
import unicodedata

from .normalize import in_taiwan, parse_float
from .sections import bearing, haversine

SNAP_DISTANCE = 35.0
AMBIGUITY_DISTANCE = 12.0
ROAD_PATTERN = r"(?:[^,，()（）/、與及]{1,24}?(?:大道|道路|路|街)(?:\d+段)?(?:\d+巷)?(?:\d+弄)?|台\d+[甲乙丙丁]?線|北\d+[甲乙丙丁]?線)"
VEHICLE_HIGHWAYS = frozenset(("motorway", "trunk", "primary", "secondary", "tertiary",
                             "unclassified", "residential", "living_street", "service",
                             "motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link"))


def _chinese_number(text: str) -> str:
    if "百" in text or "千" in text:
        return text
    digits = dict(zip("零一二三四五六七八九", range(10)))
    if "十" not in text:
        return "".join(str(digits[c]) for c in text)
    a, b = text.split("十", 1)
    return str((digits.get(a, 1) if a else 1) * 10 + digits.get(b, 0))


def normalize_address(text: str) -> str:
    text = re.sub(r"\s+", "", unicodedata.normalize("NFKC", text)).replace("臺", "台")
    text = re.sub(r"[零一二三四五六七八九十百千]+(?=[段巷弄號])", lambda m: _chinese_number(m[0]), text)
    text = re.sub(r"(\d+)-(\d+)(?=號)", r"\1之\2", text)
    return re.sub(r"(\d+)號之(\d+)", r"\1之\2號", text)


def without_place(city: str, district: str, address: str) -> str:
    text = normalize_address(address)
    for prefix in (city, district):
        prefix = normalize_address(prefix)
        if prefix and text.startswith(prefix):
            text = text[len(prefix):]
    return text


@dataclass(frozen=True)
class AddressQuery:
    kind: str
    road: str
    key: str
    other_road: str = ""


def parse_address(city: str, district: str, address: str) -> AddressQuery | None:
    text = without_place(city, district, address)
    # 桿號可能在括號裡，不能先刪括號；前導零與字母原樣保留。
    lamp = re.search(r"(?:燈桿|路燈)(?:編號)?[:：]?([A-Za-z0-9]+)", text)
    if not lamp:
        lamp = re.search(r"([A-Za-z0-9]+)(?:號)?(?:燈桿|號燈(?:\(|$))", text)
    road = re.match(ROAD_PATTERN, text)
    if lamp:
        if re.search(r"(?:[、/,，及與](?:燈桿)?[A-Za-z0-9]{3,}|燈桿[：:]?[A-Za-z0-9]+)", text[lamp.end():]):
            return None
        return AddressQuery("lamp", road[0], lamp[1]) if road else None
    if any(word in text for word in ("電桿", "燈桿", "路燈編號")):
        return None
    text = re.sub(r"\([^)]*\)", "", text).rstrip("。.")
    house = re.match(rf"({ROAD_PATTERN})(\d+(?:之\d+)?號)", text)
    if house:
        rest = text[house.end():]
        if re.search(r"(?:至|到|~|～|-)\d|\d+(?:之\d+)?號", rest):
            return None
        if not rest or re.fullmatch(r"(?:前|旁|附近|對面|處|往[^,，]+|[,，].*)+", rest):
            return AddressQuery("door", house[1], house[1] + house[2])
    # 完整兩路名，或「某路123巷口」；不將整條路／橋名當成一點。
    location = re.split(r"[,，]|往", text, maxsplit=1)[0]
    junction = re.fullmatch(rf"({ROAD_PATTERN})(?:與|及|/|近)({ROAD_PATTERN})(?:路?口|交叉口|交會處)?(?:附近)?", location)
    if junction:
        return AddressQuery("intersection", junction[1], "", junction[2])
    lane = re.fullmatch(rf"({ROAD_PATTERN})(\d+巷)(?:口|路口)", location)
    if lane:
        return AddressQuery("intersection", lane[1], "", lane[1] + lane[2])
    return None


def twd97_to_wgs84(x: float, y: float) -> tuple[float, float]:
    """EPSG:3826（GRS80、中央經線121°）的反橫麥卡托；不自行猜其他 CRS。"""
    if not all(math.isfinite(v) for v in (x, y)) or not (90000 <= x <= 370000 and 2400000 <= y <= 2900000):
        raise ValueError("EPSG:3826 座標超出臺灣本島範圍")
    a, f, k = 6378137.0, 1 / 298.257222101, .9999
    e2 = f * (2 - f)
    ep2 = e2 / (1 - e2)
    mu = y / k / (a * (1 - e2 / 4 - 3 * e2 ** 2 / 64 - 5 * e2 ** 3 / 256))
    e1 = (1 - math.sqrt(1 - e2)) / (1 + math.sqrt(1 - e2))
    phi = (mu + (3 * e1 / 2 - 27 * e1 ** 3 / 32) * math.sin(2 * mu)
           + (21 * e1 ** 2 / 16 - 55 * e1 ** 4 / 32) * math.sin(4 * mu)
           + 151 * e1 ** 3 / 96 * math.sin(6 * mu) + 1097 * e1 ** 4 / 512 * math.sin(8 * mu))
    t, c = math.tan(phi) ** 2, ep2 * math.cos(phi) ** 2
    n = a / math.sqrt(1 - e2 * math.sin(phi) ** 2)
    r = a * (1 - e2) / (1 - e2 * math.sin(phi) ** 2) ** 1.5
    d = (x - 250000) / (n * k)
    lat = phi - n * math.tan(phi) / r * (
        d ** 2 / 2 - (5 + 3 * t + 10 * c - 4 * c ** 2 - 9 * ep2) * d ** 4 / 24
        + (61 + 90 * t + 298 * c + 45 * t ** 2 - 252 * ep2 - 3 * c ** 2) * d ** 6 / 720)
    lon = math.radians(121) + (
        d - (1 + 2 * t + c) * d ** 3 / 6
        + (5 - 2 * c + 28 * t - 3 * c ** 2 + 8 * ep2 + 24 * t ** 2) * d ** 5 / 120) / math.cos(phi)
    return math.degrees(lat), math.degrees(lon)


@dataclass
class LocationResult:
    method: str | None = None
    point: tuple[float, float] | None = None
    axis: float | None = None
    evidence: str = ""
    reason: str = ""
    reason_code: str = ""
    details: dict = field(default_factory=dict)


def rejected(code: str, reason: str) -> LocationResult:
    return LocationResult(reason_code=code, reason=reason)


def _angle(a: float, b: float) -> float:
    return abs((a - b + 90) % 180 - 90)


def _project(point, a, b):
    sy, sx = 111195.0, 111195.0 * math.cos(math.radians(point[0]))
    ax, ay = (a[1] - point[1]) * sx, (a[0] - point[0]) * sy
    dx, dy = (b[1] - a[1]) * sx, (b[0] - a[0]) * sy
    length = dx * dx + dy * dy
    if length <= .01:
        return None
    t = max(0, min(1, -(ax * dx + ay * dy) / length))
    projection = a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t
    return haversine(*point, *projection), projection, bearing(*a, *b) % 180


def way_names(way: dict) -> set[str]:
    tags = way.get("tags", {})
    names = {normalize_address(tags[key]) for key in ("name", "name:zh", "official_name") if tags.get(key)}
    for ref in tags.get("ref", "").split(";"):
        if re.fullmatch(r"\d+[甲乙丙丁]?", ref):
            names.add("台" + ref + "線")
        elif re.fullmatch(r"[北雲]\d+[甲乙丙丁]?", ref):
            names.add(ref + "線")
    return names


def _vehicle_way(way: dict) -> bool:
    tags = way.get("tags", {})
    return (tags.get("highway") in VEHICLE_HIGHWAYS
            and tags.get("access") not in ("no", "private")
            and tags.get("motor_vehicle") != "no" and tags.get("vehicle") != "no")


class RoadIndex:
    def __init__(self, regions: list[dict]):
        self.regions = {(normalize_address(r["city"]), r["district"]): r for r in regions}

    def region(self, city, district, *names) -> dict | None:
        region = self.regions.get((normalize_address(city), district))
        if not region or not set(names) <= set(region["coverage"]):
            return None
        return region

    @staticmethod
    def ways(region: dict, road: str) -> list[dict]:
        return [w for w in region["ways"] if _vehicle_way(w) and road in way_names(w)]

    def snap(self, city: str, district: str, road: str, point: tuple[float, float]) -> LocationResult:
        region = self.region(city, district, road)
        if not region:
            return rejected("road_data_missing", "缺少該行政區同名道路的完整查核資料")
        ways = self.ways(region, road)
        if not ways:
            return rejected("road_not_found", "同一行政區沒有可核的 OSM 同名車行道路")
        inside = set(region["insideNodes"])
        candidates = []
        for way in ways:
            for i, (a, b) in enumerate(zip(way["geometry"], way["geometry"][1:])):
                if not {way["nodes"][i], way["nodes"][i + 1]} <= inside:
                    continue
                projection = _project(point, (a["lat"], a["lon"]), (b["lat"], b["lon"]))
                if projection and projection[0] <= SNAP_DISTANCE:
                    candidates.append((*projection, way["id"], (way["nodes"][i], way["nodes"][i + 1])))
        if not candidates:
            return rejected("road_too_far", f"官方位置無法在 {SNAP_DISTANCE:g} m 內貼齊公告同名道路（或跨行政區界）")
        distance, point, axis, way_id, nodes = min(candidates, key=lambda x: (x[0], x[3]))
        connected = set(nodes)
        while True:
            expanded = connected | {node for *_, pair in candidates if connected & set(pair) for node in pair}
            if expanded == connected:
                break
            connected = expanded
        if (any(not connected.intersection(pair) for *_, pair in candidates)
                or any(d <= distance + 3 and (haversine(*point, *p) > AMBIGUITY_DISTANCE or _angle(axis, ax) > 30)
                       for d, p, ax, _, _ in candidates)):
            return rejected("road_ambiguous", "35 m 內有分離或不同軸向的同名道路投影；不選最近一條")
        return LocationResult(point=point, axis=round(axis, 1) % 180,
                              evidence=f"OSM way/{way_id}（{region['version']}），貼齊側距 {distance:.1f} m",
                              details={"wayIDs": sorted({c[3] for c in candidates}), "snapDistance": round(distance, 2)})

    def intersection(self, city: str, district: str, road: str, other: str) -> LocationResult:
        region = self.region(city, district, road, other)
        if not region:
            return rejected("road_data_missing", "缺少該行政區兩條同名道路的完整查核資料")
        a, b = self.ways(region, road), self.ways(region, other)
        if not a or not b:
            return rejected("road_not_found", "同一行政區找不到公告兩條完整路名的車行道路")
        inside = set(region["insideNodes"])
        candidates: dict[int, tuple] = {}
        for first in a:
            for second in b:
                ta, tb = first["tags"], second["tags"]
                if (first["id"] == second["id"] or ta.get("layer", "0") != tb.get("layer", "0")
                        or ta.get("level", "0") != tb.get("level", "0")):
                    continue
                if any(t.get(key) not in (None, "no") for t in (ta, tb) for key in ("bridge", "tunnel")):
                    continue
                shared = set(first["nodes"]) & set(second["nodes"]) & inside
                for node in shared:
                    i = first["nodes"].index(node)
                    p = first["geometry"][i]
                    axes = []
                    for j in (i - 1, i + 1):
                        if 0 <= j < len(first["nodes"]):
                            q = first["geometry"][j]
                            if haversine(p["lat"], p["lon"], q["lat"], q["lon"]) > 1:
                                axes.append(bearing(p["lat"], p["lon"], q["lat"], q["lon"]) % 180)
                    if not axes:
                        continue
                    old = candidates.get(node)
                    all_axes = axes + (old[1] if old else [])
                    way_ids = {first["id"], second["id"]} | (old[2] if old else set())
                    candidates[node] = ((p["lat"], p["lon"]), all_axes, way_ids)
        if len(candidates) != 1:
            return rejected("intersection_ambiguous" if candidates else "intersection_not_found",
                            f"同區同層共同車行節點有 {len(candidates)} 個；只接受唯一交點，不算平面線交叉")
        node, (point, axes, ids) = next(iter(candidates.items()))
        if any(_angle(axes[0], x) > 30 for x in axes):
            return rejected("road_ambiguous", "路口主要道路的局部軸向不唯一")
        return LocationResult(method="intersection", point=point, axis=round(axes[0], 1) % 180,
                              evidence=f"OSM node/{node}、ways {','.join(map(str, sorted(ids)))}（{region['version']}）；同區唯一同層共同節點",
                              details={"nodeID": node, "wayIDs": sorted(ids)})


class Geocoder:
    def __init__(self, references: list[dict], roads: RoadIndex, reference_coverage: set[tuple] | None = None):
        self.roads = roads
        self.reference_coverage = reference_coverage
        self.references: dict[tuple, list[dict]] = {}
        for row in references:
            key = (normalize_address(row["city"]), row["district"], row["kind"], row["key"])
            self.references.setdefault(key, []).append(row)

    def locate(self, city: str, district: str, address: str) -> LocationResult:
        query = parse_address(city, district, address)
        if not query:
            return rejected("unsupported_address", "非完整門牌、可核燈桿編號或明確兩路口；不取路段／地標中心")
        if query.kind == "intersection":
            return self.roads.intersection(city, district, query.road, query.other_road)
        rows = self.references.get((normalize_address(city), district, query.kind, query.key), [])
        if not rows:
            if (self.reference_coverage is not None
                    and (normalize_address(city), district, query.kind, query.key) not in self.reference_coverage):
                return rejected("reference_unavailable", "官方定位資料不可用，或小型快照未涵蓋此新地址；不能當作官方查無")
            return rejected(f"{query.kind}_not_found", "官方定位資料未命中同一行政區的完整門牌／原始桿號")
        points = set()
        for row in rows:
            lat, lon = parse_float(row.get("lat")), parse_float(row.get("lon"))
            if lat is None or lon is None or not in_taiwan(lat, lon):
                return rejected("invalid_reference_coordinate", "官方定位列座標無效")
            points.add((lat, lon))
        first = min(points)
        if any(haversine(*first, *point) > 1 for point in points):
            return rejected(f"{query.kind}_ambiguous", "同區同門牌／桿號對到相距超過 1 m 的不同官方座標")
        result = self.roads.snap(city, district, query.road, first)
        if result.point is not None:
            reference = rows[0]
            result.method = query.kind
            result.evidence = (f"{reference['dataset']}／{reference['version']}／{district}{query.key}；"
                               + result.evidence)
            result.details["reference"] = reference
        return result
