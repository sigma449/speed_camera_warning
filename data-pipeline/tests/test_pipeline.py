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
    parse_axis,
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


@pytest.mark.parametrize("text,expected", [
    ("南北雙向", 0), ("南北雙向(區間測速)", 0), ("南北", 0), ("北南雙向", 0),
    ("東西雙向", 90), ("東西雙向（區間測速）", 90),
    ("雙向", None), ("往大溪方向", None), ("", None), (None, None),
])
def test_parse_axis(text, expected):
    assert parse_axis(text) == expected


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
    (None, "中山路 南北雙向(超速闖紅燈)", "redLightSpeed"),
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
    # 9 列：2 列座標無效、1 列重複合併 → 6 筆
    assert len(cams) == 6
    tunnel = [c for c in by_addr["臺北市"] if c.heading is None][0]
    assert tunnel.type == "section" and tunnel.axis == 0   # 方向欄的「(區間測速)」也會判斷類型
    assert tunnel.to_json()["axis"] == 0 and "heading" not in tunnel.to_json()
    taipei = sorted((c for c in by_addr["臺北市"] if c.heading is not None), key=lambda c: c.heading)
    assert [c.heading for c in taipei] == [90, 270]
    merged = taipei[0]
    assert merged.speedLimit == 40          # 重複資料取較小速限
    assert "(重複)" in merged.address        # 保留較長的地址
    taoyuan = by_addr["桃園市"][0]
    assert (taoyuan.lat, taoyuan.lon) == (24.9521, 121.2345)  # 經緯度對調修正
    assert by_addr["新北市"][0].heading is None                # 雙向
    assert by_addr["新北市"][0].axis is None                   # 沒寫南北或東西就不知道軸向
    assert by_addr["臺中市"][0].speedLimit == 80
    assert all(c.type == "fixed" for c in cams if c is not tunnel)


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
    allowed = {"id", "type", "lat", "lon", "heading", "axis", "speedLimit", "address", "city", "district"}
    swift_types = {"fixed", "redLight", "redLightSpeed", "section", "tech", "mobile"}
    for cam in db["cameras"]:
        assert set(cam) <= allowed
        assert {"id", "type", "lat", "lon", "address"} <= set(cam)
        assert cam["type"] in swift_types
    s = db["sections"][0]
    assert set(s) <= {"id", "name", "start", "end", "lengthMeters", "speedLimit", "lengthEstimated", "startHeading"}
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
    assert len(data["cameras"]) == 6
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
    # 不連網：用假的里程牌索引（沿著東西向直線，每 100 m 一支）
    sections = load_sections(os.path.join(HERE, "..", "manual", "sections.csv"),
                             log=lambda *_: None, fetch_index=lambda log=print: _fake_index())
    assert len(sections) == 8          # 北宜 4 段 × 雙向
    by_id = {s["id"]: s for s in sections}
    assert by_id["beiyi-1-f"]["lengthMeters"] == 4100
    assert by_id["beiyi-4-r"]["lengthMeters"] == 12300
    assert all(s["speedLimit"] == 40 and not s["lengthEstimated"] for s in sections)
    assert by_id["beiyi-1-f"]["name"].endswith("（往宜蘭）")
    assert by_id["beiyi-1-r"]["start"] == by_id["beiyi-1-f"]["end"]
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


def test_ssl_context_keeps_verification_but_not_strict_mode():
    import ssl
    ctx = sources.ssl_context()
    assert ctx.verify_mode == ssl.CERT_REQUIRED
    assert ctx.check_hostname is True
    strict = getattr(ssl, "VERIFY_X509_STRICT", 0)
    if strict:
        assert not (ctx.verify_flags & strict)


# ---------------------------------------------------------------- 里程牌與區間
from speedcam_data import mileposts  # noqa: E402
from speedcam_data.sections import load_sections, needs_mileposts  # noqa: E402

MILEPOST_HEADER = "公路編號,起點樁號,牌面內容,TWD97X,TWD97Y,WGS84X,WGS84Y"


def _milepost_rows(start_km=0.0, end_km=80.0, step=0.1, road="台9"):
    """沿北緯 24.95 往東的直線，每 step 公里一支里程牌（假資料：1 公里 = 0.004 經度，確保 80 公里都在台灣範圍內）。"""
    rows = []
    k = start_km
    while k <= end_km + 1e-9:
        rows.append({"公路編號": road, "起點樁號": f"{int(k):03d}K+{round((k - int(k)) * 1000):03d}",
                     "牌面內容": f"{k:g}", "TWD97X": "300000", "TWD97Y": "2760000",
                     "WGS84X": f"{121.5 + k * 0.004:.6f}", "WGS84Y": "24.950000"})
        k = round(k + step, 4)
    return rows


def _fake_index():
    return mileposts.build_index(_milepost_rows(), log=lambda *_: None)


@pytest.mark.parametrize("text,expected", [
    ("台9線", "台9"), ("臺9線", "台9"), ("台009", "台9"), ("省道台9甲線", "台9甲"), ("9", "台9"),
    ("台61", "台61"), ("", None), (None, None), ("國道5號", "台5"),
])
def test_normalize_road(text, expected):
    assert mileposts.normalize_road(text) == expected


@pytest.mark.parametrize("text,expected", [
    ("019K+100", 19.1), ("19K+100", 19.1), ("19+100", 19.1), ("19.1", 19.1), ("19K", 19.0),
    ("23.1K", 23.1), ("068K+600M", 68.6), ("", None), (None, None), ("abc", None),
])
def test_parse_km(text, expected):
    assert mileposts.parse_km(text) == expected


def test_milepost_index_exact_and_interpolated():
    index = mileposts.build_index(_milepost_rows(18, 24, step=0.5), log=lambda *_: None)
    lat, lon = index.resolve("台9", 19.0)
    assert lat == pytest.approx(24.95) and lon == pytest.approx(121.5 + 19 * 0.004)
    lat, lon = index.resolve("台9", 23.1)   # 23.0 與 23.5 之間內插
    assert lon == pytest.approx(121.5 + 23.1 * 0.004, abs=1e-6)
    assert index.resolve("台9", 30) is None      # 超出範圍
    assert index.resolve("台2", 19) is None      # 沒有這條路


def test_milepost_index_rejects_large_gaps_and_averages_duplicates():
    rows = _milepost_rows(10, 10) + _milepost_rows(12, 12)
    index = mileposts.build_index(rows, log=lambda *_: None)
    assert index.resolve("台9", 11) is None       # 間距 2 公里 > 1 公里，不內插
    dup = _milepost_rows(10, 10)
    dup[0]["WGS84Y"] = "24.950200"
    index = mileposts.build_index(_milepost_rows(10, 10) + dup, log=lambda *_: None)
    assert index.resolve("台9", 10)[0] == pytest.approx(24.9501)


def test_milepost_real_headers_2026():
    # 公路局資料集 7040 實際的欄位名稱（2026-11 下載）
    row = {"公路編號": "台9", "公路編碼": "0090", "隸屬縣市": "新北市", "坐標-X-TWD97": "312345.6",
           "坐標-Y-TWD97": "2761234.5", "坐標-E-WGS84": "121.623456", "坐標-N-WGS84": "24.956789",
           "起點樁號": "019K+000", "牌面內容": "19", "種類": "整公里", "牌面方向": "順向"}
    logs = []
    index = mileposts.build_index([row], log=logs.append)
    assert index.resolve("台9", 19) == (24.956789, 121.623456)
    assert any("經度=坐標-E-WGS84" in m and "緯度=坐標-N-WGS84" in m for m in logs)


def test_milepost_columns_missing_raises():
    with pytest.raises(ValueError, match="必要欄位"):
        mileposts.build_index([{"foo": "1", "bar": "2"}], log=lambda *_: None)


def test_sections_from_mileposts_bidirectional():
    text = ("id,name,start_lat,start_lon,end_lat,end_lon,length_m,speed_limit,note,road,start_km,end_km,"
            "bidirectional,forward_label,reverse_label\n"
            "b1,北宜測試,,,,,,40,,台9,19,23.1,yes,往宜蘭,往台北\n"
            "b2,單向測試,,,,,,50,,台9,26.2,32.2,,,\n")
    assert needs_mileposts(text)
    secs = parse_sections_csv(text, resolver=_fake_index().resolve, log=lambda *_: None)
    assert [s["id"] for s in secs] == ["b1-f", "b1-r", "b2"]
    f, r, single = secs
    assert f["name"] == "北宜測試（往宜蘭）" and r["name"] == "北宜測試（往台北）"
    assert f["start"] == r["end"] and f["end"] == r["start"]
    assert f["lengthMeters"] == 4100 and f["lengthEstimated"] is False
    assert f["start"]["lon"] < f["end"]["lon"]     # 里程增加 = 往東（測試資料）
    assert single["lengthMeters"] == 6000
    # 測試資料的道路往東：順向進入方向 90°、反向 270°
    assert f["startHeading"] == pytest.approx(90, abs=0.5)
    assert r["startHeading"] == pytest.approx(270, abs=0.5)


def test_sections_with_explicit_coordinates_have_no_start_heading_unless_given():
    text = ("id,name,start_lat,start_lon,end_lat,end_lon,length_m,speed_limit,forward_heading\n"
            "a,x,25.0,121.5,25.03,121.5,3300,60,\n"
            "b,y,25.0,121.5,25.03,121.5,3300,60,15\n")
    a, b = parse_sections_csv(text, log=lambda *_: None)
    assert "startHeading" not in a
    assert b["startHeading"] == 15


def test_load_sections_skips_when_mileposts_unavailable(tmp_path):
    p = tmp_path / "s.csv"
    p.write_text("id,name,start_lat,start_lon,end_lat,end_lon,length_m,speed_limit,note,road,start_km,end_km\n"
                 "a,有座標,25.0,121.5,25.03,121.5,3300,60,,,,\n"
                 "b,只有里程,,,,,,40,,台9,19,23.1\n", encoding="utf-8")
    logs = []

    def broken(log=print):
        raise RuntimeError("network down")

    secs = load_sections(str(p), log=logs.append, fetch_index=broken)
    assert [s["id"] for s in secs] == ["a"]
    assert any("略過" in m for m in logs)


def test_load_sections_detects_duplicate_ids(tmp_path):
    p = tmp_path / "s.csv"
    p.write_text("id,name,start_lat,start_lon,end_lat,end_lon,length_m,speed_limit\n"
                 "a,x,25.0,121.5,25.03,121.5,3300,60\n"
                 "a,y,25.0,121.5,25.03,121.5,3300,60\n", encoding="utf-8")
    with pytest.raises(SectionError, match="重複"):
        load_sections(str(p), log=lambda *_: None)
