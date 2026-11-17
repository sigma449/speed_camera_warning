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
DIVIDED_AXIS_TOLERANCE = 15.0
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
    heading: float | None = None


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


@dataclass(frozen=True)
class _RoadProjection:
    distance: float
    point: tuple[float, float]
    axis: float
    way: dict
    nodes: tuple[int, int]
    start: tuple[float, float]
    end: tuple[float, float]

    @property
    def heading(self) -> float | None:
        tags = self.way["tags"]
        oneway = tags.get("oneway:motor_vehicle", tags.get("oneway:vehicle", tags.get("oneway")))
        if oneway not in ("yes", "true", "1", "-1"):
            return None
        return (bearing(*self.start, *self.end) + (180 if oneway == "-1" else 0)) % 360


def _projection_groups(candidates: list[_RoadProjection]) -> list[list[_RoadProjection]]:
    groups = []
    remaining = list(candidates)
    while remaining:
        group = [remaining.pop()]
        connected = set(group[0].nodes)
        while True:
            adjacent = [c for c in remaining if connected.intersection(c.nodes)]
            if not adjacent:
                break
            group.extend(adjacent)
            remaining = [c for c in remaining if not connected.intersection(c.nodes)]
            connected.update(node for c in adjacent for node in c.nodes)
        groups.append(group)
    return groups


def _projection_key(candidate: _RoadProjection) -> tuple:
    return candidate.distance, candidate.way["id"], candidate.nodes


def _cross_near(a: _RoadProjection, b: _RoadProjection, point: tuple[float, float]) -> bool:
    dx, dy = a.end[1] - a.start[1], a.end[0] - a.start[0]
    ex, ey = b.end[1] - b.start[1], b.end[0] - b.start[0]
    denominator = dx * ey - dy * ex
    if abs(denominator) < 1e-20:
        return False
    x, y = b.start[1] - a.start[1], b.start[0] - a.start[0]
    t, u = (x * ey - y * ex) / denominator, (x * dy - y * dx) / denominator
    crossing = a.start[0] + t * dy, a.start[1] + t * dx
    return 0 <= t <= 1 and 0 <= u <= 1 and haversine(*point, *crossing) <= SNAP_DISTANCE


class RoadIndex:
    def __init__(self, regions: list[dict], landmarks: list[dict] | None = None):
        self.regions = {(normalize_address(r["city"]), r["district"]): r for r in regions}
        self.landmarks = landmarks or []

    def region(self, city, district, *names) -> dict | None:
        region = self.regions.get((normalize_address(city), district))
        if not region or not set(names) <= set(region["coverage"]):
            return None
        return region

    @staticmethod
    def ways(region: dict, road: str) -> list[dict]:
        return [w for w in region["ways"] if _vehicle_way(w) and road in way_names(w)]

    @staticmethod
    def _projections(ways: list[dict], point: tuple[float, float], inside: set[int] | None = None):
        for way in ways:
            for i, (a, b) in enumerate(zip(way["geometry"], way["geometry"][1:])):
                nodes = way["nodes"][i], way["nodes"][i + 1]
                if inside is not None and not set(nodes) <= inside:
                    continue
                start, end = (a["lat"], a["lon"]), (b["lat"], b["lon"])
                projection = _project(point, start, end)
                if projection:
                    yield _RoadProjection(*projection, way, nodes, start, end)

    def _directed_carriageway(self, city: str, address: str, nearest: list[_RoadProjection]):
        targets = re.findall(r"往([^(),，。]+?)(?:方向)?(?=[),，。]|$)", normalize_address(address))
        if len(targets) != 1:
            return None
        matches = [landmark for landmark in self.landmarks
                   if normalize_address(landmark["city"]) == normalize_address(city)
                   and normalize_address(landmark["name"]) == targets[0]]
        if len(matches) != 1:
            return None
        landmark = matches[0]
        ways = [w for w in landmark["ways"] if _vehicle_way(w) and targets[0] in way_names(w)]
        midpoint = tuple((a + b) / 2 for a, b in zip(nearest[0].point, nearest[1].point))
        groups = _projection_groups(list(self._projections(ways, midpoint)))
        points = sorted((min(group, key=_projection_key) for group in groups), key=_projection_key)
        if (not points or any(p.distance <= SNAP_DISTANCE for p in points)
                or any(haversine(*a.point, *b.point) > SNAP_DISTANCE for a in points for b in points)):
            return None
        selected = []
        for target in points:
            aligned = [c for c in nearest
                       if c.heading is not None
                       and abs((c.heading - bearing(*c.point, *target.point) + 180) % 360 - 180) <= 45]
            if len(aligned) != 1:
                return None
            selected.append(aligned[0])
        if any(c.way["id"] != selected[0].way["id"] for c in selected):
            return None
        proof = dict(name=landmark["name"], version=landmark["version"],
                     wayIDs=sorted(w["id"] for w in ways),
                     points=[dict(lat=p.point[0], lon=p.point[1], wayID=p.way["id"]) for p in points])
        return selected[0], proof

    def _divided(self, city: str, address: str, region: dict, point: tuple[float, float],
                 groups: list[list[_RoadProjection]]) -> LocationResult | None:
        if len(groups) != 2:
            return None
        if {c.way["id"] for c in groups[0]} & {c.way["id"] for c in groups[1]}:
            return None
        nearest = sorted((min(group, key=_projection_key) for group in groups), key=_projection_key)
        a, b = nearest
        if (_angle(a.axis, b.axis) > DIVIDED_AXIS_TOLERANCE
                or a.heading is None or b.heading is None
                or abs((a.heading - b.heading) % 360 - 180) > DIVIDED_AXIS_TOLERANCE):
            return None
        signatures = set()
        for group in groups:
            best = min(group, key=_projection_key)
            for c in group:
                tags = c.way["tags"]
                signatures.add((tags["highway"], tags.get("layer", "0"), tags.get("level", "0"),
                                tags.get("bridge") not in (None, "no"), tags.get("tunnel") not in (None, "no")))
                if (tags.get("junction") in ("roundabout", "circular")
                        or c.heading is None or _angle(best.axis, c.axis) > 30
                        or abs((best.heading - c.heading + 180) % 360 - 180) > 30):
                    return None
        if len(signatures) != 1 or any(_cross_near(x, y, point) for x in groups[0] for y in groups[1]):
            return None
        axis = (a.axis + ((b.axis - a.axis + 90) % 180 - 90) / 2) % 180
        x = (b.point[1] - a.point[1]) * 111195 * math.cos(math.radians(point[0]))
        y = (b.point[0] - a.point[0]) * 111195
        along = x * math.sin(math.radians(axis)) + y * math.cos(math.radians(axis))
        across = x * math.cos(math.radians(axis)) - y * math.sin(math.radians(axis))
        if abs(across) <= 1 or abs(along) > max(3, abs(across) * math.tan(math.radians(DIVIDED_AXIS_TOLERANCE))):
            return None
        midpoint = tuple((p + q) / 2 for p, q in zip(a.point, b.point))
        midpoint_axis = round(axis, 1) % 180
        details = dict(wayIDs=sorted({c.way["id"] for group in groups for c in group}),
                       dividedCarriageways=[dict(wayID=c.way["id"], lat=c.point[0], lon=c.point[1],
                                                 axis=round(c.axis, 1) % 180, heading=round(c.heading, 1) % 360,
                                                 snapDistance=round(c.distance, 2)) for c in nearest],
                       dividedMidpoint=dict(lat=midpoint[0], lon=midpoint[1], axis=midpoint_axis),
                       axisDifference=round(_angle(a.axis, b.axis), 2))
        evidence = (f"OSM ways {','.join(map(str, details['wayIDs']))}（{region['version']}）；"
                    f"同名同層反向單行車道，局部軸向差 {details['axisDifference']:g}°")
        has_conditional_oneway = any(k.startswith("oneway") and "conditional" in k
                                     for group in groups for c in group for k in c.way["tags"])
        directed = self._directed_carriageway(city, address, nearest) if not has_conditional_oneway else None
        if directed:
            selected, proof = directed
            result_point, heading, axis = selected.point, round(selected.heading, 1) % 360, None
            details.update(positionChoice="carriageway", directionTarget=proof)
            evidence += (f"；公告往{proof['name']}，以該地物 OSM ways {','.join(map(str, proof['wayIDs']))}"
                         f"（{proof['version']}）最近投影與單行行向核對，選 way/{selected.way['id']}，heading={heading:g}°")
        else:
            result_point = midpoint
            heading, axis = None, midpoint_axis
            details["positionChoice"] = "midpoint"
            evidence += "；取兩車道最近投影的中點；分向車道無法判定，沿路雙向"
            if "往" in address or "方向" in address:
                evidence += "；公告方向缺少可唯一核對的地物／單行行向證據，不猜方向"
        distance = haversine(*point, *result_point)
        if distance > SNAP_DISTANCE:
            return None
        details["snapDistance"] = round(distance, 2)
        return LocationResult(point=result_point, axis=axis, heading=heading, evidence=evidence, details=details)

    def snap(self, city: str, district: str, road: str, point: tuple[float, float],
             *, divided_address: str | None = None) -> LocationResult:
        region = self.region(city, district, road)
        if not region:
            return rejected("road_data_missing", "缺少該行政區同名道路的完整查核資料")
        ways = self.ways(region, road)
        if not ways:
            return rejected("road_not_found", "同一行政區沒有可核的 OSM 同名車行道路")
        inside = set(region["insideNodes"])
        candidates = [c for c in self._projections(ways, point, inside) if c.distance <= SNAP_DISTANCE]
        if not candidates:
            return rejected("road_too_far", f"官方位置無法在 {SNAP_DISTANCE:g} m 內貼齊公告同名道路（或跨行政區界）")
        best = min(candidates, key=lambda c: (c.distance, c.way["id"]))
        groups = _projection_groups(candidates)
        if (len(groups) != 1
                or any(c.distance <= best.distance + 3
                       and (haversine(*best.point, *c.point) > AMBIGUITY_DISTANCE or _angle(best.axis, c.axis) > 30)
                       for c in candidates)):
            if divided_address is not None:
                divided = self._divided(city, divided_address, region, point, groups)
                if divided:
                    return divided
            return rejected("road_ambiguous", "35 m 內有分離或不同軸向的同名道路投影；不選最近一條")
        return LocationResult(point=best.point, axis=round(best.axis, 1) % 180,
                              evidence=f"OSM way/{best.way['id']}（{region['version']}），貼齊側距 {best.distance:.1f} m",
                              details={"wayIDs": sorted({c.way['id'] for c in candidates}),
                                       "snapDistance": round(best.distance, 2)})

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

    def locate(self, city: str, district: str, address: str, *, allow_divided: bool = False) -> LocationResult:
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
        result = self.roads.snap(city, district, query.road, first,
                                 divided_address=address if allow_divided else None)
        if result.point is not None:
            reference = rows[0]
            result.method = query.kind
            result.evidence = (f"{reference['dataset']}／{reference['version']}／{district}{query.key}；"
                               + result.evidence)
            result.details["reference"] = reference
        return result
