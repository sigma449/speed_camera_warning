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
    NormalizeReport,
    detect_type,
    parse_axis,
    parse_level,
    in_taiwan,
    normalize_rows,
    parse_coordinates,
    parse_direction,
    parse_limit,
)
from speedcam_data.sections import SectionError, attach_paths, parse_sections_csv, simplify_path  # noqa: E402

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
                               "--sections", str(tmp_path / "none.csv"), "--extra", str(tmp_path / "none.csv"), "--no-auto-sections"])
    assert code == 0
    data = json.loads(out.read_text(encoding="utf-8"))
    assert len(data["cameras"]) == 6
    assert data["sections"] == []

    # 資料沒變時不重寫檔案（版本日期維持不變）
    data["version"] = "2000-01-01"
    out.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    code = build_cameras.main(["--input", fixture("national_sample.csv"), "--output", str(out),
                               "--sections", str(tmp_path / "none.csv"), "--extra", str(tmp_path / "none.csv"), "--no-auto-sections"])
    assert code == 0
    assert json.loads(out.read_text(encoding="utf-8"))["version"] == "2000-01-01"

    code = build_cameras.main(["--input", fixture("national_sample.csv"), "--output", str(tmp_path / "x.json"),
                               "--sections", str(tmp_path / "none.csv"), "--extra", str(tmp_path / "none.csv"), "--no-auto-sections",
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
    assert by_id["beiyi-4-r"]["lengthMeters"] == 12000
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


def _curve_rows(road="台9"):
    """L 形道路：0～1 公里往東，1～2 公里往北，每 0.1 公里一支里程牌（1 公里 ≈ 0.01 度）。"""
    rows = []
    for i in range(21):
        k = i / 10
        if k <= 1:
            lat, lon = 24.95, 121.5 + k * 0.01
        else:
            lat, lon = 24.95 + (k - 1) * 0.009, 121.51
        rows.append({"公路編號": road, "起點樁號": f"{int(k):03d}K+{round((k - int(k)) * 1000):03d}",
                     "TWD97X": "300000", "TWD97Y": "2760000", "WGS84X": f"{lon:.6f}", "WGS84Y": f"{lat:.6f}"})
    return rows


def test_milepost_path_follows_posts_in_travel_order():
    index = mileposts.build_index(_curve_rows(), log=lambda *_: None)
    fwd = index.path("台9", 0.55, 1.45)
    assert len(fwd) == 11                                   # 起訖內插點＋中間 9 支（0.6～1.4）
    assert fwd[0][1] == pytest.approx(121.5055, abs=1e-6)   # 0.55K 內插
    assert (24.95, 121.51) in [(round(a, 6), round(b, 6)) for a, b in fwd]   # 經過轉角
    rev = index.path("台9", 1.45, 0.55)
    assert rev == list(reversed(fwd))
    assert index.path("台2", 0, 1) is None


def test_milepost_path_skips_bad_posts_and_rejects_gaps():
    rows = _curve_rows()
    rows[5]["WGS84Y"] = "25.300000"                         # 0.5K 座標填錯（跑到 40 公里外）
    index = mileposts.build_index(rows, log=lambda *_: None)
    path = index.path("台9", 0.2, 0.8)
    assert all(lat < 25 for lat, _ in path)
    assert len(path) == 6                                   # 0.2、0.3、0.4、0.6、0.7、0.8
    sparse = mileposts.build_index(_milepost_rows(0, 1, step=1) + _milepost_rows(4, 5, step=1),
                                   log=lambda *_: None)
    assert sparse.path("台9", 0, 5) is None                 # 1～4 公里缺里程牌


def test_simplify_path_drops_straight_points_but_keeps_corner():
    straight = [(24.95, 121.5 + i * 0.001) for i in range(11)]
    assert simplify_path(straight) == [straight[0], straight[-1]]
    corner = [(24.95, 121.5 + i * 0.001) for i in range(6)] + [(24.95 + i * 0.001, 121.505) for i in range(1, 6)]
    simplified = simplify_path(corner)
    assert simplified == [corner[0], (24.95, 121.505), corner[-1]]


def test_attach_paths_for_both_directions_and_only_with_mileage():
    index = mileposts.build_index(_curve_rows(), log=lambda *_: None)
    text = ("id,name,start_lat,start_lon,end_lat,end_lon,length_m,speed_limit,note,road,start_km,end_km,"
            "bidirectional,forward_label,reverse_label\n"
            "c1,彎路,,,,,,40,,台9,0.5,1.5,yes,往北,往西\n"
            "c2,只有座標,24.95,121.5,24.96,121.51,1500,50,,,,,,,\n")
    secs = parse_sections_csv(text, resolver=index.resolve, log=lambda *_: None)
    f, r, plain = secs
    assert (f["road"], f["startKm"], f["endKm"]) == ("台9", 0.5, 1.5)
    assert (r["startKm"], r["endKm"]) == (1.5, 0.5)
    assert attach_paths(secs, index.path, log=lambda *_: None) == 2
    assert f["path"][0] == [f["start"]["lat"], f["start"]["lon"]]
    assert f["path"][-1] == [f["end"]["lat"], f["end"]["lon"]]
    assert [24.95, 121.51] in f["path"]                     # 有畫出轉角，不是直線
    assert r["path"] == list(reversed(f["path"]))
    assert "path" not in plain


def test_add_paths_keeps_going_when_mileposts_unavailable():
    secs = [{"id": "x", "road": "台9", "startKm": 0, "endKm": 1,
             "start": {"lat": 24.95, "lon": 121.5}, "end": {"lat": 24.95, "lon": 121.51}}]

    def broken(log=print):
        raise OSError("offline")

    logs = []
    build_cameras.add_paths(secs, broken, log=logs.append)
    assert "path" not in secs[0]
    assert any("直線" in m for m in logs)


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


# ---------------------------------------------------------------- 區間文字解析
from speedcam_data import section_text  # noqa: E402
from speedcam_data.section_text import cn_number, parse_section_text  # noqa: E402


@pytest.mark.parametrize("text,expected", [
    ("三", 3), ("七", 7), ("十", 10), ("十一", 11), ("二十", 20), ("六十一", 61), ("9", 9), ("十二三", None), ("", None),
])
def test_cn_number(text, expected):
    assert cn_number(text) == expected


def _seg(address, direction="南北雙向(區間測速)", limit=60):
    segs, problems = parse_section_text(address, direction, limit)
    return [(s.road, s.start_km, s.end_km, s.bidirectional) for s in segs], problems


@pytest.mark.parametrize("address,direction,expected", [
    ("台9線68k+600m至56k+600m", "南北雙向(區間測速)", [("台9", 68.6, 56.6, True)]),
    ("台9線129k+404m至136k+883m(觀音隧道)", "南北雙向(區間測速)", [("台9", 129.404, 136.883, True)]),
    ("南澳鄉台9線110k+960m至蘇澳鎮台9線108k+224m(東澳隧道)", "南北雙向(區間測速)", [("台9", 110.96, 108.224, True)]),
    ("台3線82.2公里至84.3公里", "南北雙向(區間測速)", [("台3", 82.2, 84.3, True)]),
    ("台3線103.2公里至108公里及台3線114.3公里至123.6公里", "南北雙向(區間測速)",
     [("台3", 103.2, 108.0, True), ("台3", 114.3, 123.6, True)]),
    ("台13甲線8.3公里至9.5公里及9.8公里至11公里", "南北雙向(區間測速)",
     [("台13甲", 8.3, 9.5, True), ("台13甲", 9.8, 11.0, True)]),
    ("台61線北向122.6公里至115.6公里及台61線122.2公里至130.2公里", "南向北(區間測速) 北向南(區間測速)",
     [("台61", 122.6, 115.6, False), ("台61", 122.2, 130.2, False)]),
    ("臺21線53.8K至51.1K(北向)/臺21線51.1K至53.9K(南向)", "南北雙向(區間測速)",
     [("台21", 53.8, 51.1, False), ("台21", 51.1, 53.9, False)]),
    ("台61線快速道路157.8K至151.6K(南向北)/148.1K至156.4K(北向南)", "南北雙向(區間測速)",
     [("台61", 157.8, 151.6, False), ("台61", 148.1, 156.4, False)]),
    ("鹿港鎮台61線177至168.1公里(快速道路)(20公噸以上大貨車速限80公里/小時)", "北向(區間測速)",
     [("台61", 177.0, 168.1, False)]),
    ("台1線戰備道429.5-433K", "南北雙向（區間測速）", [("台1", 429.5, 433.0, True)]),
    ("台9線草埔隧道434.4-437.2K", "東西雙向（區間測速）", [("台9", 434.4, 437.2, True)]),
    ("臺11線129.61至126.13K(小馬)", "雙向區間測速", [("台11", 129.61, 126.13, True)]),
    ("臺9丁線59.5K-64K", "雙向區間測速", [("台9丁", 59.5, 64.0, True)]),
    ("台62線快速道路1.7K至0.7K(瑪陵隧道東往西)區間測速", "東往西", [("台62", 1.7, 0.7, False)]),
    ("台64線快速公路東向21.4K主線至23.2K", "東向(區間測速)", [("台64", 21.4, 23.2, False)]),
    ("台65線快速公路北向7.9K主線至4.5K", "北向(區間測速)", [("台65", 7.9, 4.5, False)]),
    ("省道台2線73.7K至79.6K（雙向）", "東西雙向(區間測速)", [("台2", 73.7, 79.6, True)]),
    ("台7乙線5.3K至8.1K（雙向）", "南北雙向(區間測速)", [("台7乙", 5.3, 8.1, True)]),
    ("台三線31.8k至30.5k", "雙向(區間測速)", [("台3", 31.8, 30.5, True)]),
    ("台七乙線12.1k至8.2k", "雙向(區間測速)", [("台7乙", 12.1, 8.2, True)]),
    ("臺9戊線9.92K(壽卡休憩亭)至3.94K森永區間測速", "雙向測速科技執法", [("台9戊", 9.92, 3.94, True)]),
    ("台9線19K至23.1K（雙向）", "東西雙向(區間測速)", [("台9", 19.0, 23.1, True)]),
])
def test_parse_section_text(address, direction, expected):
    segs, problems = _seg(address, direction)
    assert segs == expected, problems


@pytest.mark.parametrize("address,reason", [
    ("縣道140線16.2公里至16.9公里及23.1公里至25.1公里", "不是省道"),
    ("內門區市道182號28.9K至31.8K", "不是省道"),
    ("新莊區壽山路（北118線0K至1.2K）（往新莊方向）", "不是省道"),
    ("金門大橋5K至0.5K(西向)", "不是省道"),
    ("台15線鳳鼻隧道", "沒有里程範圍"),
    ("台62甲線3號隧道出口處至東海街出口(南往北)區間測速", "沒有里程範圍"),
    ("環河路（中央路至白馬寺，雙向）", "沒有里程範圍"),
    ("自強隧道區間測速", "沒有里程範圍"),
])
def test_parse_section_text_skips_unusable(address, reason):
    segs, problems = _seg(address)
    assert segs == []
    assert any(reason in p for p in problems), problems


def test_extract_from_rows_dedupes_and_ignores_non_sections():
    rows = [
        {"CityName": "臺東縣", "Address": "臺11線129.61至126.13K(小馬)", "direct": "雙向區間測速", "limit": "60",
         "Latitude": "22.98017", "Longitude": "121.30966"},
        {"CityName": "臺東縣", "Address": "臺11線126.13K至129.61(小馬)", "direct": "雙向區間測速", "limit": "60",
         "Latitude": "23.00777", "Longitude": "121.32352"},
        {"CityName": "臺北市", "Address": "信義路三段", "direct": "西向東", "limit": "50",
         "Latitude": "25.03", "Longitude": "121.53"},
    ]
    report = section_text.TextParseReport()
    segs = section_text.extract_from_rows(rows, report)
    assert len(segs) == 1                    # 同一段雙向寫成兩筆 → 合併
    assert segs[0].point == (22.98017, 121.30966)
    assert segs[0].speed_limit == 60


def _line_index(road="台9", lat=24.0, lon0=121.2, per_km=0.004, km_from=0, km_to=150):
    rows = []
    k = km_from
    while k <= km_to + 1e-9:
        rows.append({"公路編號": road, "起點樁號": f"{int(k)}K+{round((k - int(k)) * 1000):03d}",
                     "坐標-E-WGS84": f"{lon0 + k * per_km:.6f}", "坐標-N-WGS84": f"{lat:.6f}"})
        k = round(k + 0.1, 4)
    return mileposts.build_index(rows, log=lambda *_: None)


def test_to_sections_builds_both_directions_and_validates_against_point():
    index = _line_index()
    seg = section_text.TextSegment(road="台9", start_km=19, end_km=23.1, bidirectional=True, speed_limit=40,
                                   source_text="台9線19K至23.1K", city="新北市",
                                   point=(24.0, 121.2 + 23.1 * 0.004))
    secs = section_text.to_sections([seg], index.resolve, log=lambda *_: None)
    assert [s["id"] for s in secs] == ["auto-台9-19-23.1-f", "auto-台9-19-23.1-r"]
    assert secs[0]["name"] == "新北市 台9線 19K–23.1K（往東）"
    assert secs[1]["name"].endswith("（往西）")
    assert secs[0]["lengthMeters"] == 4100 and secs[0]["speedLimit"] == 40
    assert secs[0]["startHeading"] == pytest.approx(90, abs=0.5)

    # 照相點離換算出的區間太遠 → 判定為解析錯誤，略過
    far = section_text.TextSegment(road="台9", start_km=19, end_km=23.1, bidirectional=False, speed_limit=40,
                                   source_text="x", point=(24.5, 121.2))
    logs = []
    assert section_text.to_sections([far], index.resolve, log=logs.append) == []
    assert any("可能解析錯誤" in m for m in logs)


def test_to_sections_skips_manual_ranges_and_unresolvable():
    index = _line_index(km_to=30)
    segs = [
        section_text.TextSegment("台9", 19, 23.1, True, 40, "北宜"),
        section_text.TextSegment("台9", 120, 125, True, 60, "超出里程牌範圍"),
        section_text.TextSegment("台9", 1, 3, False, None, "沒有速限"),
    ]
    logs = []
    secs = section_text.to_sections(segs, index.resolve, exclude={("台9", 19.0, 23.1)}, log=logs.append)
    assert secs == []
    assert any("人工資料已有" in m for m in logs)
    assert any("里程牌資料找不到" in m for m in logs)
    assert any("沒有速限" in m for m in logs)


def test_manual_range_keys_and_supplement_csv():
    from speedcam_data.sections import manual_range_keys
    keys = manual_range_keys(os.path.join(HERE, "..", "manual", "sections.csv"))
    assert ("台9", 56.6, 68.6) in keys and ("台9", 19.0, 23.1) in keys
    rows = sources.read_local_rows([os.path.join(HERE, "..", "manual", "sections_text.csv")])
    segs = section_text.extract_from_rows(rows)
    roads = sorted({(s.road, min(s.start_km, s.end_km), max(s.start_km, s.end_km)) for s in segs})
    assert roads == [("台61", 41.5, 46.9), ("台7乙", 8.2, 12.1), ("台9戊", 3.94, 9.92)]
    assert all(s.point is None for s in segs)     # 補充清單沒有座標


@pytest.mark.parametrize("text,expected", [
    ("西向", 270), ("北向(區間測速)", 0), ("南向北(區間測速)", 0), ("東往西", 270), ("北上", 0), ("南下", 180),
    ("往新莊方向", None), ("", None),
])
def test_travel_bearing_of(text, expected):
    assert section_text.travel_bearing_of(text) == expected


def test_speed_unit_slash_is_not_a_segment_separator():
    segs, problems = parse_section_text("鹿港鎮台61線177至168.1公里(快速道路)(20公噸以上大貨車速限80公里/小時)",
                                        "北向(區間測速)", 90)
    assert len(segs) == 1 and problems == []
    assert segs[0].travel_bearing == 0


def test_one_way_order_is_corrected_by_stated_direction():
    # 「西向1.6K至5.4K」：測試資料的里程往東增加，所以往西行駛應該是 5.4K → 1.6K
    index = _line_index(road="台64", km_to=10)
    segs, _ = parse_section_text("省道台64線西向1.6K至5.4K", "西向(區間測速)", 80)
    logs = []
    secs = section_text.to_sections(segs, index.resolve, log=logs.append)
    assert len(secs) == 1
    assert secs[0]["start"]["lon"] > secs[0]["end"]["lon"]        # 由東往西
    assert secs[0]["name"].endswith("（往西）")
    assert secs[0]["startHeading"] == pytest.approx(270, abs=0.5)
    assert any("校正方向" in m for m in logs)

    # 方向與里程一致時不對調
    segs, _ = parse_section_text("台64線快速公路東向21.4K主線至23.2K", "東向(區間測速)", 70)
    index = _line_index(road="台64", km_to=30)
    secs = section_text.to_sections(segs, index.resolve, log=lambda *_: None)
    assert secs[0]["start"]["lon"] < secs[0]["end"]["lon"]


def test_sibling_segments_of_one_entry_use_relaxed_distance():
    # 一筆兩段，照相點在第一段上：第二段離照相點約 8 km → 同一筆有一段通過檢查，所以接受
    index = _line_index(km_to=60)
    point = (24.0, 121.2 + 10 * 0.004)          # 10K 處
    near = section_text.TextSegment("台9", 8, 12, True, 60, "x", point=point, group=1)
    sibling = section_text.TextSegment("台9", 30, 35, True, 60, "x", point=point, group=1)   # 約 8 km
    secs = section_text.to_sections([near, sibling], index.resolve, log=lambda *_: None)
    assert {s["id"] for s in secs} == {"auto-台9-8-12-f", "auto-台9-8-12-r", "auto-台9-30-35-f", "auto-台9-30-35-r"}

    # 太遠（> 15 km）仍然略過
    far = section_text.TextSegment("台9", 50, 55, True, 60, "x", point=point, group=1)          # 約 16 km
    logs = []
    secs = section_text.to_sections([near, far], index.resolve, log=logs.append)
    assert {s["id"] for s in secs} == {"auto-台9-8-12-f", "auto-台9-8-12-r"}
    assert any("可能解析錯誤" in m for m in logs)

    # 不同筆的資料不互相放寬
    other = section_text.TextSegment("台9", 30, 35, True, 60, "y", point=point, group=2)
    secs = section_text.to_sections([near, other], index.resolve, log=lambda *_: None)
    assert {s["id"] for s in secs} == {"auto-台9-8-12-f", "auto-台9-8-12-r"}


def test_extract_assigns_same_group_to_segments_of_one_row():
    rows = [{"CityName": "苗栗縣", "Address": "台3線103.2公里至108公里及台3線114.3公里至123.6公里",
             "direct": "南北雙向(區間測速)", "limit": "60", "Latitude": "24.61412", "Longitude": "120.95242"},
            {"CityName": "新竹縣", "Address": "台3線82.2公里至84.3公里", "direct": "南北雙向(區間測速)", "limit": "60",
             "Latitude": "24.70351", "Longitude": "121.04712"}]
    segs = section_text.extract_from_rows(rows)
    groups = [s.group for s in segs]
    assert groups[0] == groups[1] != groups[2]


@pytest.mark.parametrize("address,expected", [
    ("市民高架道下建國南路", "elevated"),      # 「下」是下匝道，照相點在高架上
    ("市民大道高架京站百貨前", "elevated"),
    ("建國高架道和平東路上方", "elevated"),
    ("國道一號五楊高架北向64.3公里", "elevated"),
    ("台61線29.5K(高架)", "elevated"),
    ("中環路2段台65線高架下（新泰路401巷29號對面）", "surface"),
    ("南科南路與新港社高架橋前", None),
    ("市民大道三段214號前", None),
    ("", None),
])
def test_parse_level(address, expected):
    assert parse_level(address) == expected


def test_surface_marked_near_elevated_cameras():
    rows = [
        {"CityName": "臺北市", "Address": "市民高架道下建國南路", "Longitude": "121.54244", "Latitude": "25.044632",
         "direct": "東西雙向", "limit": "80"},
        {"CityName": "臺北市", "Address": "市民大道三段214號前", "Longitude": "121.53994", "Latitude": "25.044518",
         "direct": "西向東", "limit": "40"},
        {"CityName": "臺北市", "Address": "忠孝東路四段1號前", "Longitude": "121.54400", "Latitude": "25.041600",
         "direct": "西向東", "limit": "50"},   # 約 400 公尺外，不標示
    ]
    report = NormalizeReport()
    cams = {c.address: c for c in normalize_rows(rows, report)}
    assert cams["市民高架道下建國南路"].level == "elevated"
    assert cams["市民大道三段214號前"].level == "surface"
    assert cams["忠孝東路四段1號前"].level is None
    assert cams["市民大道三段214號前"].to_json()["level"] == "surface"
    assert "level" not in cams["忠孝東路四段1號前"].to_json()
    assert (report.elevated, report.surface) == (1, 1)
    assert "高架 1、平面 1" in report.summary()
