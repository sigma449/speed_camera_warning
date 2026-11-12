import copy
import importlib.util
import json
from pathlib import Path

import pytest

CHECKER = Path(__file__).resolve().parents[2] / "scripts" / "ci" / "check-replay-1108.py"
spec = importlib.util.spec_from_file_location("check_replay_1108", CHECKER)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


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
    for prefix in checker.REQUIRED_CASES:
        case = prefix + " 檢查器單元測試"
        add(case, "case_start", 0)
        if prefix == "去程01":
            add(case, "camera_pre", 10, id="city-camera")
            add(case, "camera_passed", 30, id="city-camera")
        elif prefix == "去程02":
            add(case, "nav_display", 10, text="左轉 上水源快速道路")
            add(case, "nav_speech", 20, text="300公尺後，左轉上水源快速道路，朝(永和)、景美前進")
        elif prefix in ("去程04", "回程02"):
            section(case, "ntpc-huanhe-f" if prefix == "去程04" else "ntpc-huanhe-r")
            if prefix == "去程04":
                add(case, "camera_pre", 110, id="3de5c6fd4567")
                add(case, "camera_near", 130, id="3de5c6fd4567", afterPre=True, overspeed=True,
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
            start = out[-1]
            start["hintCheckIDs"] = ids
            if prefix != "補測03":
                address = dict(Name="長春路128號", Query=checker.ADDRESS_QUERY, Lat=25.05478, Lon=121.531)
                store = dict(Name="7-ELEVEN 坪林門市", Query=checker.STORE_QUERY, Lat=24.935, Lon=121.711)
                for side, place in zip(("from", "to"), (address, store) if prefix == "補測01" else (store, address)):
                    start.update({side + key: value for key, value in place.items()})
            spoken = {}
            for index, key in enumerate(ids):
                _, hint_id, short, instruction = checker.HINT_POINTS[key]
                if hint_id in spoken:
                    continue
                along = (index + 1) * 1_000
                add(case, "nav_display", 10 + index * 30, text=short, hintID=hint_id, along=along - 500)
                add(case, "nav_hint", 20 + index * 30, text=short, hintID=hint_id, along=along - 200, distance=200)
                add(case, "nav_speech", 25 + index * 30, text=instruction, hintID=hint_id, along=along - 100, announcement=-1)
                spoken[hint_id] = out[-1]
            for key in ids:
                point, hint_id, short, instruction = checker.HINT_POINTS[key]
                speech = spoken[hint_id]
                add(case, "hint_check", 490, id=key, lat=point[0], lon=point[1], hintID=hint_id,
                    along=speech["along"] + 100, routeDistance=1, coverage="covered", matched=True, triggered=True,
                    shortText=short, instruction=instruction, displayAtPoint=short, displayedHint=short, liveActivityHint=short,
                    appleSteps=[dict(start=0, end=10_000, text="Apple 原文")],
                    speeches=[dict(t=speech["t"], text=instruction, source="navigation", hintID=hint_id)])
        add(case, "case_end", 500, sectionStillActive=False)
    add("", "run_end", 0, failed=0, succeeded=len(checker.REQUIRED_CASES), correctManeuvers=1, totalManeuvers=1)
    return out


def row(records, prefix, event, index=0):
    return [r for r in records if r["case"].startswith(prefix + " ") and r["event"] == event][index]


def test_underpass_replay_starts_before_announcement_window():
    cases = json.loads(CHECKER.with_name("route-replay-1108.json").read_text(encoding="utf-8"))
    case = next(case for case in cases if case["name"].startswith("補測03 "))
    point = checker.HINT_POINTS["huanhe-underpass"][0]
    assert checker.distance((case["from"]["lat"], case["from"]["lon"]), point) >= 500
    assert any(hint["hintID"] == "huanhe-underpass" for hint in case["hintChecks"])


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


@pytest.mark.parametrize("prefix", list(checker.BEIYI_CASES) + ["去程03", "回程04", "補測01", "補測02", "補測03"])
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
    row(records, "補測01", "hint_check").update(changes)
    assert any(reason in error for error in checker.check_records(records))


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
