import copy
import importlib.util
import json
import math
from pathlib import Path

import pytest

CHECKER = Path(__file__).resolve().parents[2] / "scripts" / "ci" / "check-replay-1108.py"
spec = importlib.util.spec_from_file_location("check_replay_1108", CHECKER)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def shift(point, heading, meters):
    radians = math.radians(heading)
    return [point[0] + math.cos(radians) * meters / 111195,
            point[1] + math.sin(radians) * meters / (111195 * math.cos(math.radians(point[0])))]


def extended(points, before=700, after=700):
    return [shift(points[0], checker.bearing(*points[:2]) + 180, before),
            *map(list, points), shift(points[-1], checker.bearing(*points[-2:]), after)]


def hint_path(prefix, wrong_branch=False):
    points, seen = [], set()
    for key in checker.HINT_CASES[prefix]:
        hint_id = checker.HINT_POINTS[key][1]
        if hint_id in seen:
            continue
        seen.add(hint_id)
        entry, confirmation, heading, _ = checker.HINT_BRANCHES[hint_id]
        if wrong_branch:
            confirmation = shift(entry, heading + 90, 500)
        points += [shift(entry, heading + 180, 700), list(entry), list(confirmation),
                   shift(confirmation, checker.bearing(entry, confirmation), 350)]
    return points


def case_path(prefix):
    if prefix in checker.HINT_CASES:
        return hint_path(prefix)
    if prefix in ("去程02", "補測05"):
        return [shift(checker.SHUIYUAN_ENTRY, 70, 650), list(checker.SHUIYUAN_ENTRY),
                list(checker.SHUIYUAN_CONFIRMATION), shift(checker.SHUIYUAN_CONFIRMATION, 150, 500)]
    if prefix in ("去程01", "補測09"):
        return [shift(checker.CITY_CAMERA, 0, 500), list(checker.CITY_CAMERA), shift(checker.CITY_CAMERA, 180, 500)]
    if prefix in ("語音01", "補測08"):
        before = 80 if prefix == "語音01" else 300
        return [shift(checker.NEAR_CAMERA, 270, before), list(checker.NEAR_CAMERA), shift(checker.NEAR_CAMERA, 90, 700)]
    sid = checker.SECTION_CASES.get(prefix, "beiyi-1-f")
    points = extended(checker.SECTION_POINTS[sid])
    if prefix == "去程04":
        points += case_path("補測08")
    return points


def apple_steps(points, *, highway=False):
    geometry = checker.RouteGeometry(points)
    if not highway:
        return [dict(index=0, start=0, end=geometry.length, text="Apple 原文", corrected="Apple 原文", shortText="Apple 原文")]
    end = geometry.nearest(checker.SHUIYUAN_ENTRY)[0]
    return [
        dict(index=0, start=0, end=0, text="", corrected="", shortText=""),
        dict(index=1, start=0, end=end, text="左轉上高速公路，朝(永和)、景美前進",
             corrected="左轉上水源快速道路，朝(永和)、景美前進", shortText="左轉 上水源快速道路"),
        dict(index=2, start=end, end=geometry.length, text="抵達目的地", corrected="抵達目的地", shortText="抵達目的地"),
    ]


@pytest.fixture
def records():
    """人工紀錄只測檢查器，不是本輪 MapKit replay 的驗收證據。"""
    out = []

    def add(case, event, second, **fields):
        out.append(dict(schema=1, case=case, event=event, t=second, lat=25, lon=121) | fields)

    def section(case, sid, completed=True):
        add(case, "section_approach", 10, id=sid)
        add(case, "section_entered", 20, id=sid)
        if completed:
            add(case, "section_completed", 100, id=sid)

    add("", "run_start", 0)
    cases = {case["name"].split(" ", 1)[0]: case
             for case in json.loads(CHECKER.with_name("route-replay-1108.json").read_text(encoding="utf-8"))}
    for prefix in checker.REQUIRED_CASES:
        case = prefix + " 檢查器單元測試"
        points = case_path(prefix)
        geometry = checker.RouteGeometry(points)
        add(case, "case_start", 0, lat=points[0][0], lon=points[0][1],
            **{key: cases[prefix].get(key, 0) for key in (
                "turnaroundAtMeters", "waitAtTurnaroundSeconds", "pauseAtMeters", "pauseSeconds")})
        start = out[-1]
        add(case, "route_geometry", 0, pointCount=len(points), chunkCount=1,
            appleSteps=apple_steps(points, highway=prefix in ("去程02", "補測05")))
        add(case, "route_geometry_part", 0, index=0, points=points)
        if prefix in ("去程01", "補測09"):
            add(case, "camera_pre", 10, id="fdb06e9709c2")
            add(case, "camera_passed", 30, id="fdb06e9709c2")
        elif prefix in ("去程02", "補測05"):
            along = geometry.nearest(checker.SHUIYUAN_ENTRY)[0]
            add(case, "nav_display", 10, text="左轉 上水源快速道路", instruction="左轉上水源快速道路，朝(永和)、景美前進",
                stepIndex=1, along=along - 300, maneuverAlong=along)
            add(case, "nav_speech", 20, text="300公尺後，左轉上水源快速道路，朝(永和)、景美前進", stepIndex=1, along=along - 300)
        elif prefix in ("去程04", "回程02", "補測06", "補測07"):
            section(case, checker.SECTION_CASES[prefix])
            if prefix == "去程04":
                add(case, "camera_pre", 110, id="3de5c6fd4567")
                add(case, "camera_near", 130, id="3de5c6fd4567", afterPre=True, overspeed=True,
                    announcedDistance=100, speeches=["100公尺，超速"])
        elif prefix == "補測08":
            add(case, "camera_pre", 10, id="3de5c6fd4567")
            add(case, "camera_near", 20, id="3de5c6fd4567", afterPre=True, overspeed=True,
                announcedDistance=100, speeches=["100公尺，超速"])
        elif prefix in ("北宜2去程", "北宜2回程"):
            sid = "beiyi-2-f" if prefix == "北宜2去程" else "beiyi-2-r"
            a, b, length = checker.GATES[sid]
            add(case, "section_entered", 20, id=sid, lat=a[0], lon=a[1], gateLat=a[0], gateLon=a[1], length=length)
            add(case, "section_overspeed_started", 20, id=sid)
            for second in (20, 35, 50):
                add(case, "section_beep", second, id=sid)
            add(case, "section_status", 50, id=sid, remaining=350, sectionOverspeed=True,
                cameraOverspeed=False, presentationOverspeed=True)
            add(case, "section_completed", 400, id=sid, lat=b[0], lon=b[1], gateLat=b[0], gateLon=b[1])
        elif prefix in checker.BEIYI_CASES:
            section(case, checker.BEIYI_CASES[prefix])
        elif prefix in ("折返01", "折返02", "歸零01"):
            sid = "beiyi-1-f"
            section(case, sid, completed=False)
            add(case, "section_overspeed_started", 25, id=sid)
            add(case, "section_beep", 25, id=sid)
            if prefix != "折返01":
                add(case, "section_overspeed_ended", 317, id=sid)
                add(case, "section_zero", 317, id=sid)
                add(case, "section_status", 330, id=sid, remaining=0, sectionOverspeed=False,
                    cameraOverspeed=True, presentationOverspeed=True)
            add(case, "section_completed" if prefix == "歸零01" else "section_aborted", 450, id=sid)
        elif prefix == "語音01":
            add(case, "camera_near", 0, id="3de5c6fd4567", afterPre=False, overspeed=True,
                announcedDistance=100, speeches=["前方100公尺，測速照相，速限50", "您已超速，速限50"])
        elif prefix in checker.HINT_CASES:
            ids = checker.HINT_CASES[prefix]
            start["hintCheckIDs"] = ids
            if prefix in checker.CONTINUOUS_HINT_CASES:
                address = dict(Name="長春路128號", Query=checker.ADDRESS_QUERY, Lat=25.05478, Lon=121.531)
                store = dict(Name="7-ELEVEN 坪林門市", Query=checker.STORE_QUERY, Lat=24.935, Lon=121.711)
                for side, place in zip(("from", "to"), (address, store) if prefix == "補測01" else (store, address)):
                    start.update({side + key: value for key, value in place.items()})
            spoken = {}
            for index, key in enumerate(ids):
                _, hint_id, short, instruction = checker.HINT_POINTS[key]
                if hint_id in spoken:
                    continue
                along = geometry.nearest(checker.HINT_BRANCHES[hint_id][0])[0]
                add(case, "nav_display", 10 + index * 30, text=short, hintID=hint_id, along=along - 500)
                add(case, "nav_hint", 20 + index * 30, text=short, hintID=hint_id, along=along - 200, distance=200)
                add(case, "nav_speech", 25 + index * 30, text=instruction, hintID=hint_id, along=along - 100, announcement=-1)
                spoken[hint_id] = out[-1]
            for key in ids:
                point, hint_id, short, instruction = checker.HINT_POINTS[key]
                speech = spoken[hint_id]
                along, lateral = geometry.nearest(point)
                add(case, "hint_check", 490, id=key, lat=point[0], lon=point[1], hintID=hint_id,
                    along=along, routeDistance=lateral, coverage="covered", matched=True, triggered=True,
                    shortText=short, instruction=instruction, displayAtPoint=short, displayedHint=short, liveActivityHint=short,
                    appleSteps=[dict(start=0, end=10_000, text="Apple 原文")],
                    speeches=[dict(t=speech["t"], text=instruction, source="navigation", hintID=hint_id)])
        add(case, "case_end", 500, sectionStillActive=False)
    add("", "run_end", 0, failed=0, succeeded=len(checker.REQUIRED_CASES), correctManeuvers=1, totalManeuvers=1)
    return out


def row(records, prefix, event, index=0):
    return [r for r in records if r["case"].startswith(prefix + " ") and r["event"] == event][index]


def replace_route(records, prefix, points):
    row(records, prefix, "route_geometry").update(pointCount=len(points), chunkCount=1, appleSteps=apple_steps(points))
    row(records, prefix, "route_geometry_part").update(points=points)


@pytest.mark.parametrize("prefix,ids", checker.FIXED_HINT_CASES.items())
def test_fixed_hint_replays_start_before_announcement_window(prefix, ids):
    cases = json.loads(CHECKER.with_name("route-replay-1108.json").read_text(encoding="utf-8"))
    assert sorted(case["name"].split(" ", 1)[0] for case in cases) == sorted(checker.REQUIRED_CASES)
    case = next(case for case in cases if case["name"].startswith(prefix + " "))
    assert not case["from"].get("query") and not case["to"].get("query")
    assert sorted(hint["id"] for hint in case["hintChecks"]) == sorted(ids)
    for key in ids:
        point, hint_id, _, _ = checker.HINT_POINTS[key]
        assert checker.distance((case["from"]["lat"], case["from"]["lon"]), point) >= 500
        hint = next(hint for hint in case["hintChecks"] if hint["id"] == key)
        assert hint["hintID"] == hint_id
        assert checker.distance((hint["lat"], hint["lon"]), point) <= 1


def test_complete_synthetic_log_is_accepted_by_checker_only(records, tmp_path, capsys):
    text = "\n".join("2026-11-12T00:00:00Z job " + checker.MARKER + json.dumps(r, ensure_ascii=False) for r in records)
    assert checker.check_text(text) == []
    path = tmp_path / "synthetic-checker-test.log"
    path.write_text(text, encoding="utf-8")
    assert checker.main([str(path)]) == 0
    assert "不代表實機播放" in capsys.readouterr().out


@pytest.mark.parametrize("prefix,event,changes,reason", [
    ("去程01", "case_start", {"event": "camera_near", "address": "國道一號南向279公里"}, "錯位"),
    ("去程04", "section_entered", {"event": "camera_near", "id": "685b30491485"}, "IKEA"),
    ("回程02", "section_completed", {"t": 5}, "順序"),
    ("北宜2去程", "section_entered", {"lat": 24.9511}, "60 m"),
    ("北宜2回程", "section_completed", {"gateLat": 24.9509}, "方向別官方"),
    ("北宜2去程", "section_entered", {"length": 6000}, "公告長度"),
    ("北宜2回程", "section_beep", {"t": 30}, "小於 15 秒"),
    ("折返01", "section_aborted", {"event": "section_completed"}, "中途離開"),
    ("折返02", "case_end", {"sectionStillActive": True}, "仍在追蹤"),
    ("折返02", "section_status", {"event": "section_beep"}, "歸零後"),
    ("歸零01", "section_status", {"sectionOverspeed": True}, "歸零後區間畫面"),
    ("歸零01", "section_status", {"presentationOverspeed": False}, "Live Activity"),
    ("歸零01", "section_completed", {"event": "section_aborted"}, "掩蓋"),
    ("北宜4回程", "section_completed", {"event": "section_aborted"}, "中途離開"),
    ("北宜3去程", "section_entered", {"event": "section_approach"}, "沒有對應進入"),
    ("回程03", "case_end", {"sectionStillActive": True}, "仍在追蹤"),
    ("語音01", "camera_near", {"speeches": ["100公尺，超速"]}, "首次近距"),
    ("去程04", "camera_near", {"speeches": ["100公尺"]}, "持續超速"),
    ("去程04", "camera_near", {"speeches": ["100公尺，超速", "您已超速，速限50"]}, "近距語句"),
    ("去程02", "nav_display", {"text": "左轉 上高速公路"}, "畫面沒有"),
    ("去程02", "nav_speech", {"text": "左轉上高速公路，朝(永和)、景美前進"}, "語音沒有"),
])
def test_each_acceptance_failure_is_rejected(records, prefix, event, changes, reason):
    target = row(records, prefix, event, index=1 if prefix == "北宜2回程" and event == "section_beep" else 0)
    target.update(changes)
    assert any(reason in error for error in checker.check_records(records))


@pytest.mark.parametrize("kind", ["mobile", "noise", "tech"])
def test_new_non_speed_reminder_at_ikea_is_not_mistaken_for_section_fixed_camera(records, kind):
    reminder = dict(schema=1, case="去程04 檢查器單元測試", event="camera_pre", t=50, lat=25, lon=121,
                    id="new-reminder", address="中央路白馬寺路口", cameraType=kind, enforcesSpeed=False)
    before = "section_completed"
    if kind == "mobile":
        reminder.update(t=15, traveled=100, speeches=["前方300公尺，常見移動測速"])
        before = "section_entered"
    records.insert(records.index(row(records, "去程04", before)), reminder)
    assert checker.check_records(records) == []
    reminder["id"] = "685b30491485"
    assert any("IKEA" in error for error in checker.check_records(records))


def add_hotspot(records, prefix, second, traveled=100, **fields):
    reminder = dict(schema=1, case=row(records, prefix, "case_start")["case"], event="camera_pre",
                    t=second, lat=25, lon=121, id=f"mobile-{second}", address="臺9線18K雙向",
                    cameraType="mobile", enforcesSpeed=False, traveled=traveled,
                    speeches=["前方300公尺，常見移動測速"]) | fields
    end = records.index(row(records, prefix, "case_end"))
    position = next((i for i in range(end) if records[i]["case"] == reminder["case"]
                     and records[i]["t"] > second), end)
    records.insert(position, reminder)
    return reminder


@pytest.mark.parametrize("prefix,second", [("去程04", 20), ("去程04", 50), ("北宜2回程", 50),
                                          ("補測01", 100), ("補測02", 100)])
def test_hotspot_pre_is_rejected_during_every_case_countdown_including_same_batch_entry(records, prefix, second):
    if prefix.startswith("補測"):
        start = row(records, prefix, "case_start")
        entry = dict(start, event="section_entered", t=second, id="temporary-section")
        at = records.index(next(r for r in records if r["case"] == start["case"] and r["t"] >= second))
        records.insert(at, entry)
        end = row(records, prefix, "case_end")
        records.insert(records.index(end), dict(entry, event="section_completed", t=499))
    add_hotspot(records, prefix, second, sectionActive=False)
    assert any("區間倒數中出現熱點預告" in error for error in checker.check_records(records))


def test_hotspot_is_allowed_before_entry_and_at_completion_but_noise_and_tech_remain_independent(records):
    add_hotspot(records, "去程04", 15, traveled=100)
    add_hotspot(records, "去程04", 100, traveled=1100)
    assert checker.check_records(records) == []


@pytest.mark.parametrize("traveled", [1099.99, 99, -1, float("nan"), None, True])
def test_hotspot_spacing_rejects_under_one_km_reversals_and_invalid_odometer(records, traveled):
    add_hotspot(records, "補測01", 200, traveled=100)
    add_hotspot(records, "補測01", 300, traveled=traveled)
    assert any("行駛距離" in error for error in checker.check_records(records))


def test_hotspot_spacing_is_traveled_distance_not_elapsed_time_or_straight_line(records):
    first = add_hotspot(records, "補測02", 200, traveled=100)
    second = add_hotspot(records, "補測02", 400, traveled=1100)
    assert (first["lat"], first["lon"]) == (second["lat"], second["lon"])
    assert checker.check_records(records) == []
    second["traveled"] = 1090
    assert any("小於 1 km" in error for error in checker.check_records(records))


@pytest.mark.parametrize("prefix,address", [
    ("去程01", "臺9線22.5K(往新店)"), ("北宜1去程", "臺9線22.5K（往新店方向）"),
    ("補測01", "臺9線18.4K（往 新店）"), ("回程01", "臺9線18.4K(往宜蘭)"),
    ("北宜2回程", "臺9線27.6K(往坪林)"), ("補測02", "臺9線25.2K(往坪林方向)"),
    ("折返01", "臺9線18.4K(往新店)"), ("折返02", "臺9線18.4K(往新店)"),
])
def test_hotspot_wrong_direction_is_rejected_from_road_evidence_on_long_and_short_cases(records, prefix, address):
    a, _, _, _, course = checker.RouteGeometry(case_path(prefix)).segments[0]
    point = shift(a, course, 50)
    add_hotspot(records, prefix, 5, traveled=50, address=address, source="ntpc-mobile",
                lat=point[0], lon=point[1])
    directions = {("ntpc-mobile", checker.normalized_address(address)): ((course + 180) % 360, None)}
    assert any("反向" in error for error in checker.check_records(records, hotspot_directions=directions))


@pytest.mark.parametrize("prefix,address", [
    ("去程01", "臺9線22.5K(往新店)"), ("補測01", "臺9線18.4K（往 新店）"),
    ("回程01", "臺9線14.5K(往坪林)"), ("補測02", "臺9線25.2K(往宜蘭方向)"),
])
def test_same_direction_hotspot_is_not_rejected_by_case_name(records, prefix, address):
    a, _, _, _, course = checker.RouteGeometry(case_path(prefix)).segments[0]
    point = shift(a, course, 50)
    add_hotspot(records, prefix, 5, traveled=50, address=address, source="ntpc-mobile",
                lat=point[0], lon=point[1])
    directions = {("ntpc-mobile", checker.normalized_address(address)): (course, None)}
    assert checker.check_records(records, hotspot_directions=directions) == []


@pytest.mark.parametrize("course,heading,accepted", [(0, 45, True), (0, 45.01, False),
                                                   (350, 10, True), (350, 170, False)])
def test_hotspot_direction_uses_45_degree_limit_and_wraps_north(records, course, heading, accepted):
    points = [[25, 121], shift([25, 121], course, 400)]
    replace_route(records, "回程01", points)
    point = shift(points[0], course, 100)
    target = add_hotspot(records, "回程01", 5, address="臺9線14.5K(往坪林)", source="ntpc-mobile",
                         lat=point[0], lon=point[1])
    directions = {("ntpc-mobile", checker.normalized_address(target["address"])): (heading, None)}
    errors = checker.check_records(records, hotspot_directions=directions)
    assert (errors == []) is accepted
    if not accepted:
        assert any("反向" in error and "超過 45°" in error for error in errors)


@pytest.mark.parametrize("course,accepted", [(87.3, True), (267.3, True), (177.3, False)])
def test_unresolved_destination_uses_only_known_road_axis(records, course, accepted):
    points = [[25, 121], shift([25, 121], course, 400)]
    replace_route(records, "回程01", points)
    point = shift(points[0], course, 100)
    target = add_hotspot(records, "回程01", 5, address="新店區臺9線18.4K(往新店)", source="ntpc-mobile",
                         lat=point[0], lon=point[1])
    directions = {("ntpc-mobile", checker.normalized_address(target["address"])): (None, 87.3)}
    information = []
    errors = checker.check_records(records, information=information, hotspot_directions=directions)
    assert (errors == []) is accepted
    assert any("只有道路雙向軸" in message and "不據地名推測單向" in message for message in information)
    if not accepted:
        assert any("反向／橫向" in error for error in errors)


@pytest.fixture
def e_return_hotspot_log(records):
    """保存 e 版的實際事件與局部原始折線，不冒充整份真實回放。"""
    points = [
        [24.953162700000007, 121.56736050000002], [24.95340530000001, 121.56749669999998],
        [24.953579799999986, 121.56759490000003], [24.95375609999999, 121.56772200000003],
        [24.953789499999996, 121.56775050000003], [24.9539379, 121.56790200000002],
        [24.9542002, 121.56824230000004], [24.95425039999999, 121.56830060000003],
        [24.954301400000002, 121.56835030000002], [24.954582299999995, 121.56856949999997],
        [24.95467839999999, 121.56864359999994], [24.95488319999999, 121.56881290000004],
        [24.955057399999987, 121.5690215], [24.955150399999987, 121.5691653],
        [24.955331900000004, 121.56950059999996],
    ]
    replace_route(records, "回程01", points)
    target = add_hotspot(
        records, "回程01", 201, traveled=3349.9999999999918,
        id="ntpc-mobile-fecd4a6863d0", address="新店區臺9線14.5K(往坪林)",
        source="ntpc-mobile", lat=24.953336260536748, lon=121.56745794000454,
        distance=288.20922324529187, announcedDistance=300, threshold=300,
        estimated=False, sectionActive=False, overspeed=False)
    passed = dict(target, event="camera_passed", t=218, traveled=3633.3333333333226,
                  lat=24.955221745616662, lon=121.56929710267364)
    records.insert(records.index(target) + 1, passed)
    report = ("[熱點行向] ntpc-mobile｜新店區 新店區臺9線14.5K(往坪林)｜directional"
              "｜heading=63.3 axis=None｜同路官方行政區「坪林」里程 31.7–55.5K，取里程增加方向")
    return report + "\n" + "\n".join(checker.MARKER + json.dumps(r, ensure_ascii=False) for r in records)


def test_actual_e_return_event_is_accepted_using_legacy_report_and_geometry(e_return_hotspot_log):
    assert checker.check_text(e_return_hotspot_log) == []
    reversed_heading = e_return_hotspot_log.replace("heading=63.3", "heading=243.3")
    assert any("反向" in error for error in checker.check_text(reversed_heading))


@pytest.mark.parametrize("change,reason", [
    ("missing", "缺少熱點地址對應"),
    ("malformed", "熱點行向數值無效"),
    ("conflicting", "有衝突的熱點行向"),
])
def test_missing_malformed_or_conflicting_hotspot_evidence_cannot_pass(e_return_hotspot_log, change, reason):
    report, records = e_return_hotspot_log.split("\n", 1)
    if change == "missing":
        text = records
    elif change == "malformed":
        text = e_return_hotspot_log.replace("heading=63.3", "heading=bad")
    else:
        text = report.replace("heading=63.3", "heading=243.3") + "\n" + e_return_hotspot_log
    assert any(reason in error for error in checker.check_text(text))


def test_returning_hotspot_course_is_reversed_from_trip_metadata_not_case_name(records):
    prefix, address = "折返01", "臺9線18.4K(往新店)"
    a, _, _, _, course = checker.RouteGeometry(case_path(prefix)).segments[0]
    point = shift(a, course, 50)
    turn = row(records, prefix, "case_start")["turnaroundAtMeters"]
    add_hotspot(records, prefix, 480, traveled=2 * turn - 50, address=address, source="ntpc-mobile",
                lat=point[0], lon=point[1])
    key = ("ntpc-mobile", checker.normalized_address(address))
    assert checker.check_records(records, hotspot_directions={key: ((course + 180) % 360, None)}) == []
    assert any("反向" in error for error in checker.check_records(records, hotspot_directions={key: (course, None)}))


@pytest.mark.parametrize("ambiguous", [False, True])
def test_hotspot_course_requires_local_unambiguous_route_geometry(records, ambiguous):
    point = [25, 121]
    points = [shift(point, 180, 400), shift(point, 0, 400)]
    if ambiguous:
        points += [shift(point, 180, 400)]
    replace_route(records, "回程01", points)
    target = add_hotspot(records, "回程01", 5, address="臺9線14.5K(往坪林)", source="ntpc-mobile",
                         lat=point[0], lon=point[1] if ambiguous else point[1] + 0.001)
    directions = {("ntpc-mobile", checker.normalized_address(target["address"])): (0, None)}
    assert any("不在路線 30 m 內或行向有歧義" in error
               for error in checker.check_records(records, hotspot_directions=directions))


def test_missing_hotspot_type_or_section_state_claim_cannot_hide_a_violation(records):
    target = add_hotspot(records, "去程04", 50, source="ntpc-mobile", sectionActive=False)
    target.pop("cameraType")
    assert any("區間倒數中" in error for error in checker.check_records(records))
    target["t"] = 100
    records.remove(target)
    records.insert(records.index(row(records, "去程04", "camera_pre")), target)
    target["sectionActive"] = True
    assert any("區間倒數中" in error for error in checker.check_records(records))
    target["sectionActive"] = False
    target.pop("address")
    assert any("缺少 address" in error for error in checker.check_records(records))


@pytest.mark.parametrize("fields", [{}, {"cameraType": "tech", "enforcesSpeed": True},
                                   {"cameraType": "fixed", "enforcesSpeed": False}])
def test_ikea_speed_reminder_or_missing_type_evidence_still_fails(records, fields):
    records.insert(records.index(row(records, "去程04", "section_completed")),
                   dict(schema=1, case="去程04 檢查器單元測試", event="camera_pre", t=50, lat=25, lon=121,
                        id="other-fixed", address="中央路白馬寺路口", **fields))
    assert any("IKEA" in error for error in checker.check_records(records))


def test_voice_cooldown_and_first_warning_are_not_confused(records):
    first = row(records, "北宜2去程", "section_overspeed_started")
    new = copy.deepcopy(first)
    new["t"] = 35
    records.insert(records.index(row(records, "北宜2去程", "section_beep", index=2)), new)
    assert any("小於 30 秒" in error for error in checker.check_records(records))


def test_non_overspeed_and_fast_near_thresholds_are_checked(records):
    target = row(records, "北宜2去程", "section_entered")
    extra = dict(target, event="camera_near", id="fast", afterPre=True, overspeed=False,
                 announcedDistance=200, speeches=["200公尺"])
    records.insert(records.index(target), extra)
    assert checker.check_records(records) == []
    extra["speeches"] = ["100公尺，超速"]
    assert any("200公尺" in error for error in checker.check_records(records))


@pytest.mark.parametrize("bad", ["", "舊版只有中文事件\n案例完成：成功 23，失敗 0",
                                "REPLAY1108 {broken", "REPLAY1108 null", 'REPLAY1108 {"schema":2}'])
def test_empty_old_or_malformed_logs_do_not_vacuously_pass(bad):
    assert checker.check_text(bad)


def test_missing_case_or_truncated_end_fails(records):
    assert checker.check_records([r for r in records if not r["case"].startswith("折返02 ")])
    assert checker.check_records(records[:-1])


@pytest.mark.parametrize("prefix", list(checker.BEIYI_CASES) + ["去程03", "回程03", "回程04", "補測01", "補測02", "補測03", "補測04"])
def test_unchanged_cases_cannot_be_dropped_or_abort_vacuously(records, prefix):
    remaining = [r for r in records if not r["case"].startswith(prefix + " ")]
    assert any("缺少案例" in error for error in checker.check_records(remaining))
    target = row(records, prefix, "case_end")
    index = records.index(target)
    records.insert(index, dict(target, event="section_aborted", id="unexpected"))
    assert any("非折返案例" in error for error in checker.check_records(records))


def test_incomplete_lifecycle_counts_and_disabled_city_alerts_fail(records):
    records[:] = [r for r in records if not (r["case"].startswith("去程01 ") and r["event"].startswith("camera_"))]
    assert any("真正的市區" in error for error in checker.check_records(records))
    records[-1]["succeeded"] -= 1
    assert any("成功案例數" in error for error in checker.check_records(records))


@pytest.mark.parametrize("changes,reason", [
    ({"coverage": "not_on_route", "routeDistance": 700}, "未涵蓋"),
    ({"coverage": "different_branch", "matched": False}, "正確分支"),
    ({"triggered": False}, "觸發提示"),
    ({"displayedHint": "左轉 環河路"}, "短句不符"),
    ({"liveActivityHint": ""}, "Live Activity"),
    ({"instruction": "左轉"}, "語音全文"),
    ({"appleSteps": []}, "Apple 原文"),
    ({"speeches": []}, "語音清單"),
])
def test_hint_reports_cannot_pass_missing_route_branch_or_evidence(records, changes, reason):
    row(records, "補測03", "hint_check").update(changes)
    assert any(reason in error for error in checker.check_records(records))


def skip_hint(records, prefix, key, coverage="not_on_route"):
    assert key in checker.HINT_CASES[prefix]
    points = hint_path(prefix, wrong_branch=True) if coverage == "different_branch" else [
        [point[0] + 0.1, point[1]] for point in case_path(prefix)]
    replace_route(records, prefix, points)
    geometry = checker.RouteGeometry(points)
    for report in records:
        if not (report["case"].startswith(prefix + " ") and report["event"] == "hint_check"):
            continue
        point = checker.HINT_POINTS[report["id"]][0]
        along, lateral = geometry.nearest(point)
        report.update(coverage="not_on_route" if lateral > 30 else "different_branch",
                      along=along, routeDistance=lateral,
                      matched=False, triggered=False, displayedHint="", liveActivityHint="", speeches=[])
    records[:] = [r for r in records if not (r["case"].startswith(prefix + " ")
                  and r["event"] in {"nav_hint", "nav_speech"} and r.get("hintID"))]


@pytest.mark.parametrize("coverage", ["not_on_route", "different_branch"])
def test_continuous_routes_can_skip_points_only_with_other_case_coverage(records, tmp_path, capsys, coverage):
    for prefix, ids in checker.CONTINUOUS_HINT_CASES.items():
        for key in ids:
            skip_hint(records, prefix, key, coverage)
    information = []
    assert checker.check_records(records, information=information) == []
    assert sum(any(key in message for key in checker.HINT_POINTS) for message in information) == len(checker.HINT_POINTS)
    path = tmp_path / "alternate-route.log"
    path.write_text("\n".join(checker.MARKER + json.dumps(r) for r in records), encoding="utf-8")
    assert checker.main([str(path)]) == 0
    output = capsys.readouterr().out
    assert "[資訊] 補測01 xiulang-fork 未經過" in output
    assert "[資訊] 補測01 huanhe-underpass 未經過" in output


@pytest.mark.parametrize("key", checker.HINT_POINTS)
def test_point_without_actual_coverage_in_any_case_fails(records, key):
    for prefix, ids in checker.HINT_CASES.items():
        if key in ids:
            skip_hint(records, prefix, key)
    assert f"提示點 {key} 所有案例都沒有通過實際覆蓋檢查" in checker.check_records(records)


@pytest.mark.parametrize("prefix", checker.FIXED_HINT_CASES)
@pytest.mark.parametrize("coverage", ["not_on_route", "different_branch"])
def test_fixed_route_variations_are_informational_when_another_route_really_covers_the_point(records, prefix, coverage):
    skip_hint(records, prefix, checker.FIXED_HINT_CASES[prefix][0], coverage)
    information = []
    assert checker.check_records(records, information=information) == []
    assert any(message.startswith(prefix + " ") and "未經過" in message for message in information)


def alternate_route(records, prefix):
    """r5 去程02 改走辛亥、復興、基隆，沒有師大路水源入口。"""
    points = [[25.0262663, 121.5376475], [25.02249, 121.53784], [25.02123, 121.54330],
              [25.01910, 121.54639], [25.01310, 121.53952], [25.0059115, 121.5341985]]
    replace_route(records, prefix, points)
    records[:] = [r for r in records if not (r["case"].startswith(prefix + " ")
                  and r["event"] in {"nav_display", "nav_speech"})]


def test_r5_alternate_route_is_not_reported_as_missing_shuiyuan_text(records):
    alternate_route(records, "去程02")
    information = []
    assert checker.check_records(records, information=information) == []
    assert any("去程02 未經過「水源南向入口路形」" in message for message in information)


@pytest.mark.parametrize("kind", ["reverse", "parallel", "crossing"])
def test_reverse_parallel_and_crossing_routes_do_not_count_as_the_shuiyuan_joining_branch(records, kind):
    points = case_path("去程02")
    if kind == "reverse":
        points.reverse()
    elif kind == "parallel":
        points = [[lat, lon + 0.0008] for lat, lon in points]
    else:
        points = [shift(checker.SHUIYUAN_ENTRY, 70, 500), list(checker.SHUIYUAN_ENTRY),
                  shift(checker.SHUIYUAN_ENTRY, 250, 500)]
    replace_route(records, "去程02", points)
    records[:] = [r for r in records if not (r["case"].startswith("去程02 ")
                  and r["event"] in {"nav_display", "nav_speech"})]
    information = []
    assert checker.check_records(records, information=information) == []
    assert any("去程02 未經過「水源南向入口路形」" in message for message in information)


def test_every_route_missing_the_shuiyuan_entrance_still_fails_global_coverage(records):
    for prefix in ("去程02", "補測05"):
        alternate_route(records, prefix)
    information = []
    errors = checker.check_records(records, information=information)
    assert any("必驗項目「水源南向入口路形」" in error for error in errors)
    assert not any("畫面沒有" in error or "語音沒有" in error for error in errors)


def test_passing_the_entrance_without_actual_events_cannot_be_hidden_by_another_passing_case(records):
    records[:] = [r for r in records if not (r["case"].startswith("補測05 ")
                  and r["event"] in {"nav_display", "nav_speech"})]
    errors = checker.check_records(records)
    assert any("補測05 畫面沒有" in error for error in errors)
    assert any("補測05 語音沒有" in error for error in errors)


def test_highway_correction_is_verified_against_apple_original_and_the_same_maneuver(records):
    report = row(records, "補測05", "route_geometry")
    report["appleSteps"][1]["corrected"] = "左轉上高速公路，朝(永和)、景美前進"
    speech = row(records, "補測05", "nav_speech")
    speech["stepIndex"] = 99
    errors = checker.check_records(records)
    assert any("原文沒有正確校正" in error for error in errors)
    assert any("補測05 語音沒有" in error for error in errors)


def test_another_highway_maneuver_is_allowed_to_keep_apple_text(records):
    display = row(records, "去程02", "nav_display")
    records.insert(records.index(display) + 1,
                   dict(display, stepIndex=99, maneuverAlong=display["maneuverAlong"] + 600,
                        text="左轉 上高速公路", instruction="左轉上高速公路，未知接續"))
    assert checker.check_records(records) == []


def test_already_named_apple_text_is_not_claimed_as_a_correction(records):
    for prefix in ("去程02", "補測05"):
        step = row(records, prefix, "route_geometry")["appleSteps"][1]
        step["text"] = step["corrected"]
    information = []
    errors = checker.check_records(records, information=information)
    assert any("必驗項目「水源上高速公路原文校正」" in error for error in errors)
    assert any("Apple 沒有提供「上高速公路」原文" in message for message in information)


@pytest.mark.parametrize("prefix,backup,event,reason", [
    ("去程01", "補測09", "camera_pre", "真正的市區"),
    ("去程04", "補測06", "section_entered", "section_entered"),
    ("回程02", "補測07", "section_completed", "section_completed"),
    ("去程04", "補測08", "camera_near", "持續超速"),
])
def test_other_dedicated_checks_do_not_excuse_missing_events_on_a_route_that_was_passed(records, prefix, backup, event, reason):
    records.remove(row(records, prefix, event))
    assert any(reason in error for error in checker.check_records(records))
    assert row(records, backup, event)


def test_a_long_section_detour_is_information_but_no_case_may_vacuously_skip_the_lifecycle(records):
    for prefix in ("去程04", "補測06"):
        points = [[point[0] + 0.1, point[1]] for point in case_path(prefix)]
        replace_route(records, prefix, points)
        records[:] = [r for r in records if not (r["case"].startswith(prefix + " ")
                      and r["event"].startswith("section_"))]
    information = []
    errors = checker.check_records(records, information=information)
    assert any("必驗項目「ntpc-huanhe-f 完整生命週期」" in error for error in errors)
    assert any("去程04 未經過" in message for message in information)
    assert not any("去程04 ntpc-huanhe-f 預期" in error for error in errors)


@pytest.mark.parametrize("points", [[], [[25, 121], [float("nan"), 121]], [[25, 121], [25, 121]]])
def test_missing_or_invalid_geometry_cannot_be_replaced_by_a_success_shaped_event_log(records, points):
    report = row(records, "補測05", "route_geometry")
    row(records, "補測05", "route_geometry_part")["points"] = points
    assert any("完整路線" in error for error in checker.check_records(records))
    records.remove(report)
    assert any("缺少唯一完整路線" in error for error in checker.check_records(records))


def test_complete_numbered_geometry_chunks_are_reassembled_and_missing_chunks_are_rejected(records):
    header = row(records, "補測05", "route_geometry")
    part = row(records, "補測05", "route_geometry_part")
    points = part["points"]
    header["chunkCount"] = 2
    part["points"] = points[:2]
    second = dict(part, index=1, points=points[2:])
    records.insert(records.index(part) + 1, second)
    assert checker.check_records(records) == []
    second["index"] = 0
    assert any("分段缺失、重複或索引無效" in error for error in checker.check_records(records))
    records.remove(second)
    assert any("分段缺失、重複或索引無效" in error for error in checker.check_records(records))


def test_continuous_report_cannot_hide_missing_prompt_with_false_coverage_label(records):
    report = row(records, "補測01", "hint_check")
    report["coverage"] = "not_on_route"
    assert any("未涵蓋狀態與距離／分支證據不符" in error for error in checker.check_records(records))


def test_fixed_case_cannot_start_at_the_hint_even_if_another_case_covers_it(records):
    row(records, "補測04", "hint_check")["along"] = 0
    assert any("不足 500 m" in error for error in checker.check_records(records))


def test_one_combined_speech_covers_both_shuiyuan_and_xiulang_markers(records):
    for prefix in ("補測01", "去程03"):
        reports = {r["id"]: r for r in records if r["case"].startswith(prefix + " ") and r["event"] == "hint_check"}
        first, fork = (reports[key] for key in ("shuiyuan-south-exit", "xiulang-fork"))
        fork["along"] = first["along"] + 38.23
        assert first["speeches"] == fork["speeches"]
    assert checker.check_records(records) == []


def test_hint_report_self_claims_do_not_replace_actual_events(records):
    records[:] = [r for r in records if not (r["case"].startswith("補測01 ") and r["event"] in {"nav_hint", "nav_speech"})]
    errors = checker.check_records(records)
    assert any("不能只信報告自稱" in error for error in errors)
    assert any("實際導航語音" in error for error in errors)


def test_six_landmarks_reverse_endpoints_and_no_duplicate_hint_thresholds(records):
    records.remove(row(records, "補測01", "hint_check", index=3))
    assert any("缺少或重複提示點報告" in error for error in checker.check_records(records))
    row(records, "補測02", "case_start")["toLon"] += 0.01
    assert any("同一對搜尋結果反向" in error for error in checker.check_records(records))
    speech = row(records, "補測02", "nav_speech")
    records.insert(records.index(speech) + 1, copy.deepcopy(speech))
    assert any("重複播報" in error for error in checker.check_records(records))


@pytest.mark.parametrize("encoding", ["utf-8-sig", "utf-16"])
def test_cli_accepts_utf8_or_windows_powershell_log_bom(records, tmp_path, encoding):
    path = tmp_path / "replay.log"
    path.write_text("\n".join(checker.MARKER + json.dumps(r) for r in records), encoding=encoding)
    assert checker.main([str(path)]) == 0


def test_cli_returns_nonzero_with_reason(records, tmp_path, capsys):
    row(records, "去程04", "camera_near")["speeches"] = ["100公尺"]
    path = tmp_path / "bad.log"
    path.write_text("\n".join(checker.MARKER + json.dumps(r) for r in records), encoding="utf-8")
    assert checker.main([str(path)]) == 1
    assert "100公尺，超速" in capsys.readouterr().err
