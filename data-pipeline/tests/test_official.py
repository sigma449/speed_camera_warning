import csv
import io
import json
import os
import sys
import zipfile

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import build_cameras  # noqa: E402
from speedcam_data import official, sources  # noqa: E402
from speedcam_data.normalize import normalize_rows  # noqa: E402
from speedcam_data.sections import SectionError, attach_paths, bearing, load_sections  # noqa: E402


def ntpc_rows():
    return sources.read_local_rows([build_cameras.DEFAULT_NTPC_SNAPSHOT])


def camera_row(address="國道一號南向279公里", lat="25.042383", lon="121.53301", direction="北往南"):
    return {"Address": address, "Latitude": lat, "Longitude": lon, "direct": direction, "limit": "110"}


def authoritative_row(lat="23.373209", lon="120.350715", direction="北往南"):
    return {"設置地點": "國道一號南向279公里", "座標緯度": lat, "座標經度": lon,
            "拍攝方向": direction, "速限": "110"}


def test_national_conflict_uses_authoritative_coordinates_without_removing_other_direction():
    rows = [camera_row(), camera_row(direction="南往北"),
            camera_row("國道一號南向22.7公里", "25.07305", "121.536862")]
    logs = []
    cameras = normalize_rows(official.apply_freeway_coordinates(rows, [authoritative_row()], log=logs.append))
    south = next(c for c in cameras if c.address.endswith("279公里") and c.heading == 180)
    assert (south.lat, south.lon) == (23.373209, 120.350715)
    assert any(c.heading == 0 and c.lat == 25.042383 for c in cameras)
    assert any(c.address.endswith("22.7公里") and c.lat == 25.07305 for c in cameras)
    assert any("來源衝突" in m and "220" in m for m in logs)
    assert len(cameras) == 3


def test_conflicting_or_invalid_authority_is_reported_without_last_row_winning():
    original = camera_row()
    logs = []
    result = official.apply_freeway_coordinates([original],
        [authoritative_row(), authoritative_row(lat="24.0"), authoritative_row(lon="錯誤")], log=logs.append)
    assert result == [original]
    assert any("多組座標" in m for m in logs)
    assert any("座標無效" in m for m in logs)


@pytest.mark.parametrize("address,expected", [
    ("國道一號南向279公里", "1"), ("國道10號西向16.8公里", "10"),
    ("國道三號甲線西向1.7公里", "3甲"), ("台1線", None),
])
def test_freeway_ref_keeps_number_and_branch(address, expected):
    assert official.freeway_ref(address) == expected


def test_zip_source_ignores_manifest_and_rejects_html():
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as archive:
        archive.writestr("manifest.csv", "name,schema\n測速.csv,\n")
        archive.writestr("測速.csv", "設置地點,座標緯度,座標經度,拍攝方向,速限\n國道一號南向279公里,23.373209,120.350715,北往南,110\n")
    rows = sources.parse_payload(stream.getvalue(), "ZIP")
    official.validate_freeway_rows(rows)
    assert len(rows) == 1
    with pytest.raises(ValueError, match="HTML"):
        sources.parse_payload(b"<!DOCTYPE html><html>offline</html>")


def test_official_source_failure_uses_snapshot_explicitly(monkeypatch):
    def offline(*args, **kwargs):
        raise OSError("offline")
    monkeypatch.setattr(sources, "dataset_download_urls", offline)
    monkeypatch.setattr(sources, "http_get", offline)
    logs = []
    rows = sources.fetch_official_rows("126156", build_cameras.DEFAULT_NTPC_SNAPSHOT,
        official.validate_ntpc_rows, fallback_urls=("https://example.gov.tw/sections.csv",), log=logs.append)
    assert len(official.parse_ntpc_sections(rows)) == 9
    assert any("改用 repo 官方快照" in m and "非即時" in m for m in logs)
    assert any("offline" in m for m in logs)


def test_shorter_official_download_does_not_silently_drop_snapshot_rows(monkeypatch):
    saved = sources.read_local_rows([build_cameras.DEFAULT_FREEWAY_SNAPSHOT])
    stream = io.StringIO()
    writer = csv.DictWriter(stream, fieldnames=saved[0].keys())
    writer.writeheader()
    writer.writerow(saved[0])
    monkeypatch.setattr(sources, "dataset_download_urls", lambda _: [("https://example.gov.tw/data.csv", "CSV")])
    monkeypatch.setattr(sources, "http_get", lambda _: stream.getvalue().encode())
    logs = []
    rows = sources.fetch_official_rows("13940", build_cameras.DEFAULT_FREEWAY_SNAPSHOT,
                                      official.validate_freeway_rows, log=logs.append)
    assert rows == saved
    assert any("少於已保存快照" in m for m in logs)


def test_no_source_or_snapshot_keeps_build_running_with_explicit_degradation(monkeypatch, tmp_path):
    monkeypatch.setattr(sources, "dataset_download_urls", lambda _: [])
    logs = []
    assert sources.fetch_official_rows("13940", str(tmp_path / "missing.csv"),
                                      official.validate_freeway_rows, log=logs.append) == []
    assert any("保留原主來源" in m and "未套用此來源" in m for m in logs)


def test_official_sections_keep_directional_endpoints_and_lengths():
    sections = {s["id"]: s for s in official.parse_ntpc_sections(ntpc_rows())}
    south, north = sections["ntpc-huanhe-f"], sections["ntpc-huanhe-r"]
    assert south["start"] == {"lat": 24.9718199, "lon": 121.5292394}
    assert south["end"] == {"lat": 24.9641247, "lon": 121.5367909}
    assert north["start"] == {"lat": 24.9639108, "lon": 121.5369783}
    assert north["end"] == {"lat": 24.9712441, "lon": 121.5309406}
    assert south["lengthMeters"] == 1293.1 and north["lengthMeters"] == 1138.6
    assert south["start"] != north["end"]
    assert sections["ntpc-shoushan"]["lengthMeters"] == 1171.6
    assert sections["ntpc-shoushan"]["end"] == {"lat": 25.0393101, "lon": 121.4072525}


def test_official_beiyi_gates_preserve_length_and_group():
    old = load_sections(build_cameras.DEFAULT_SECTIONS, fetch_index=lambda **_: (_ for _ in ()).throw(OSError("offline")),
                        log=lambda *_: None)
    logs = []
    sections = {s["id"]: s for s in official.apply_ntpc_sections(old, ntpc_rows(), log=logs.append)}
    f, r = sections["beiyi-2-f"], sections["beiyi-2-r"]
    assert f["start"] == {"lat": 24.9504174, "lon": 121.6477995}
    assert f["end"] == {"lat": 24.9429879, "lon": 121.6708659}
    assert r["start"] == {"lat": 24.9430715, "lon": 121.6708954}
    assert r["end"] == {"lat": 24.9503516, "lon": 121.6478697}
    assert (f["lengthMeters"], r["lengthMeters"]) == (5835.3, 5830.5)
    assert (f["startKm"], f["endKm"], r["startKm"], r["endKm"]) == (26.2, 32.2, 32.2, 26.2)
    assert f["id"][:-2] == r["id"][:-2] == "beiyi-2"
    assert sections["beiyi-4-f"] == next(s for s in old if s["id"] == "beiyi-4-f")
    assert any("沒有北宜第 4 段" in m for m in logs)


def test_official_direction_order_is_read_from_same_row_not_assumed():
    rows = ntpc_rows()
    before = {s["id"]: s for s in official.parse_ntpc_sections(rows)}
    row = rows[1]
    for key in ("start latitude", "start longitude", "end latitude", "end longitude"):
        row[key] = " ".join(reversed(row[key].split()))
    row["length"] = "往宜蘭方向：5835.3公尺 往新店方向：5830.5公尺"
    assert {s["id"]: s for s in official.parse_ntpc_sections(rows)} == before


def test_milepost_path_uses_official_gate_and_recomputes_local_entry_heading():
    section = next(s for s in official.parse_ntpc_sections(ntpc_rows()) if s["id"] == "beiyi-2-f")
    old_milepost = (24.950865, 121.647163)
    bend = (24.9500, 121.6483)
    end = (section["end"]["lat"], section["end"]["lon"])
    section["startHeading"] = 0
    assert attach_paths([section], lambda *_: [old_milepost, bend, end], log=lambda *_: None) == 1
    assert section["start"] == {"lat": 24.9504174, "lon": 121.6477995}
    assert section["path"][0] == [24.95042, 121.6478]
    assert section["path"][-1] == [24.94299, 121.67087]
    assert section["startHeading"] == round(bearing(24.9504174, 121.6477995, *bend), 1)


def test_official_beiyi_one_discards_mileposts_behind_gate_instead_of_heading_backwards():
    section = next(s for s in official.parse_ntpc_sections(ntpc_rows()) if s["id"] == "beiyi-1-f")
    before_gate = [(24.95281, 121.59768), (24.9529, 121.59787), (24.95304, 121.59791)]
    ahead = [(24.95366, 121.59964), (24.95778, 121.62236), (24.95755, 121.62341), (24.9566, 121.6237)]
    assert attach_paths([section], lambda *_: before_gate + ahead, log=lambda *_: None) == 1
    assert all(list(p) not in section["path"] for p in before_gate)
    assert section["path"][0] == [24.95313, 121.5981]
    assert 0 < section["startHeading"] < 90
    assert section["lengthMeters"] == 3938.1


@pytest.mark.parametrize("bad_path", [
    [(25.0, 121.0), (25.01, 121.0)],
    [(24.9429879, 121.6708659), (24.9504174, 121.6477995)],
])
def test_unreliable_gate_path_does_not_overwrite_existing_path(bad_path):
    section = next(s for s in official.parse_ntpc_sections(ntpc_rows()) if s["id"] == "beiyi-2-f")
    original = [[section["start"]["lat"], section["start"]["lon"]], [24.95, 121.65],
                [section["end"]["lat"], section["end"]["lon"]]]
    section["path"] = original
    logs = []
    assert attach_paths([section], lambda *_: bad_path, log=logs.append) == 0
    assert section["path"] == original
    assert any("無法可靠銜接" in line and "不套用" in line for line in logs)


@pytest.mark.parametrize("field,value", [
    ("start latitude", "24.9430715"), ("length", "未知"), ("end longitude", "121.6478697 999"),
])
def test_bad_directional_endpoint_or_length_is_not_guessed(field, value):
    rows = ntpc_rows()
    rows[1][field] = value
    with pytest.raises(SectionError, match="126156"):
        official.parse_ntpc_sections(rows)


def test_unresolved_section_camera_is_reported_but_remains_in_database():
    rows = [
        {"Address": "蘇花改中仁隧道", "Latitude": "24.266958", "Longitude": "121.7247", "direct": "雙向(區間測速)"},
        {"Address": "金門大橋區間測速", "Latitude": "24.452068", "Longitude": "118.303474"},
        {"Address": "中仁隧道旁的另一段區間測速", "Latitude": "24.266958", "Longitude": "121.7249"},
    ]
    sections = [{"id": "zhongren-tunnel-f", "name": "中仁", "start": {"lat": 24.278559, "lon": 121.744451},
                 "end": {"lat": 24.248183, "lon": 121.71488}, "lengthMeters": 4831, "speedLimit": 70}]
    logs = []
    db, _ = build_cameras.build(rows, sections, log=logs.append)
    assert len(db["cameras"]) == 3
    assert next(c for c in db["cameras"] if c["address"] == "金門大橋區間測速").get("sectionGroupID") is None
    assert any("金門大橋" in m and "[待查]" in m for m in logs)
    assert next(c for c in db["cameras"] if c["address"] == "蘇花改中仁隧道")["sectionGroupID"] == "zhongren-tunnel"
    assert next(c for c in db["cameras"] if c["address"].startswith("中仁隧道旁")).get("sectionGroupID") is None


def test_freeway_audit_checks_the_named_freeway_not_any_nearby_highway():
    camera = normalize_rows([camera_row()])[0]
    data = {"namedRoads": [
        {"freewayRef": "1", "lines": [[[23.37, 120.35], [23.38, 120.35]]]},
        {"freewayRef": "2", "lines": [[[25.04, 121.53301], [25.05, 121.53301]]]},
    ]}
    logs = []
    official.audit_cameras([camera], [], data, log=logs.append)
    assert any("國道座標異常" in m and "國道1主線" in m for m in logs)
    assert len([m for m in logs if "國道座標異常" in m]) == 1


def test_production_build_keeps_official_fixes_when_mileposts_are_offline(monkeypatch, tmp_path, capsys):
    base = [camera_row(), {"Address": "環河路（中央路至白馬寺，雙向）",
                          "Latitude": "24.97182", "Longitude": "121.529236", "direct": "東西雙向(區間測速)"}]
    monkeypatch.setattr(sources, "fetch_national_rows", lambda: base)
    monkeypatch.setattr(sources, "fetch_official_rows", lambda dataset, *args, **kwargs:
                        sources.read_local_rows([build_cameras.DEFAULT_FREEWAY_SNAPSHOT]) if dataset == "13940" else ntpc_rows())
    def offline(**kwargs):
        raise OSError("mileposts offline")
    monkeypatch.setattr(build_cameras.mileposts, "fetch_index", offline)
    out = tmp_path / "db.json"
    assert build_cameras.main(["--output", str(out), "--no-auto-sections", "--min-count", "2"]) == 0
    db = json.loads(out.read_text(encoding="utf-8"))
    assert next(c for c in db["cameras"] if c["address"].startswith("國道"))["lat"] == 23.373209
    assert {"ntpc-huanhe-f", "ntpc-huanhe-r", "ntpc-shoushan"} <= {s["id"] for s in db["sections"]}
    assert "mileposts offline" in capsys.readouterr().out
