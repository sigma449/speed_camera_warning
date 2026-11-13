import gzip
import hashlib
import json
from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_cameras
from speedcam_data import additional_sources as extra, osm_cameras as osm, sources
from speedcam_data.normalize import Camera
from speedcam_data.source_merge import SourceReport, merge_sources


@pytest.mark.parametrize("source_id,count,point", [
    ("178144", 3, (24.791551, 121.012156)),
    ("164507", 110, None), ("123740", 173, None), ("52544", 11, None),
    ("83881", 224, None), ("172940", 4, None), ("130111", 144, None),
    ("27969", 58, None), ("178358", 96, None), ("156415", 32, None),
    ("38357", 36, None), ("178119", 35, None), ("172905", 57, None), ("178357", 22, None),
])
def test_each_official_adapter_accepts_verified_file_without_losing_functions(source_id, count, point):
    source = next(s for s in extra.OFFICIAL_SOURCES if s.id == source_id)
    rows = sources.parse_payload((extra.SNAPSHOTS / f"{source_id}.raw").read_bytes())
    report = SourceReport()
    cameras = source.adapter(rows, report)
    assert len(cameras) == len({c.id for c in cameras}) == count
    assert all(c.enforcementItems and c.positionMethod == "official-coordinate" for c in cameras)
    assert all(21.8 <= c.lat <= 26.4 and 118.1 <= c.lon <= 122.1 for c in cameras)
    if point:
        assert any((c.lat, c.lon) == point and c.enforces_speed for c in cameras)
    if source_id in ("178358", "178357", "178119"):
        assert any("反置" in issue for issue in report.issues)
    if source_id == "156415":
        assert not any("20.77" in c.address for c in cameras)
        assert any("隔離" in issue for issue in report.issues)


def test_direction_specific_limits_do_not_collapse_to_minimum():
    rows = sources.parse_payload((extra.SNAPSHOTS / "130111.raw").read_bytes())
    cameras = extra.adapt_130111([r for r in rows if "\n" in r["速限-速度限制"]], SourceReport())
    assert {(c.heading, c.speedLimit) for c in cameras} == {(0, 50), (180, 60)}


def test_conditional_vehicle_or_lane_limits_remain_text_not_beep_threshold():
    rows = sources.parse_payload((extra.SNAPSHOTS / "38357.raw").read_bytes())
    cameras = extra.adapt_38357([r for r in rows if "砂石車" in r["限速（km／hr）"]], SourceReport())
    assert len(cameras) == 2
    assert all(c.speedLimit is None and "砂石車50" in c.conditions for c in cameras)
    rows = sources.parse_payload((extra.SNAPSHOTS / "27969.raw").read_bytes())
    cameras = extra.adapt_27969([r for r in rows if "慢車道" in r["備註"]], SourceReport())
    assert cameras and all(c.speedLimit is None and "慢車道" in c.conditions for c in cameras)


def test_non_speed_technology_is_not_speed_enforcement_even_with_limit():
    rows = sources.parse_payload((extra.SNAPSHOTS / "172905.raw").read_bytes())
    cameras = extra.adapt_172905([r for r in rows if r["取締項目"] == "闖紅燈"], SourceReport())
    assert cameras and all(c.type == "tech" and c.speedLimit and not c.enforces_speed for c in cameras)


@pytest.mark.parametrize("source_id,adapter,count", [
    ("173697", extra.adapt_173697, 9), ("156743", extra.adapt_156743, 324),
])
def test_sound_camera_without_coordinates_is_explicitly_not_published(source_id, adapter, count):
    rows = sources.parse_payload((extra.SNAPSHOTS / f"{source_id}.raw").read_bytes())
    report = SourceReport()
    assert adapter(rows, report) == []
    assert len(report.issues) == count
    assert all("無座標" in issue for issue in report.issues)


def test_nested_official_table_does_not_destroy_outer_mobile_rows():
    raw = "<table><tr><th>地區別</th><th>地點</th></tr><tr><td>坪林區</td><td>臺9線<table><tr><td>31.7K</td></tr></table>雙向</td></tr></table>"
    assert extra.parse_ntpc_mobile(raw.encode()) == [{"district": "坪林區", "address": "臺9線31.7K雙向"}]
    with pytest.raises(ValueError):
        extra.parse_ntpc_mobile(b"<html>not a table</html>")


def test_mobile_exact_milepost_uses_metres_and_axis_but_never_segment_center():
    calls = []

    def resolve(road, km):
        calls.append((road, km))
        return 25 + km / 1000, 121.5

    rows = [{"district": "林口區", "address": "臺61線12.4K+70M(往東)"},
            {"district": "坪林區", "address": "臺9線31.7公里雙向"},
            {"district": "林口區", "address": "臺61線12.4K至15K"}]
    report = SourceReport()
    cameras = extra.adapt_mobile(rows, "ntpc-mobile", report, resolve=resolve)
    assert len(cameras) == 2
    assert calls[0] == ("台61", 12.47)
    assert cameras[0].heading == 90
    assert cameras[1].heading is None and cameras[1].axis == 0
    assert all(c.type == "mobile" and c.speedLimit is None and not c.enforces_speed for c in cameras)
    assert any("未發布" in issue and "15K" in issue for issue in report.issues)


def test_mobile_missing_milepost_or_ambiguous_intersection_is_not_guessed():
    rows = [{"district": "新店區", "address": "中正路與中央路口"},
            {"district": "坪林區", "address": "臺9線31.7公里"}]
    junctions = [cam("a", lat=25.0, address=rows[0]["address"]), cam("b", lat=25.01, address=rows[0]["address"])]
    report = SourceReport()
    assert extra.adapt_mobile(rows, "ntpc-mobile", report, resolve=lambda *args: None, junctions=junctions) == []
    assert len(report.issues) == 2


def test_mobile_named_destination_uses_same_road_administrative_mileage_not_compass_guess():
    rows = [{"district": "石碇區", "address": f"臺9線22.5K(往{target})"}
            for target in ("新店", "宜蘭", "未核實地名")]
    xindian = cam("xindian", address="臺9線14.5K")
    yilan = cam("yilan", address="臺9線78K")
    yilan.city, yilan.district = "宜蘭縣", "宜蘭市"
    report = SourceReport()
    cameras = extra.adapt_mobile(rows, "ntpc-mobile", report,
                                 resolve=lambda road, km: (25, 121.5 + km / 1000),
                                 junctions=[xindian, yilan])
    assert [c.heading for c in cameras] == [270, 90, None]
    assert cameras[2].axis == 90
    assert [r["status"] for r in report.mobile_directions] == ["directional", "directional", "unresolved"]
    assert any("未核實地名" in issue and "沿路雙向軸向" in issue for issue in report.issues)
    assert "減少" in cameras[0].conditions and "增加" in cameras[1].conditions


def test_mobile_bidirectional_and_ambiguous_destinations_keep_local_axis_including_curves():
    rows = [{"district": "金山區", "address": f"臺2甲線2K{suffix}"}
            for suffix in ("雙向", "(往金山)", "(往臺北)", "(往北市)", "")]
    a = cam("a", address="臺2甲線1K")
    b = cam("b", address="臺2甲線3K")
    a.district = b.district = "金山區"
    # 這一小段里程增加時向西，不能把「往金山」猜成地圖上的北方。
    report = SourceReport()
    cameras = extra.adapt_mobile(rows, "ntpc-mobile", report,
                                 resolve=lambda road, km: (25, 121.5 - km / 1000), junctions=[a, b])
    assert len(cameras) == 5
    assert all(c.heading is None and c.axis == 90 for c in cameras)
    assert report.counts["ntpc-mobile"]["bidirectional"] == 1
    assert report.counts["ntpc-mobile"]["unresolved"] == 4
    assert any("跨越" in issue for issue in report.issues)
    assert all(row["evidence"] for row in report.mobile_directions)


def test_mobile_destination_names_keep_bali_and_do_not_mix_branch_roads_or_osm():
    rows = [{"district": "林口區", "address": f"臺61線12K(往{target})"} for target in ("八里", "臺北", "金山")]
    bali = cam("bali", address="臺61線2K")
    bali.district = "八里區"
    wrong_road = cam("branch", address="臺61乙線1K")
    wrong_road.city, wrong_road.district = "臺北市", "北投區"
    unverified = cam("osm", source="osm", address="臺61線1K")
    unverified.district = "金山區"
    cameras = extra.adapt_mobile(rows, "ntpc-mobile", SourceReport(),
                                 resolve=lambda road, km: (25 + km / 1000, 121.5),
                                 junctions=[bali, wrong_road, unverified])
    assert [c.heading for c in cameras] == [180, None, None]
    assert cameras[1].axis == cameras[2].axis == 0


def test_mobile_without_adjacent_geometry_reports_missing_axis_instead_of_cross_road_alert():
    report = SourceReport()
    rows = [{"district": "坪林區", "address": "臺9線33K(往未知)"}]
    assert extra.adapt_mobile(rows, "ntpc-mobile", report, resolve=lambda *args: (25, 121.5)) == []
    assert report.counts["ntpc-mobile"]["unresolved"] == 1
    assert any("缺道路軸向，未發布" in issue for issue in report.issues)


def test_mobile_junction_matching_preserves_road_name_characters():
    rows = [{"district": "新店區", "address": "臺北路與中正路口"}]
    junctions = [cam("other-road", address="北路與中正路口")]
    report = SourceReport()
    assert extra.adapt_mobile(rows, "ntpc-mobile", report, junctions=junctions) == []
    assert len(report.issues) == 1
    junctions[0].address = "台北路與中正路口"
    assert len(extra.adapt_mobile(rows, "ntpc-mobile", SourceReport(), junctions=junctions)) == 1


def test_kaohsiung_road_only_announcement_is_not_turned_into_point():
    rows = sources.parse_payload((extra.SNAPSHOTS / "169075.raw").read_bytes())
    report = SourceReport()
    assert extra.adapt_mobile(rows, "169075", report) == []
    assert len(report.issues) == 95


def cam(identity, *, source=None, kind="fixed", heading=0, lat=25, limit=50, address="測試路", items=None):
    return Camera(id=identity, type=kind, lat=lat, lon=121.5, heading=heading, speedLimit=limit,
                  address=address, city="新北市", district="新店區", source=source, sourceID=identity,
                  enforcementItems=items)


def test_conflicting_official_source_preserves_primary_id_limit_and_direction():
    report = SourceReport()
    original = cam("primary", heading=0, limit=50)
    incoming = cam("other", source="164507", kind="tech", lat=25.0003, heading=10, limit=60, items="闖紅燈")
    merged = merge_sources([original], [incoming], report)
    assert len(merged) == 1 and merged[0].id == "primary"
    assert merged[0].heading == 0 and merged[0].speedLimit == 50 and merged[0].enforces_speed
    assert merged[0].type == "tech"
    assert "闖紅燈" in merged[0].enforcementItems
    assert len(report.conflicts) == 1 and report.counts["164507"]["merged"] == 1


def test_mobile_150_metre_dedupe_retains_opposite_direction_and_fixed_wins():
    additions = [cam("m1", source="mobile", kind="mobile", lat=25.001),
                 cam("m2", source="mobile", kind="mobile", lat=25.0011),
                 cam("opposite", source="mobile", kind="mobile", heading=180)]
    report = SourceReport()
    result = merge_sources([cam("fixed")], additions, report)
    assert {c.id for c in result} == {"fixed", "opposite"}
    assert report.counts["mobile"]["merged"] == 2
    assert sum("固定優先" in issue for issue in report.issues) == 2
    result = merge_sources([], additions, SourceReport())
    assert len(result) == 2


def test_unknown_direction_hotspot_at_fixed_device_does_not_duplicate_warning():
    result = merge_sources([cam("fixed")], [cam("hotspot", source="mobile", kind="mobile", heading=None)], SourceReport())
    assert {c.id for c in result} == {"fixed"}


def test_explicit_different_road_levels_are_not_merged_by_distance():
    elevated, surface = cam("above"), cam("below", source="123740")
    elevated.level, surface.level = "elevated", "surface"
    assert len(merge_sources([elevated], [surface], SourceReport())) == 2


def test_osm_unknown_direction_distance_overlap_does_not_overwrite_official():
    report = SourceReport()
    original = cam("official", heading=90, limit=50)
    osm_camera = cam("osm", source="osm", heading=None, limit=40)
    result = merge_sources([original], [osm_camera], report)
    assert len(result) == 1 and result[0].speedLimit == 50
    assert "方向不足" in report.issues[0]
    result = merge_sources([original], [cam("opposite", source="osm", heading=270)], SourceReport())
    assert len(result) == 2


def node(identity, lat=25, lon=121.5, **tags):
    return {"type": "node", "id": identity, "lat": lat, "lon": lon, "tags": tags}


def relation(identity, origin, device, destination=None, **tags):
    return {"type": "relation", "id": identity, "tags": {"type": "enforcement", "enforcement": "maxspeed", **tags},
            "members": [{"type": "node", "ref": origin, "role": "from"},
                        {"type": "node", "ref": device, "role": "device"}]
                       + ([{"type": "node", "ref": destination, "role": "to"}] if destination else [])}


@pytest.mark.parametrize("direction", ["N", "90", "SW", "forward"])
def test_osm_camera_facing_alone_does_not_invent_vehicle_heading(direction):
    report = SourceReport()
    cameras = osm.parse_cameras([node(1, highway="speed_camera", direction=direction)], report)
    assert len(cameras) == 1 and cameras[0].heading is None and cameras[0].speedLimit is None
    assert direction in cameras[0].conditions
    assert any("不據此猜車行向" in issue for issue in report.issues)


def test_osm_relation_from_to_wins_over_facing_and_does_not_duplicate_device():
    elements = [node(1, lat=24.999), node(2, highway="speed_camera", direction="N", maxspeed="50"),
                node(3, lat=25.001), relation(7, 1, 2, 3)]
    report = SourceReport()
    cameras = osm.parse_cameras(elements, report)
    assert len(cameras) == 1 and cameras[0].heading == 0 and cameras[0].speedLimit == 50
    assert cameras[0].sourceURL == "https://www.openstreetmap.org/relation/7"
    assert any("不據此猜車行向" in issue for issue in report.issues)
    elements.append(relation(8, 3, 2, 1))
    assert {c.heading for c in osm.parse_cameras(elements, SourceReport())} == {0, 180}


def test_osm_roadside_device_without_to_does_not_create_slanted_heading():
    elements = [node(1, lat=24.999), node(2, lon=121.5004), relation(7, 1, 2)]
    report = SourceReport()
    cameras = osm.parse_cameras(elements, report)
    assert len(cameras) == 1 and cameras[0].heading is None
    assert any("斜角" in issue for issue in report.issues)


def test_osm_average_speed_and_nonpoint_objects_do_not_invent_point_or_section():
    elements = [node(1), node(2), relation(7, 1, 2, enforcement="average_speed"),
                {"type": "way", "id": 8, "nodes": [1, 2], "tags": {"highway": "speed_camera"}}]
    report = SourceReport()
    assert osm.parse_cameras(elements, report) == []
    assert len(report.issues) == 2


def test_osm_conflicting_or_conditional_limit_never_creates_false_threshold():
    elements = [node(1), node(2, maxspeed="50"), relation(7, 1, 2, maxspeed="60")]
    report = SourceReport()
    assert osm.parse_cameras(elements, report)[0].speedLimit is None
    camera = osm.parse_cameras([node(3, highway="speed_camera", **{"maxspeed:conditional": "40 @ (wet)"})], SourceReport())[0]
    assert camera.speedLimit is None and "40 @ (wet)" in camera.conditions
    camera = osm.parse_cameras([node(4, highway="speed_camera", maxspeed="60",
                                   **{"maxspeed:conditional": "40 @ (wet)"})], SourceReport())[0]
    assert camera.speedLimit is None and "40 @ (wet)" in camera.conditions


def test_osm_only_comparison_distinguishes_opposite_and_unknown_directions():
    official = [cam("official", heading=0)]
    osm_cameras = [cam("match", heading=0), cam("unknown", heading=None), cam("other", heading=180)]
    result = osm.comparison(osm_cameras, official)
    assert (result["directionMatched"], result["distanceOverlapUnknownDirection"], result["osmOnly"],
            result["osmOnlyWithHeadingAndLimit"]) == (1, 1, 1, 1)


def test_osm_comparison_and_merge_do_not_hide_known_mismatched_axes_or_separate_devices():
    axis = cam("axis", heading=None)
    axis.axis = 0
    crossing = cam("crossing", source="osm", heading=90)
    assert osm.comparison([crossing], [axis])["osmOnly"] == 1
    assert len(merge_sources([axis], [crossing], SourceReport())) == 2
    first, next_device = cam("one", source="osm", lat=25.001), cam("two", source="osm", lat=25.0015)
    assert len(merge_sources([], [first, next_device], SourceReport())) == 2


@pytest.mark.parametrize("obj", [[], {"elements": [{}]}, {"osm3s": [], "elements": []},
                                {"osm3s": {"timestamp_osm_base": "now"}, "elements": [node(1, lat="bad")]},
                                {"osm3s": {"timestamp_osm_base": "now"}, "elements": [{"type": "relation", "id": 1, "members": ["bad"]}]}])
def test_malformed_overpass_response_fails_validation_before_build(obj):
    with pytest.raises(ValueError):
        osm.validate(json.dumps(obj).encode())


def test_optional_source_failure_and_shrinkage_use_snapshot_with_warning(monkeypatch, tmp_path):
    monkeypatch.setattr(extra, "SNAPSHOTS", tmp_path)
    (tmp_path / "source.raw").write_text("a\none\ntwo\n")
    logs = []
    monkeypatch.setattr(sources, "http_get", lambda *args, **kwargs: b"a\none\n")
    rows = extra.load_optional("source", "https://example.invalid", sources.parse_payload,
                               lambda rows: extra._require(rows, "a"), log=logs.append)
    assert len(rows) == 2 and any("少於快照" in line for line in logs) and any("非即時" in line for line in logs)
    (tmp_path / "source.raw").write_text("broken")
    monkeypatch.setattr(sources, "http_get", lambda *args, **kwargs: b"<html>bad</html>")
    assert extra.load_optional("source", "https://example.invalid", sources.parse_payload,
                               lambda rows: extra._require(rows, "a"), log=logs.append) == []
    assert any("未套用" in line for line in logs)


def test_osm_failure_falls_back_per_region_and_keeps_real_empty_region(monkeypatch, tmp_path):
    monkeypatch.setattr(osm, "SNAPSHOTS", tmp_path)
    monkeypatch.setattr(osm, "REGIONS", {"one": (24, 121, 25, 122), "empty": (26, 119, 26.4, 120)})
    for region, elements in (("one", [node(1, highway="speed_camera")]), ("empty", [])):
        obj = {"osm3s": {"timestamp_osm_base": "2026-11-12T00:00:00Z"}, "elements": elements}
        (tmp_path / f"{region}.json.gz").write_bytes(gzip.compress(json.dumps(obj).encode()))

    def fail(*args, **kwargs):
        raise OSError("offline")

    monkeypatch.setattr(sources, "http_get", fail)
    logs = []
    assert len(osm.load_elements(log=logs.append)) == 1
    assert sum("使用 repo" in line for line in logs) == 2
    assert not any("未套用" in line for line in logs)


def test_osm_corrupt_deflate_snapshot_is_reported_without_breaking_build(monkeypatch, tmp_path):
    monkeypatch.setattr(osm, "SNAPSHOTS", tmp_path)
    monkeypatch.setattr(osm, "REGIONS", {"broken": (24, 121, 25, 122)})
    (tmp_path / "broken.json.gz").write_bytes(b"\x1f\x8b\x08\x00" + b"\x00" * 6 + b"\x07" + b"\x00" * 8)
    logs = []
    assert osm.load_elements(offline=True, log=logs.append) == []
    assert any("快照失效" in line for line in logs) and any("未套用" in line for line in logs)


def test_committed_snapshots_match_provenance_hashes_and_load_without_network(monkeypatch):
    manifest = json.loads((extra.SNAPSHOTS / "manifest.json").read_text(encoding="utf-8"))
    for source, info in manifest.items():
        assert hashlib.sha256((extra.SNAPSHOTS / f"{source}.raw").read_bytes()).hexdigest() == info["sha256"]
    manifest = json.loads((osm.SNAPSHOTS / "manifest.json").read_text(encoding="utf-8"))
    assert set(manifest) == set(osm.REGIONS)
    for region, info in manifest.items():
        assert hashlib.sha256((osm.SNAPSHOTS / f"{region}.json.gz").read_bytes()).hexdigest() == info["sha256"]

    def no_network(*args, **kwargs):
        pytest.fail("explicit offline build must not fetch supplemental sources")

    monkeypatch.setattr(sources, "http_get", no_network)
    report = SourceReport()
    cameras, attribution = extra.load_official(report, offline=True, log=lambda _: None)
    assert cameras and attribution and osm.load_elements(offline=True, log=lambda _: None)


def test_supplemental_build_produces_source_stats_and_preserves_legacy_ids(monkeypatch):
    rows = [{"Address": "測試路", "Latitude": "25", "Longitude": "121.5", "direct": "北", "limit": "50"}]
    baseline, _ = build_cameras.build(rows, [], log=lambda _: None)
    monkeypatch.setattr(extra, "load_official", lambda *args, **kwargs: ([cam("new", source="164507", kind="tech", lat=25.01, items="闖紅燈")], ["地方來源"]))
    monkeypatch.setattr(extra, "load_mobile", lambda *args, **kwargs: ([], []))
    monkeypatch.setattr(osm, "load_elements", lambda **kwargs: [node(5, lat=25.02, highway="speed_camera")])
    db, _ = build_cameras.build(rows, [], supplemental=True, log=lambda _: None)
    assert baseline["cameras"][0]["id"] in {c["id"] for c in db["cameras"]}
    assert db["sourceReport"]["sources"]["osm"]["added"] == 1
    assert "地方來源" in db["sources"] and any("ODbL" in source for source in db["sources"])
    assert len(db["cameras"]) == 3


def test_source_report_changes_are_persisted_even_without_point_changes(tmp_path):
    path = tmp_path / "cameras.json"
    saved = {"cameras": [], "sections": [], "sources": [], "sourceReport": {"issues": []}}
    path.write_text(json.dumps(saved), encoding="utf-8")
    updated = {**saved, "sourceReport": {"issues": ["新增來源改用快照"]}}
    assert not build_cameras.unchanged(str(path), updated)
    path.write_text(json.dumps(updated), encoding="utf-8")
    assert build_cameras.unchanged(str(path), {**updated, "generatedAt": "2026-11-13T00:00:00Z"})


@pytest.mark.parametrize("source_id,count", [
    ("176549", 266), ("176561", 98), ("135957", 93), ("25935", 118), ("178168", 145),
    ("172174", 89), ("172178", 19), ("178159", 72), ("178159-fixed", 77),
    ("119017", 75), ("178121", 12), ("176021", 2), ("146681", 36),
    ("176555", 29), ("176558", 12), ("176560", 78), ("176551", 7), ("177827", 7),
    ("170673", 8),
])
def test_stage_f_adapter_keeps_verified_rows_items_and_unique_original_keys(source_id, count):
    source = next(s for s in extra.OFFICIAL_SOURCES if s.id == source_id)
    rows = sources.parse_payload((extra.SNAPSHOTS / f"{source_id}.raw").read_bytes())
    report = SourceReport()
    cameras = source.adapter(rows, report)
    assert len(cameras) == len({c.id for c in cameras}) == count
    assert all(c.source == source_id and c.sourceID and c.enforcementItems for c in cameras)
    assert report.counts[source_id]["locationSuccess"] == count
    with pytest.raises(ValueError):
        source.adapter([{"changed_schema": "unexpected"}], SourceReport())
    if source_id == "119017":
        assert report.location_failures[source_id] == {"invalid_coordinate": 1}
    if source_id == "178159-fixed":
        assert source.dataset_id == "178159" and "178159-fixed" not in source.attribution


def test_kaohsiung_header_change_or_truncation_is_rejected_and_turns_are_not_guessed():
    rows = sources.parse_payload((extra.SNAPSHOTS / "176549.raw").read_bytes())
    with pytest.raises(ValueError):
        extra.adapt_176549(rows[:1], SourceReport())
    rows = sources.parse_payload((extra.SNAPSHOTS / "176561.raw").read_bytes())
    report = SourceReport()
    turning = [r for r in rows if r["測照行向"] == "南向西"]
    cameras = extra.adapt_176561(turning, report)
    assert cameras and all(c.heading is None and "南向西" in c.conditions for c in cameras)
    assert all(c.speedLimit is None for c in cameras) and any("轉向行向" in issue for issue in report.issues)


def test_taipei_parking_is_retained_and_known_tunnel_sections_are_not_made_into_new_points():
    rows = sources.parse_payload((extra.SNAPSHOTS / "135957.raw").read_bytes())
    report = SourceReport()
    cameras = extra.adapt_135957(rows, report)
    assert len([c for c in cameras if c.enforcementItems == "違規停車"]) == 16
    assert all(not c.enforces_speed for c in cameras if c.enforcementItems == "違規停車")
    assert not any(c.address in ("辛亥隧道", "自強隧道") for c in cameras)
    assert report.counts["135957"]["excluded"] == 2
    assert any("行政區" in issue for issue in report.issues)


def test_kinmen_known_reversed_coordinates_are_source_specific_not_a_global_guess():
    rows = sources.parse_payload((extra.SNAPSHOTS / "178121.raw").read_bytes())
    report = SourceReport()
    cameras = extra.adapt_178121(rows, report)
    assert all(24.3 < c.lat < 24.6 and 118.1 < c.lon < 118.5 for c in cameras)
    assert all(c.type == "tech" and not c.enforces_speed for c in cameras)
    assert sum("反置" in message for message in report.issues) == 12


@pytest.mark.parametrize("source_id,missing", [("176555", 2), ("176551", 4)])
def test_kaohsiung_empty_function_cells_are_not_filled_from_a_previous_row_or_title(source_id, missing):
    source = next(s for s in extra.OFFICIAL_SOURCES if s.id == source_id)
    rows = sources.parse_payload((extra.SNAPSHOTS / f"{source_id}.raw").read_bytes())
    report = SourceReport()
    cameras = source.adapter(rows, report)
    assert report.location_failures[source_id] == {"missing_field": missing}
    assert all(c.type == "tech" and c.speedLimit is None and not c.enforces_speed for c in cameras)


@pytest.mark.parametrize("source_id", ["176555", "176560", "176551", "177827"])
def test_kaohsiung_column_table_must_keep_verified_header_semantics(source_id):
    source = next(s for s in extra.OFFICIAL_SOURCES if s.id == source_id)
    rows = sources.parse_payload((extra.SNAPSHOTS / f"{source_id}.raw").read_bytes())
    rows[0]["Column5"] = "不明座標"
    with pytest.raises(ValueError):
        source.adapter(rows, SourceReport())


def test_kaohsiung_leased_fixed_technology_side_is_not_a_mobile_type_or_vehicle_heading():
    rows = sources.parse_payload((extra.SNAPSHOTS / "177827.raw").read_bytes())
    cameras = extra.adapt_177827(rows, SourceReport())
    assert len(cameras) == 7
    assert all(c.type == "tech" and c.heading is None and c.axis is None and c.speedLimit is None for c in cameras)
    assert all("側" in c.conditions and c.enforcementItems == "車不停讓行人" for c in cameras)


def test_taichung_corrupt_function_cells_and_single_point_sections_are_isolated():
    rows = sources.parse_payload((extra.SNAPSHOTS / "170673.raw").read_bytes())
    report = SourceReport()
    cameras = extra.adapt_170673(rows, report)
    assert {c.sourceID for c in cameras} == {"4", "5", "74", "75", "76", "77", "78", "79"}
    assert report.location_failures["170673"] == {"invalid_enforcement_item": 68}
    assert report.counts["170673"]["excluded"] == 3
    assert all(24 < c.lat < 24.5 and 120.4 < c.lon < 121.5 for c in cameras)
    assert all(c.speedLimit is None and not c.enforces_speed for c in cameras)
    assert next(c for c in cameras if c.sourceID == "74").heading == 90
    assert next(c for c in cameras if c.sourceID == "77").heading == 270
    assert next(c for c in cameras if c.sourceID == "79").heading is None


def test_taipei_sound_pdf_keeps_all_official_addresses_and_rejects_an_unverified_new_version():
    raw = (extra.SNAPSHOTS / "tp-noise.raw").read_bytes()
    rows = extra.parse_tp_noise(raw)
    assert len(rows) == 28 and "至善路2段431號" in rows[1]["address"]
    with pytest.raises(ValueError, match="版本變更"):
        extra.parse_tp_noise(raw + b"changed")


def test_douliu_paragraphs_preserve_twenty_six_rows_ranges_and_conditional_limits():
    rows = extra.parse_douliu_mobile((extra.SNAPSHOTS / "douliu-mobile.raw").read_bytes())
    assert len(rows) == 26 and "快車道速限60" in rows[5]["address"] and "慢車道速限40" in rows[5]["address"]
    assert rows[-1]["district"] == ""
    assert extra._douliu_mileage(rows[16]["address"]) == ("台1", 234.5)
    assert extra._douliu_mileage(rows[-1]["address"]) == ("台3", 240)
    assert extra._douliu_mileage(rows[6]["address"]) is None
    assert extra._douliu_mileage(rows[0]["address"]) is None
    with pytest.raises(ValueError):
        extra.parse_douliu_mobile("<p>（一）斗六市測試路100號</p><p>（三）斗六市測試路200號</p>".encode())


def test_sound_location_uses_same_verified_geocoder_and_retains_noise_only_rules():
    from speedcam_data.geocoding_sources import load_geocoder
    raw = sources.parse_payload((extra.SNAPSHOTS / "173697.raw").read_bytes())
    tp = extra.parse_tp_noise((extra.SNAPSHOTS / "tp-noise.raw").read_bytes())
    requests = [dict(city="彰化縣", district=extra.re.match(r".+?[市鄉鎮]", r["測點地址"])[0], address=r["測點地址"])
                for r in raw]
    requests += [dict(city="臺北市", district=r["district"], address=r["address"]) for r in tp]
    geocoder = load_geocoder(requests, offline=True, log=lambda _: None)
    report = SourceReport()
    ch_cameras = extra.adapt_173697(raw, report, geocoder)
    tp_cameras = extra.adapt_tp_noise(tp, report, geocoder)
    assert len(ch_cameras) == 4 and len(tp_cameras) == 10
    assert all(c.type == "noise" and not c.enforces_speed and c.speedLimit is None
               and c.positionMethod == "door" and c.axis is not None and "定位依據" in c.conditions
               for c in ch_cameras + tp_cameras)
    assert report.counts["173697"]["locationFailed"] == 5
    assert report.counts["tp-noise"]["locationFailed"] == 18


def test_corrupt_schema_snapshot_and_failed_download_skip_only_that_optional_source(monkeypatch, tmp_path):
    monkeypatch.setattr(extra, "SNAPSHOTS", tmp_path)
    (tmp_path / "176549.raw").write_text("wrong\nvalue\n", encoding="utf-8")

    def unavailable(*args, **kwargs):
        raise OSError("服務逾時")

    monkeypatch.setattr(sources, "http_get", unavailable)
    logs = []
    assert extra.load_optional("176549", "https://example.invalid", sources.parse_payload,
                               lambda rows: extra.adapt_176549(rows, SourceReport()), log=logs.append) == []
    assert any("快照無法使用" in message for message in logs) and any("未套用" in message for message in logs)


def test_douliu_only_single_provincial_mileage_uses_index_and_never_road_or_county_mile_centers():
    rows = extra.parse_douliu_mobile((extra.SNAPSHOTS / "douliu-mobile.raw").read_bytes())
    report = SourceReport()
    cameras = extra.adapt_mobile(rows, "douliu-mobile", report,
                                 resolve=lambda road, km: (23.7 + km / 10000, 120.5))
    assert len(cameras) == 5 and all(c.positionMethod == "milestone" and c.speedLimit is None for c in cameras)
    assert cameras[-1].heading == 180
    assert not any("154縣道" in c.address or "145乙線" in c.address or "新榮橋" in c.address for c in cameras)
    assert report.counts["douliu-mobile"]["locationSuccess"] == 5


def test_existing_official_point_does_not_bypass_new_same_district_unique_osm_junction_rule():
    from speedcam_data.geocoding import Geocoder, RoadIndex
    rows = [dict(district="新店區", address="中正路與中央路口")]
    official = cam("known", address=rows[0]["address"])
    report = SourceReport()
    assert extra.adapt_mobile(rows, "ntpc-mobile", report, junctions=[official],
                              geocoder=Geocoder([], RoadIndex([]))) == []
    assert report.location_failures["ntpc-mobile"] == {"road_data_missing": 1}
