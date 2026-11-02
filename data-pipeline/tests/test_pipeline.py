import datetime as dt
import json
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import build_cameras  # noqa: E402
from speedcam_data import sources  # noqa: E402
from speedcam_data.normalize import (  # noqa: E402
    detect_type,
    in_taiwan,
    normalize_rows,
    parse_coordinates,
    parse_direction,
    parse_limit,
)
from speedcam_data.sections import SectionError, parse_sections_csv  # noqa: E402

FIX = os.path.join(HERE, "fixtures")


def fixture(name):
    return os.path.join(FIX, name)


# ---------------------------------------------------------------- 方向
@pytest.mark.parametrize("text,expected", [
    ("北向南", 180), ("南向北", 0), ("西向東", 90), ("東向西", 270),
    ("東北往西南", 225), ("北往南", 180), ("南至北", 0),
    ("南下", 180), ("北上", 0), ("東行", 90), ("西行", 270),
    ("往北", 0), ("往東", 90), ("向南", 180),
    ("北向", 0), ("南向車道", 180),
    ("北", 0),
    ("雙向", None), ("往返", None), ("東向西、西向東", None),
    ("", None), (None, None), ("往市區", None),
])
def test_parse_direction(text, expected):
    assert parse_direction(text) == expected


# ---------------------------------------------------------------- 速限
@pytest.mark.parametrize("text,expected", [
    ("50", 50), ("60公里", 60), ("大型車60/小型車70", 60), ("速限 110", 110),
    ("", None), (None, None), ("無", None), ("5", None), ("300", None),
])
def test_parse_limit(text, expected):
    assert parse_limit(text) == expected


# ---------------------------------------------------------------- 座標
def test_bbox_includes_outlying_islands():
    assert in_taiwan(25.0330, 121.5654)   # 台北
    assert in_taiwan(23.5700, 119.5800)   # 澎湖
    assert in_taiwan(24.4320, 118.3170)   # 金門
    assert in_taiwan(26.1510, 119.9440)   # 馬祖
    assert not in_taiwan(0, 0)
    assert not in_taiwan(31.23, 121.47)   # 上海


def test_coordinates_swap_and_reject():
    assert parse_coordinates("121.2345", "24.9521") == (24.9521, 121.2345)
    assert parse_coordinates("25.0", "121.5") == (25.0, 121.5)
    assert parse_coordinates("0", "0") is None
    assert parse_coordinates("", "121") is None
    assert parse_coordinates("abc", "121") is None


# ---------------------------------------------------------------- 類型
@pytest.mark.parametrize("kind,address,expected", [
    ("闖紅燈及測速", "", "redLightSpeed"),
    ("闖紅燈", "", "redLight"),
    ("科技執法(不停讓行人)", "", "tech"),
    ("", "國道5號雪山隧道區間測速", "section"),
    (None, "信義路", "fixed"),
])
def test_detect_type(kind, address, expected):
    assert detect_type(kind, address) == expected


# ---------------------------------------------------------------- 整體流程
def test_national_csv_normalization():
    rows = sources.read_local_rows([fixture("national_sample.csv")])
    cams = normalize_rows(rows)
    by_addr = {}
    for c in cams:
        by_addr.setdefault(c.city, []).append(c)
    # 8 列：2 列座標無效、1 列重複合併 → 5 筆
    assert len(cams) == 5
    taipei = sorted(by_addr["臺北市"], key=lambda c: c.heading)
    assert [c.heading for c in taipei] == [90, 270]
    merged = taipei[0]
    assert merged.speedLimit == 40          # 重複資料取較小速限
    assert "(重複)" in merged.address        # 保留較長的地址
    taoyuan = by_addr["桃園市"][0]
    assert (taoyuan.lat, taoyuan.lon) == (24.9521, 121.2345)  # 經緯度對調修正
    assert by_addr["新北市"][0].heading is None                # 雙向
    assert by_addr["臺中市"][0].speedLimit == 80
    assert all(c.type == "fixed" for c in cams)


def test_moi_json_with_header_row():
    rows = sources.read_local_rows([fixture("moi_sample.json")])
    assert len(rows) == 3   # 第一列是欄位說明
    cams = normalize_rows(rows)
    assert {c.city for c in cams} == {"金門縣", "連江縣"}
    kinmen = [c for c in cams if c.city == "金門縣"][0]
    assert kinmen.heading == 270


def test_county_big5_csv():
    rows = sources.read_local_rows([fixture("county_big5.csv")])
    cams = normalize_rows(rows)
    types = sorted(c.type for c in cams)
    assert types == ["redLight", "redLightSpeed", "tech"]
    red = [c for c in cams if c.type == "redLight"][0]
    assert red.speedLimit is None
    assert red.heading == 180


def test_ids_are_stable_and_unique():
    rows = sources.read_local_rows([fixture("national_sample.csv")])
    a = [c.id for c in normalize_rows(rows)]
    b = [c.id for c in normalize_rows(list(reversed(rows)))]
    assert len(set(a)) == len(a)
    assert sorted(a) == sorted(b)


def test_output_schema_matches_swift_model(tmp_path):
    rows = sources.read_local_rows([fixture("national_sample.csv"), fixture("county_big5.csv")])
    sections = parse_sections_csv(
        "id,name,start_lat,start_lon,end_lat,end_lon,length_m,speed_limit,note\n"
        "s1,測試,25.0,121.5,25.03,121.5,3300,60,\n")
    db, report = build_cameras.build(rows, sections, now=dt.datetime(2026, 11, 2, tzinfo=dt.timezone.utc))
    assert db["version"] == "2026-11-02"
    assert db["generatedAt"] == "2026-11-02T00:00:00Z"
    assert db["sources"]
    allowed = {"id", "type", "lat", "lon", "heading", "speedLimit", "address", "city", "district"}
    swift_types = {"fixed", "redLight", "redLightSpeed", "section", "tech", "mobile"}
    for cam in db["cameras"]:
        assert set(cam) <= allowed
        assert {"id", "type", "lat", "lon", "address"} <= set(cam)
        assert cam["type"] in swift_types
    s = db["sections"][0]
    assert set(s) == {"id", "name", "start", "end", "lengthMeters", "speedLimit", "lengthEstimated"}
    assert set(s["start"]) == {"lat", "lon"}
    # 能被寫成 JSON
    json.dumps(db, ensure_ascii=False)
    assert "保留" in report.summary()


def test_cli_with_local_input_and_min_count(tmp_path):
    out = tmp_path / "cameras.json"
    code = build_cameras.main(["--input", fixture("national_sample.csv"), "--output", str(out),
                               "--sections", str(tmp_path / "none.csv"), "--extra", str(tmp_path / "none.csv")])
    assert code == 0
    data = json.loads(out.read_text(encoding="utf-8"))
    assert len(data["cameras"]) == 5
    assert data["sections"] == []

    # 資料沒變時不重寫檔案（版本日期維持不變）
    data["version"] = "2000-01-01"
    out.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    code = build_cameras.main(["--input", fixture("national_sample.csv"), "--output", str(out),
                               "--sections", str(tmp_path / "none.csv"), "--extra", str(tmp_path / "none.csv")])
    assert code == 0
    assert json.loads(out.read_text(encoding="utf-8"))["version"] == "2000-01-01"

    code = build_cameras.main(["--input", fixture("national_sample.csv"), "--output", str(tmp_path / "x.json"),
                               "--sections", str(tmp_path / "none.csv"), "--extra", str(tmp_path / "none.csv"),
                               "--min-count", "100"])
    assert code == 1
    assert not (tmp_path / "x.json").exists()


# ---------------------------------------------------------------- 區間
def test_sections_csv_parsing_and_estimate():
    text = (
        "# 註解會被忽略\n"
        "id,name,start_lat,start_lon,end_lat,end_lon,length_m,speed_limit,note\n"
        "a,官方長度,25.0,121.5,25.03,121.5,3300,60,\n"
        "b,估算長度,25.0,121.5,25.03,121.5,,70,\n"
    )
    a, b = parse_sections_csv(text)
    assert a["lengthMeters"] == 3300 and a["lengthEstimated"] is False
    assert b["lengthEstimated"] is True
    assert b["lengthMeters"] == pytest.approx(3336 * 1.15, rel=0.01)
    assert b["speedLimit"] == 70


@pytest.mark.parametrize("row,msg", [
    ("a,x,25.0,121.5,,121.5,1000,60,", "座標"),
    ("a,x,0,0,25.03,121.5,1000,60,", "台灣"),
    ("a,x,25.0,121.5,25.03,121.5,1000,300,", "速限"),
    (",x,25.0,121.5,25.03,121.5,1000,60,", "id"),
])
def test_sections_validation(row, msg):
    with pytest.raises(SectionError, match=msg):
        parse_sections_csv("id,name,start_lat,start_lon,end_lat,end_lon,length_m,speed_limit,note\n" + row)


def test_bundled_manual_files_are_valid():
    from speedcam_data.sections import load_sections
    assert isinstance(load_sections(os.path.join(HERE, "..", "manual", "sections.csv")), list)
    rows = sources.read_local_rows([os.path.join(HERE, "..", "manual", "cameras_extra.csv")])
    assert isinstance(normalize_rows(rows), list)


def test_collect_urls_from_dataset_metadata():
    meta = {"result": {"title": "測速執法設置點", "distribution": [
        {"resourceFormat": "CSV", "resourceDownloadUrl": "https://example.gov.tw/a.csv"},
        {"resourceFormat": "JSON", "resourceDownloadUrl": "https://example.gov.tw/a.json"},
    ], "landingPage": "https://data.gov.tw/dataset/7320"}}
    urls = []
    sources._collect_urls(meta["result"], urls)
    assert ("https://example.gov.tw/a.csv", "CSV") in urls
    assert ("https://example.gov.tw/a.json", "JSON") in urls
