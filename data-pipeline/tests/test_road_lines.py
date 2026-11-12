import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from speedcam_data import road_lines  # noqa: E402


def way(highway, ref=None, name=None, points=((25.0, 121.0), (25.01, 121.0))):
    tags = {"highway": highway}
    if ref is not None:
        tags["ref"] = ref
    if name is not None:
        tags["name"] = name
    return {"type": "way", "tags": tags, "geometry": [{"lat": a, "lon": b} for a, b in points]}


def build(elements, restricted=frozenset()):
    return road_lines.build_road_lines(elements, set(restricted), "2026-11-06", log=lambda *_: None)


def test_freeway_needs_motorway_and_known_ref():
    assert road_lines.is_freeway({"highway": "motorway", "ref": "1"})
    assert road_lines.is_freeway({"highway": "motorway", "ref": "3甲"})
    # 省道的 ref 也是數字，要靠 highway 分開
    assert not road_lines.is_freeway({"highway": "trunk", "ref": "1"})
    # 高雄港聯外高架是 motorway，但不是國道
    assert not road_lines.is_freeway({"highway": "motorway", "name": "高雄港聯外高架道路"})
    assert not road_lines.is_freeway({"highway": "motorway", "ref": "66"})


def test_build_separates_freeways_and_restricted_roads():
    data = build(
        [
            way("motorway", ref="1", name="中山高速公路"),
            way("trunk", name="新生高架道路", points=((25.05, 121.5), (25.06, 121.5))),
            way("trunk", ref="64", name="東西向快速公路 八里新店線", points=((25.1, 121.4), (25.1, 121.45))),
        ],
        restricted={"新生高架道路"},
    )
    assert data["freeways"] == [[[25.0, 121.0], [25.01, 121.0]]]
    assert data["whitePlateRestricted"] == [[[25.05, 121.5], [25.06, 121.5]]]
    assert data["attribution"] == road_lines.ATTRIBUTION


def test_sections_open_to_motorcycles_are_not_restricted():
    data = build(
        [
            way("trunk", name="新北環河快速道路", points=((25.0, 121.5), (25.01, 121.5))),
            dict(way("trunk", name="新北環河快速道路", points=((25.1, 121.5), (25.11, 121.5))),
                 tags={"highway": "trunk", "name": "新北環河快速道路", "motorcycle": "yes"}),
        ],
        restricted={"新北環河快速道路"},
    )
    assert data["whitePlateRestricted"] == [[[25.0, 121.5], [25.01, 121.5]]]


def test_overpass_query_includes_the_only_restricted_primary_road():
    assert "安朔高架橋" in road_lines.OVERPASS_QUERY
    assert "motorway|trunk" in road_lines.OVERPASS_QUERY


def test_missing_restricted_road_is_reported():
    messages = []
    road_lines.build_road_lines([way("trunk", name="別的路")], {"新生高架道路"}, "2026-11-06", log=messages.append)
    assert any("新生高架道路" in m for m in messages)


def test_merge_joins_connected_ways_in_order():
    a = [(25.0, 121.0), (25.1, 121.0)]
    b = [(25.1, 121.0), (25.2, 121.0)]
    c = [(25.2, 121.0), (25.3, 121.0)]
    separate = [(24.0, 120.0), (24.1, 120.0)]
    merged = road_lines.merge_lines([c, a, separate, b])
    assert [(25.0, 121.0), (25.1, 121.0), (25.2, 121.0), (25.3, 121.0)] in merged
    assert separate in merged
    assert len(merged) == 2


def test_merge_keeps_loops_and_drops_single_points():
    loop_a = [(25.0, 121.0), (25.1, 121.0)]
    loop_b = [(25.1, 121.0), (25.0, 121.0)]
    merged = road_lines.merge_lines([loop_a, loop_b, [(24.0, 120.0)]])
    assert len(merged) == 1
    assert merged[0][0] == merged[0][-1]


def test_simplify_removes_points_on_straight_road():
    straight = tuple((25.0 + i * 0.001, 121.0) for i in range(11))
    data = build([way("motorway", ref="3", points=straight)])
    assert data["freeways"] == [[[25.0, 121.0], [25.01, 121.0]]]


def test_restricted_names_ignore_comments():
    text = "# 說明\nname,note\n新生高架道路,Apple 不算 highway\n\n洲美快速道路,\n"
    assert road_lines.parse_restricted_names(text) == {"新生高架道路", "洲美快速道路"}


def test_dumps_is_valid_json_with_one_line_per_road():
    data = build([way("motorway", ref="1"), way("motorway", ref="3", points=((24.0, 120.0), (24.1, 120.0)))])
    text = road_lines.dumps(data)
    assert json.loads(text) == data
    assert len(text.splitlines()) == 10
    empty = dict(data, freeways=[])
    assert json.loads(road_lines.dumps(empty))["freeways"] == []


def test_line_length():
    assert abs(road_lines.line_length_km([(25.0, 121.0), (25.01, 121.0)]) - 1.1095) < 0.001


def test_named_mainlines_keep_freeway_identity_and_ignore_surface_roads_and_ramps():
    data = build([way("motorway", ref="1", name="中山高速公路"),
                  way("trunk", name="水源快速道路"), way("trunk_link", name="水源入口匝道"),
                  way("primary", name="水源路")])
    roads = {r["name"]: r for r in data["namedRoads"]}
    assert set(roads) == {"國道1號", "水源快速道路"}
    assert roads["國道1號"]["freewayRef"] == "1"
    assert "freewayRef" not in roads["水源快速道路"]
    assert roads["水源快速道路"]["lines"] == [[[25.0, 121.0], [25.01, 121.0]]]
