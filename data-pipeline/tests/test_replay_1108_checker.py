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
        if prefix == "去程02":
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
        add(case, "case_end", 500, sectionStillActive=False)
    add("", "run_end", 0, failed=0, succeeded=len(checker.REQUIRED_CASES), correctManeuvers=1, totalManeuvers=1)
    return out


def row(records, prefix, event, index=0):
    return [r for r in records if r["case"].startswith(prefix + " ") and r["event"] == event][index]


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
