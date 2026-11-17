import io
import json
import math
from pathlib import Path
import re
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from speedcam_data import geocoding as geo, geocoding_sources as refs
from speedcam_data.sections import haversine
from speedcam_data.source_merge import SourceReport


def way(identity, nodes, points, name="測試路", **tags):
    return dict(id=identity, nodes=nodes, geometry=[dict(lat=a, lon=b) for a, b in points],
                tags=dict(highway="residential", name=name, **tags))


def region(ways=None, inside=None):
    ways = ways if ways is not None else [
        way(11, [1, 2, 3], [(24.999, 121.5), (25, 121.5), (25.001, 121.5)]),
        way(22, [4, 2, 5], [(25, 121.499), (25, 121.5), (25, 121.501)], name="交叉街"),
    ]
    return dict(city="新北市", district="新店區", coverage=["測試路", "交叉街"], ways=ways,
                insideNodes=inside if inside is not None else [1, 2, 3, 4, 5], version="2026-11-12T00:00:00Z")


def reference(**changes):
    return dict(dict(city="新北市", district="新店區", kind="door", key="測試路100號",
                     lat=25.0004, lon=121.5001, dataset="168887", version="11511",
                     sourceURL="https://data.gov.tw/dataset/168887"), **changes)


@pytest.mark.parametrize("address,kind,road,key,other", [
    ("淡水區淡金路一段５４７號前(往淡水)", "door", "淡金路1段", "淡金路1段547號", ""),
    ("淡水區新市二路3段燈桿431279(往新市二路2段方向)", "lamp", "新市二路3段", "431279", ""),
    ("環河西路三段091159號燈桿(往板橋)", "lamp", "環河西路3段", "091159", ""),
    ("泰林路3段與泰林路3段330巷口(往林口)", "intersection", "泰林路3段", "", "泰林路3段330巷"),
    ("溪東路178巷口(往三峽)", "intersection", "溪東路", "", "溪東路178巷"),
    ("明燈路3段25號(往瑞芳九份)", "door", "明燈路3段", "明燈路3段25號", ""),
    ("石榴路95-2號前，往斗六方向，速限50公里/小時。", "door", "石榴路", "石榴路95之2號", ""),
])
def test_announcement_address_parsing_is_exact_and_keeps_lamp_leading_zero(address, kind, road, key, other):
    query = geo.parse_address("新北市", "淡水區", address)
    assert (query.kind, query.road, query.key, query.other_road) == (kind, road, key, other)


@pytest.mark.parametrize("address", [
    "測試路", "測試路100號至200號", "測試路100號、交叉街200號",
    "測試路100號，交叉街200號", "測試路中油加油站前", "台9線12K至15K",
    "北47線蓬格幹78電桿處", "永福橋8H燈桿(往臺北)",
    "測試路燈桿00123與00456", "測試路燈桿00123、燈桿00456",
])
def test_ranges_landmarks_unverified_power_poles_and_multiple_doors_are_not_points(address):
    assert geo.parse_address("新北市", "新店區", address) is None


def test_twd97_conversion_matches_official_dual_coordinate_lamp_not_just_a_plausible_city():
    lat, lon = geo.twd97_to_wgs84(296216.187, 2778349.164)
    assert haversine(lat, lon, 25.112792, 121.458274) < .1
    with pytest.raises(ValueError):
        geo.twd97_to_wgs84(float("nan"), 2778349)
    with pytest.raises(ValueError):
        geo.twd97_to_wgs84(121.5, 25)


def test_exact_door_is_snapped_to_the_named_road_and_retains_source_version():
    g = geo.Geocoder([reference()], geo.RoadIndex([region()]))
    result = g.locate("新北市", "新店區", "測試路100號對面")
    assert result.method == "door" and result.point == pytest.approx((25.0004, 121.5))
    assert result.axis == 0 and result.details["snapDistance"] < 11
    assert "168887" in result.evidence and "11511" in result.evidence
    assert result.details["reference"]["key"] == "測試路100號"
    assert g.locate("新北市", "中和區", "測試路100號").reason_code == "door_not_found"
    assert g.locate("新北市", "新店區", "測試路101號").reason_code == "door_not_found"


def test_lamp_exact_original_identifier_uses_road_validation_not_house_number_interpretation():
    r = reference(kind="lamp", key="00123", dataset="123962")
    g = geo.Geocoder([r], geo.RoadIndex([region()]))
    assert g.locate("新北市", "新店區", "測試路00123號燈桿").method == "lamp"
    assert g.locate("新北市", "新店區", "測試路123號燈桿").reason_code == "lamp_not_found"


def test_duplicate_floors_at_one_door_are_accepted_but_different_coordinates_are_not_selected():
    index = geo.RoadIndex([region()])
    assert geo.Geocoder([reference(), reference()], index).locate("新北市", "新店區", "測試路100號").point
    g = geo.Geocoder([reference(), reference(lat=25.001)], index)
    assert g.locate("新北市", "新店區", "測試路100號").reason_code == "door_ambiguous"
    g = geo.Geocoder([reference(lat=float("nan"))], index)
    assert g.locate("新北市", "新店區", "測試路100號").reason_code == "invalid_reference_coordinate"


def test_door_too_far_from_same_name_road_does_not_fall_back_to_nearby_other_road():
    result = geo.Geocoder([reference(lon=121.501)], geo.RoadIndex([region()])).locate("新北市", "新店區", "測試路100號")
    assert result.point is None and result.reason_code == "road_too_far"
    assert "35 m" in result.reason
    result = geo.Geocoder([reference()], geo.RoadIndex([region(inside=[4, 5])])).locate("新北市", "新店區", "測試路100號")
    assert result.reason_code == "road_too_far"


def test_disconnected_same_name_roads_inside_snap_radius_are_ambiguous():
    roads = region()
    roads["ways"].append(way(33, [6, 7], [(24.999, 121.5002), (25.001, 121.5002)]))
    roads["insideNodes"] += [6, 7]
    result = geo.Geocoder([reference()], geo.RoadIndex([roads])).locate("新北市", "新店區", "測試路100號")
    assert result.point is None and result.reason_code == "road_ambiguous"


def test_only_unique_same_district_shared_drivable_node_is_an_intersection():
    result = geo.Geocoder([], geo.RoadIndex([region()])).locate("新北市", "新店區", "測試路與交叉街口")
    assert result.method == "intersection" and result.point == (25, 121.5) and result.axis == 0
    assert result.details["nodeID"] == 2 and result.details["wayIDs"] == [11, 22]
    assert "唯一同層共同節點" in result.evidence


@pytest.mark.parametrize("change", ["different-node", "bridge", "tunnel", "layer", "level", "private", "outside"])
def test_grade_crossings_or_non_drivable_or_outside_district_nodes_are_not_intersections(change):
    roads = region()
    if change == "different-node":
        roads["ways"][1]["nodes"][1] = 9
        roads["insideNodes"].append(9)
    elif change == "outside":
        roads["insideNodes"].remove(2)
    else:
        key, value = {"bridge": ("bridge", "yes"), "tunnel": ("tunnel", "yes"),
                      "layer": ("layer", "1"), "level": ("level", "1"), "private": ("access", "private")}[change]
        roads["ways"][1]["tags"][key] = value
    result = geo.Geocoder([], geo.RoadIndex([roads])).locate("新北市", "新店區", "測試路與交叉街口")
    assert result.point is None


def test_multiple_true_intersections_and_incomplete_road_coverage_are_not_uniquely_geocoded():
    roads = region()
    roads["ways"][1] = way(22, [2, 3], [(25, 121.5), (25.001, 121.5)], name="交叉街")
    g = geo.Geocoder([], geo.RoadIndex([roads]))
    assert g.locate("新北市", "新店區", "測試路與交叉街口").reason_code == "intersection_ambiguous"
    roads["coverage"].remove("交叉街")
    assert g.locate("新北市", "新店區", "測試路與交叉街口").reason_code == "road_data_missing"


def test_streaming_official_door_filter_matches_all_address_parts_and_reports_ambiguous_rows():
    spec = dict(dataset="168887", city="新北市", kind="door", crs="EPSG:3826", version="11511", url="https://example.invalid",
                columns=dict(district="code", road="road", area="area", lane="lane", alley="alley", number="number", x="x", y="y"))
    raw = ("code,road,area,lane,alley,number,x,y\n"
           "65000060,測試路,,,,１００號,296216.187,2778349.164\n"
           "65000060,測試路,,,,１００號二樓,296216.187,2778349.164\n"
           "65000060,測試路,,,1弄,１００號,296216.187,2778349.164\n"
           "65000030,測試路,,,,１００號,296216.187,2778349.164\n")
    wanted = {("新北市", "新店區", "door"): {"測試路100號"}}
    rows, count = refs.collect_references(io.StringIO(raw), spec, wanted, {"65000060": "新店區", "65000030": "中和區"})
    assert count == 4 and len(rows) == 1 and rows[0]["duplicateRows"] == 2
    assert rows[0]["raw"]["number"] == "１００號"
    with pytest.raises(ValueError):
        refs.collect_references(io.StringIO("different\nx\n"), spec, wanted, {})


def test_online_road_query_matches_chinese_segments_and_keeps_exact_name_not_substring():
    regex = refs._road_regex({"淡金路1段", "台2線"})
    assert re.fullmatch(regex, "淡金路一段") and re.fullmatch(regex, "淡金路1段")
    assert re.fullmatch(regex, "臺2線") and not re.fullmatch(regex, "淡金路11段")


def test_location_report_persists_success_method_and_separates_failure_reasons():
    report = SourceReport()
    report.location("test", "a", point=(25, 121.5), method="door", evidence="官方門牌")
    report.location("test", "b", code="road_ambiguous", reason="同名道路歧義")
    report.location("test", "c", code="road_too_far", reason="貼不上")
    assert report.counts["test"]["locationSuccess"] == 1
    assert report.counts["test"]["locationFailed"] == 2
    assert report.location_failures["test"] == {"road_ambiguous": 1, "road_too_far": 1}
    assert report.locations[0]["method"] == "door" and len(report.issues) == 2


def test_unavailable_or_corrupt_reference_snapshots_do_not_break_other_sources(monkeypatch, tmp_path):
    monkeypatch.setattr(refs, "SNAPSHOTS", tmp_path)
    (tmp_path / "manifest.json").write_text(json.dumps({}), encoding="utf-8")
    logs = []
    g = refs.load_geocoder([dict(city="新北市", district="新店區", address="測試路100號")], offline=True, log=logs.append)
    assert g.locate("新北市", "新店區", "測試路100號").point is None
    assert any("快照無法使用" in line for line in logs) and any("無可用快照" in line for line in logs)


def test_live_reference_and_overpass_failure_use_small_snapshot_with_explicit_warnings(monkeypatch):
    source = dict(dataset="168887", city="新北市", kind="door", version="11511")
    saved = dict(sources=[source], areas={"新北市": {}}, records=[reference()])
    monkeypatch.setattr(refs, "_snapshot", lambda name: saved if name == "addresses.json" else dict(regions=[region()]))
    calls = []

    def unavailable(*args):
        calls.append(args)
        raise OSError("服務逾時")

    monkeypatch.setattr(refs, "_fetch_references", unavailable)
    monkeypatch.setattr(refs, "fetch_roads", unavailable)
    logs = []
    g = refs.load_geocoder([dict(city="新北市", district="新店區", address="測試路100號")], log=logs.append)
    assert g.locate("新北市", "新店區", "測試路100號").method == "door"
    assert len(calls) == 3 and sum("使用 repo" in message for message in logs) == 2
    assert any("線上查核失敗" in message for message in logs) and any("OSM 定位服務本次不可用" in message for message in logs)


def test_valid_online_no_match_is_not_misreported_as_a_saved_address(monkeypatch):
    source = dict(dataset="168887", city="新北市", kind="door", version="11511")
    saved = dict(sources=[source], areas={"新北市": {}}, records=[])
    monkeypatch.setattr(refs, "_snapshot", lambda name: saved if name == "addresses.json" else dict(regions=[region()]))
    monkeypatch.setattr(refs, "_fetch_references", lambda *args: ([], 100))
    monkeypatch.setattr(refs, "fetch_roads", lambda *args: region())
    logs = []
    g = refs.load_geocoder([dict(city="新北市", district="新店區", address="測試路100號")], log=logs.append)
    assert g.locate("新北市", "新店區", "測試路100號").reason_code == "door_not_found"
    assert not any("使用 repo" in line for line in logs)


def test_snapshot_unknown_new_address_is_not_claimed_to_be_an_official_negative_lookup(monkeypatch):
    source = dict(dataset="168887", city="新北市", kind="door", version="11511")
    saved = dict(sources=[source], areas={"新北市": {}}, records=[reference()],
                 coverage=[["新北市", "新店區", "door", "測試路101號"]])
    monkeypatch.setattr(refs, "_snapshot", lambda name: saved if name == "addresses.json" else dict(regions=[region()]))
    requests = [dict(city="新北市", district="新店區", address=f"測試路{n}號") for n in (101, 102)]
    g = refs.load_geocoder(requests, offline=True, log=lambda _: None)
    assert g.locate("新北市", "新店區", "測試路101號").reason_code == "door_not_found"
    assert g.locate("新北市", "新店區", "測試路102號").reason_code == "reference_unavailable"


def test_streamed_live_reference_version_uses_content_hash_not_build_time(monkeypatch):
    import hashlib
    raw = b"town,id,x,y\nnew,00123,121.5,25\n"
    spec = dict(dataset="123962", city="新北市", kind="lamp", version="known", crs="EPSG:4326",
                url="https://example.invalid", encoding="utf-8", originSHA256=hashlib.sha256(raw).hexdigest(),
                columns=dict(district="town", key="id", x="x", y="y"))
    monkeypatch.setattr(refs.urllib.request, "urlopen", lambda *args, **kwargs: io.BytesIO(raw))
    rows, count = refs._fetch_references(spec, {("新北市", "new", "lamp"): {"00123"}}, {})
    assert count == 1 and rows[0]["version"] == "known" and rows[0]["originSHA256"] == spec["originSHA256"]
    spec["originSHA256"] = "old"
    updated, _ = refs._fetch_references(spec, {("新北市", "new", "lamp"): {"00123"}}, {})
    assert updated[0]["version"] == "SHA256:" + hashlib.sha256(raw).hexdigest()


def test_committed_location_snapshots_are_hash_verified_and_every_region_has_complete_node_geometry():
    addresses, roads = refs._snapshot("addresses.json"), refs._snapshot("roads.json.gz")
    assert len(addresses["records"]) == 142 and addresses["coverage"]
    assert all(r["boundaryRelation"] and r["coverage"] for r in roads["regions"])
    assert {"彰化縣", "雲林縣", "新北市", "臺北市"} <= {r["city"] for r in roads["regions"]}
    assert all(len(w["nodes"]) == len(w["geometry"]) for r in roads["regions"] for w in r["ways"])


@pytest.mark.parametrize("failure", [None, "two-districts", "incomplete", "bad-geometry", "outside-taiwan"])
def test_online_road_evidence_requires_unique_complete_administrative_topology(monkeypatch, failure):
    import urllib.parse
    roads = region()
    elements = [dict(type="relation", id=1, tags=dict(name="新店區", admin_level="7"))]
    elements += [dict(w, type="way") for w in roads["ways"]]
    elements += [dict(type="node", id=n) for n in roads["insideNodes"]]
    payload = dict(osm3s=dict(timestamp_osm_base="2026-11-12T00:00:00Z"), elements=elements)
    if failure == "two-districts":
        elements.append(dict(elements[0], id=99))
    elif failure == "incomplete":
        payload["remark"] = "runtime error: Query timed out"
    elif failure == "bad-geometry":
        elements[1]["geometry"] = []
    elif failure == "outside-taiwan":
        elements[1]["geometry"][0]["lat"] = 40
    urls = []
    def fetch(url, **kwargs):
        urls.append(url)
        return json.dumps(payload).encode()
    monkeypatch.setattr(refs.sources, "http_get", fetch)
    if failure:
        with pytest.raises(ValueError):
            refs.fetch_roads("新北市", "新店區", {"測試路", "交叉街"}, "https://example.invalid")
    else:
        found = refs.fetch_roads("新北市", "新店區", {"測試路", "交叉街"}, "https://example.invalid")
        assert found["boundaryRelation"] == 1 and len(found["ways"]) == 2 and found["insideNodes"] == [1, 2, 3, 4, 5]
    query = urllib.parse.parse_qs(urllib.parse.urlsplit(urls[0]).query)["data"][0]
    assert '"admin_level"~"^(7|8)$"' in query and "(?:" not in query


def divided_roads():
    return region([
        way(11, [1, 2], [(24.9994, 121.5), (25.0014, 121.5)], oneway="yes"),
        way(33, [6, 7], [(25.0014, 121.5002), (24.9994, 121.5002)], oneway="yes"),
    ], inside=[1, 2, 6, 7])


def direction_landmark():
    return dict(city="新北市", name="測試橋", version="2026-11-12T00:00:00Z",
                sourceURL="https://download.geofabrik.de/asia/taiwan-latest.osm.pbf", pbfMD5="verified",
                ways=[way(99, [8, 9], [(25.01, 121.5), (25.011, 121.5)], name="測試橋", bridge="yes")])


@pytest.mark.parametrize("reverse_nodes", [False, True])
def test_noise_divider_uses_verified_landmark_and_actual_oneway_not_nearest_lane(reverse_nodes):
    roads = divided_roads()
    if reverse_nodes:
        roads["ways"][0]["nodes"].reverse()
        roads["ways"][0]["geometry"].reverse()
        roads["ways"][0]["tags"]["oneway"] = "-1"
    g = geo.Geocoder([reference(lon=121.50015)], geo.RoadIndex([roads], [direction_landmark()]))
    result = g.locate("新北市", "新店區", "測試路100號對面(往測試橋方向)", allow_divided=True)
    assert result.point == pytest.approx((25.0004, 121.5), abs=1e-9, rel=0)
    assert result.heading == 0 and result.axis is None and result.method == "door"
    assert result.details["positionChoice"] == "carriageway"
    assert result.details["directionTarget"]["wayIDs"] == [99]
    assert result.details["snapDistance"] > min(c["snapDistance"] for c in result.details["dividedCarriageways"])
    assert "168887" in result.evidence and "單行行向核對" in result.evidence


@pytest.mark.parametrize("address", [
    "測試路100號對面", "測試路100號(往未知橋方向)", "測試路100號(上山方向)",
])
def test_noise_divider_without_unique_direction_uses_midpoint_and_road_axis(address):
    g = geo.Geocoder([reference()], geo.RoadIndex([divided_roads()], [direction_landmark()]))
    result = g.locate("新北市", "新店區", address, allow_divided=True)
    assert result.point == pytest.approx((25.0004, 121.5001), abs=1e-9, rel=0)
    assert result.axis == 0 and result.heading is None and result.method == "door"
    assert result.details["positionChoice"] == "midpoint"
    assert result.details["snapDistance"] <= 35
    assert "分向車道無法判定，沿路雙向" in result.evidence


@pytest.mark.parametrize("change", [
    "duplicate-landmark", "crosswise-landmark", "conditional-oneway", "conditional-opposite",
])
def test_noise_divider_does_not_infer_a_single_heading_from_ambiguous_or_conditional_evidence(change):
    roads, landmarks = divided_roads(), [direction_landmark()]
    if change == "duplicate-landmark":
        landmarks.append(direction_landmark())
    elif change == "crosswise-landmark":
        landmarks[0]["ways"][0]["geometry"] = [
            dict(lat=25.0004, lon=121.51), dict(lat=25.0014, lon=121.51),
        ]
    else:
        index = 1 if change == "conditional-opposite" else 0
        roads["ways"][index]["tags"]["oneway:conditional"] = "-1 @ (Mo-Fr 07:00-09:00)"
    g = geo.Geocoder([reference()], geo.RoadIndex([roads], landmarks))
    result = g.locate("新北市", "新店區", "測試路100號(往測試橋方向)", allow_divided=True)
    assert result.point == pytest.approx((25.0004, 121.5001), abs=1e-9, rel=0)
    assert result.heading is None and result.axis == 0
    assert "分向車道無法判定，沿路雙向" in result.evidence
    assert "不猜方向" in result.evidence


@pytest.mark.parametrize("change", [
    "cross-axis", "shallow-crossing", "elevated", "different-class",
    "end-to-end", "third-road", "same-flow", "missing-oneway", "roundabout",
])
def test_noise_divider_still_rejects_crossings_unverified_lanes_and_nonparallel_branches(change):
    roads = divided_roads()
    second = roads["ways"][1]
    if change == "cross-axis":
        second["geometry"] = [dict(lat=25.0004, lon=121.499), dict(lat=25.0004, lon=121.501)]
    elif change == "shallow-crossing":
        second["geometry"] = [dict(lat=25.0014, lon=121.50022), dict(lat=24.9994, lon=121.49982)]
    elif change == "elevated":
        second["tags"].update(bridge="yes", layer="1")
    elif change == "different-class":
        second["tags"]["highway"] = "service"
    elif change == "end-to-end":
        roads["ways"][0]["geometry"][-1]["lat"] = 25.0003
        second["geometry"][-1]["lat"] = 25.0005
    elif change == "third-road":
        roads["ways"].append(way(44, [10, 12], [(24.9994, 121.5003), (25.0014, 121.5003)], oneway="yes"))
        roads["insideNodes"] += [10, 12]
    elif change == "same-flow":
        second["tags"]["oneway"] = "-1"
    elif change == "roundabout":
        second["tags"]["junction"] = "roundabout"
    else:
        del second["tags"]["oneway"]
    g = geo.Geocoder([reference()], geo.RoadIndex([roads]))
    result = g.locate("新北市", "新店區", "測試路100號", allow_divided=True)
    assert result.point is None and result.reason_code == "road_ambiguous"
    assert result.reason == "35 m 內有分離或不同軸向的同名道路投影；不選最近一條"


@pytest.mark.parametrize("angle,accepted", [(14.9, True), (15.1, False)])
def test_noise_divider_local_axis_difference_is_limited_to_fifteen_degrees(angle, accepted):
    roads = divided_roads()
    dy = .001 * math.cos(math.radians(angle))
    dx = .001 * math.sin(math.radians(angle)) / math.cos(math.radians(25.0004))
    roads["ways"][1]["geometry"] = [
        dict(lat=25.0004 + dy, lon=121.5002 + dx), dict(lat=25.0004 - dy, lon=121.5002 - dx),
    ]
    g = geo.Geocoder([reference()], geo.RoadIndex([roads]))
    result = g.locate("新北市", "新店區", "測試路100號", allow_divided=True)
    assert (result.point is not None) is accepted
    if not accepted:
        assert result.reason_code == "road_ambiguous"


def test_noise_divider_axis_mean_wraps_at_north_and_is_independent_of_way_order():
    roads = divided_roads()
    for w, angle, lon in zip(roads["ways"], (179, 1), (121.5, 121.5002)):
        dy = .001 * math.cos(math.radians(angle))
        dx = .001 * math.sin(math.radians(angle)) / math.cos(math.radians(25.0004))
        w["geometry"] = [dict(lat=25.0004 - dy, lon=lon - dx), dict(lat=25.0004 + dy, lon=lon + dx)]
    g = geo.Geocoder([reference()], geo.RoadIndex([roads]))
    first = g.locate("新北市", "新店區", "測試路100號", allow_divided=True)
    roads["ways"].reverse()
    second = g.locate("新北市", "新店區", "測試路100號", allow_divided=True)
    assert first.point is not None and first.heading is None and first.axis == 0
    assert first == second


def test_noise_divider_keeps_transitively_connected_osm_fragments_in_the_same_carriageway():
    roads = divided_roads()
    roads["ways"] = [
        way(11, [1, 2], [(25.0001, 121.5), (25.0003, 121.5)], oneway="yes"),
        way(12, [2, 3], [(25.0003, 121.5), (25.0005, 121.5)], oneway="yes"),
        way(13, [3, 4], [(25.0005, 121.5), (25.0007, 121.5)], oneway="yes"),
        roads["ways"][1],
    ]
    roads["insideNodes"] += [3, 4]
    result = geo.Geocoder([reference()], geo.RoadIndex([roads])).locate(
        "新北市", "新店區", "測試路100號", allow_divided=True)
    assert result.point == pytest.approx((25.0004, 121.5001), abs=1e-9, rel=0)
    assert result.details["wayIDs"] == [11, 12, 13, 33]


def test_noise_divider_does_not_treat_two_arms_of_one_hairpin_way_as_separate_carriageways():
    roads = region([
        way(11, [1, 2, 6, 7], [(24.9994, 121.5), (25.002, 121.5),
                               (25.002, 121.5002), (24.9994, 121.5002)], oneway="yes"),
    ], inside=[1, 2, 6, 7])
    result = geo.Geocoder([reference()], geo.RoadIndex([roads])).locate(
        "新北市", "新店區", "測試路100號", allow_divided=True)
    assert result.point is None and result.reason_code == "road_ambiguous"


def test_noise_divider_opt_in_does_not_relax_exact_door_reference_or_thirty_five_metre_limit():
    index = geo.RoadIndex([divided_roads()], [direction_landmark()])
    g = geo.Geocoder([reference()], index)
    assert g.locate("新北市", "新店區", "測試路100號").reason_code == "road_ambiguous"
    assert g.locate("新北市", "新店區", "測試路101號", allow_divided=True).reason_code == "door_not_found"
    g = geo.Geocoder([reference(), reference(lat=25.001)], index)
    assert g.locate("新北市", "新店區", "測試路100號", allow_divided=True).reason_code == "door_ambiguous"
    g = geo.Geocoder([reference(lon=121.501)], index)
    result = g.locate("新北市", "新店區", "測試路100號(往測試橋方向)", allow_divided=True)
    assert result.point is None and result.reason_code == "road_too_far"


@pytest.mark.parametrize("failure", [None, "source-missing", "origin-mismatch", "geometry-missing", "invalid-coordinate"])
def test_direction_landmark_snapshot_has_the_same_hash_source_and_geometry_guards(monkeypatch, tmp_path, failure):
    import gzip
    import hashlib
    landmark = direction_landmark()
    payload = dict(regions=[region()], landmarks=[landmark],
                   **{k: landmark[k] for k in ("sourceURL", "pbfMD5", "version")})
    if failure == "source-missing":
        del landmark["sourceURL"]
    elif failure == "origin-mismatch":
        landmark["pbfMD5"] = "different-origin"
    elif failure == "geometry-missing":
        landmark["ways"][0]["geometry"].pop()
    elif failure == "invalid-coordinate":
        landmark["ways"][0]["geometry"][0]["lat"] = float("nan")
    raw = gzip.compress(json.dumps(payload).encode())
    (tmp_path / "roads.json.gz").write_bytes(raw)
    (tmp_path / "manifest.json").write_text(json.dumps({"roads.json.gz": {"sha256": hashlib.sha256(raw).hexdigest()}}))
    monkeypatch.setattr(refs, "SNAPSHOTS", tmp_path)
    if failure:
        with pytest.raises(ValueError):
            refs._snapshot("roads.json.gz")
    else:
        assert refs._snapshot("roads.json.gz")["landmarks"] == [landmark]
        (tmp_path / "roads.json.gz").write_bytes(raw + b"changed")
        with pytest.raises(ValueError, match="雜湊不符"):
            refs._snapshot("roads.json.gz")


@pytest.mark.parametrize("kind", ["door", "lamp"])
def test_ntpc_mobile_divider_uses_the_same_landmark_oneway_and_exact_reference_rules(kind):
    from speedcam_data import additional_sources as extra
    r = reference(lon=121.50015)
    address = "測試路100號對面(往測試橋方向)"
    if kind == "lamp":
        r.update(kind="lamp", key="00123", dataset="123962")
        address = "測試路00123號燈桿(往測試橋方向)"
    g = geo.Geocoder([r], geo.RoadIndex([divided_roads()], [direction_landmark()]))
    report = SourceReport()
    cameras = extra.adapt_mobile([dict(district="新店區", address=address)], "ntpc-mobile", report, geocoder=g)
    assert len(cameras) == 1
    camera = cameras[0]
    assert (camera.lat, camera.lon) == pytest.approx((25.0004, 121.5), abs=1e-9, rel=0)
    assert camera.heading == 0 and camera.axis is None and camera.positionMethod == kind
    assert not camera.enforces_speed and camera.speedLimit is None and camera.type == "mobile"
    assert "公告候選地點，非即時執法" in camera.conditions and "單行行向核對" in camera.conditions
    assert report.mobile_directions[0]["status"] == "directional"
    assert report.locations[0]["details"]["reference"]["key"] == r["key"]
    if kind == "lamp":
        missing = SourceReport()
        assert extra.adapt_mobile([dict(district="新店區", address=address.replace("00123", "123"))],
                                  "ntpc-mobile", missing, geocoder=g) == []
        assert missing.location_failures["ntpc-mobile"] == {"lamp_not_found": 1}


@pytest.mark.parametrize("suffix", ["", "(往未知橋方向)", "(往北)", "(往測試橋方向，雙向)"])
def test_ntpc_mobile_divider_without_unique_or_exclusively_single_direction_uses_h7_midpoint(suffix):
    from speedcam_data import additional_sources as extra
    g = geo.Geocoder([reference(lon=121.50015)], geo.RoadIndex([divided_roads()], [direction_landmark()]))
    report = SourceReport()
    camera, = extra.adapt_mobile([dict(district="新店區", address="測試路100號" + suffix)],
                                "ntpc-mobile", report, geocoder=g)
    assert (camera.lat, camera.lon) == pytest.approx((25.0004, 121.5001), abs=1e-9, rel=0)
    assert camera.heading is None and camera.axis == 0
    assert "分向車道無法判定，沿路雙向" in camera.conditions
    assert report.locations[0]["details"]["positionChoice"] == "midpoint"
    assert report.locations[0]["lat"] == camera.lat and report.locations[0]["lon"] == camera.lon


def test_ntpc_mobile_conflicting_official_and_osm_directions_publish_only_the_midpoint_and_report_conflict():
    from speedcam_data import additional_sources as extra
    landmark = direction_landmark()
    landmark["name"] = "北"
    landmark["ways"][0]["tags"]["name"] = "北"
    landmark["ways"][0]["geometry"] = [dict(lat=24.99, lon=121.5), dict(lat=24.989, lon=121.5)]
    g = geo.Geocoder([reference(lon=121.50015)], geo.RoadIndex([divided_roads()], [landmark]))
    report = SourceReport()
    camera, = extra.adapt_mobile([dict(district="新店區", address="測試路100號(往北)")],
                                "ntpc-mobile", report, geocoder=g)
    assert (camera.lat, camera.lon) == pytest.approx((25.0004, 121.5001), abs=1e-9, rel=0)
    assert camera.heading is None and camera.axis == 0
    assert "不發布單向" in camera.conditions and "分向車道無法判定，沿路雙向" in camera.conditions
    assert len(report.conflicts) == 1 and "衝突" in report.conflicts[0]
    conflict = report.locations[0]["details"]["directionConflict"]
    assert conflict["officialHeading"] == 0 and conflict["osmHeading"] == 180
    assert report.mobile_directions[0]["status"] == "unresolved"


@pytest.mark.parametrize("change", ["cross-axis", "third-road", "missing-oneway"])
def test_ntpc_mobile_opt_in_still_rejects_non_h7_carriageways(change):
    from speedcam_data import additional_sources as extra
    roads = divided_roads()
    if change == "cross-axis":
        roads["ways"][1]["geometry"] = [dict(lat=25.0004, lon=121.499), dict(lat=25.0004, lon=121.501)]
    elif change == "third-road":
        roads["ways"].append(way(44, [10, 12], [(24.9994, 121.5003), (25.0014, 121.5003)], oneway="yes"))
        roads["insideNodes"] += [10, 12]
    else:
        del roads["ways"][1]["tags"]["oneway"]
    g = geo.Geocoder([reference()], geo.RoadIndex([roads]))
    report = SourceReport()
    assert extra.adapt_mobile([dict(district="新店區", address="測試路100號")],
                              "ntpc-mobile", report, geocoder=g) == []
    assert report.location_failures["ntpc-mobile"] == {"road_ambiguous": 1}


def test_new_divider_candidates_follow_old_points_so_150_metre_dedupe_keeps_existing_id_and_position():
    from speedcam_data import additional_sources as extra
    from speedcam_data.source_merge import merge_sources
    roads = divided_roads()
    roads["ways"].append(way(55, [13, 14], [(24.9994, 121.5007), (25.0014, 121.5007)], name="既有路"))
    roads["insideNodes"] += [13, 14]
    roads["coverage"].append("既有路")
    g = geo.Geocoder([reference(), reference(key="既有路200號", lon=121.5007)], geo.RoadIndex([roads]))
    old_row = dict(district="新店區", address="既有路200號")
    original, = extra.adapt_mobile([old_row], "ntpc-mobile", SourceReport(), geocoder=g)
    candidates = extra.adapt_mobile([dict(district="新店區", address="測試路100號"), old_row],
                                    "ntpc-mobile", SourceReport(), geocoder=g)
    assert len(candidates) == 2 and candidates[0].to_json() == original.to_json()
    report = SourceReport()
    camera, = merge_sources([], candidates, report)
    assert (camera.id, camera.lat, camera.lon, camera.heading, camera.axis) == (
        original.id, original.lat, original.lon, original.heading, original.axis)
    assert report.counts["ntpc-mobile"]["added"] == report.counts["ntpc-mobile"]["merged"] == 1


@pytest.mark.parametrize("distance,heading,directed,absorbed", [
    (149, 0, True, True), (151, 0, True, False), (149, 180, True, False),
    (149, None, False, True),
])
def test_divider_hotspots_keep_the_existing_fixed_priority_radius_and_direction_rules(distance, heading, directed, absorbed):
    from speedcam_data import additional_sources as extra
    from speedcam_data.normalize import Camera
    from speedcam_data.source_merge import merge_sources
    g = geo.Geocoder([reference()], geo.RoadIndex([divided_roads()], [direction_landmark()]))
    suffix = "(往測試橋方向)" if directed else ""
    hotspot, = extra.adapt_mobile([dict(district="新店區", address="測試路100號" + suffix)],
                                  "ntpc-mobile", SourceReport(), geocoder=g)
    fixed = Camera(id="fixed", type="fixed", lat=hotspot.lat + distance / 111195,
                   lon=hotspot.lon, heading=heading, speedLimit=50, address="既有測速")
    report = SourceReport()
    result = merge_sources([fixed], [hotspot], report)
    assert {c.id for c in result} == ({"fixed"} if absorbed else {"fixed", hotspot.id})
    assert any("固定優先" in issue for issue in report.issues) is absorbed
