import io
import json
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
