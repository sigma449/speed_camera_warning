"""逐源核實的地方官方設備、公告熱點及未定位聲音照相；只用標準函式庫。"""
from __future__ import annotations

from dataclasses import dataclass
from collections import Counter
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
from typing import Callable
import unicodedata

from . import sources
from .normalize import Camera, detect_type, parse_axis, parse_direction, parse_float, parse_level, parse_limit
from .sections import bearing
from .source_merge import SourceReport
from . import geocoding_sources

SNAPSHOTS = Path(__file__).resolve().parents[1] / "snapshots"
GOV_LICENSE = "政府資料開放授權條款－第1版（https://data.gov.tw/license）"
NTPC_MOBILE_URL = "https://www.traffic.police.ntpc.gov.tw/cp-3313-97704-27.html"
HCCP_URL = "https://tra6.hccp.gov.tw/trafficweb/pages/camera"
DOULIU_URL = "https://ylhpb.yunlin.gov.tw/Douliu/News_Content.aspx?n=31362&s=577863"
TP_NOISE_URL = "https://www-ws.gov.taipei/Download.ashx?u=LzAwMS9VcGxvYWQvNDQ4L3JlbGZpbGUvMzM5ODYvODMzMzc0MC83YzBlYWViNS1mMzdhLTRjMmMtYjRmOC1lNGJjMGNlZGYzZTgucGRm&n=6Ie65YyX5biC55Kw5aKD5L%2bd6K235bGA44CM5Zu65a6a5byP6auY5Zmq6Z%2bz6LuK6Lyb5YG15ris5pSd5b2x57O757Wx44CN6Kit572u5Zyw6bueKDExNTA5KS5wZGY%3d&icon=..pdf"
CITY_BOXES = {
    "新竹市": (24.7, 24.9, 120.85, 121.08), "新北市": (24.65, 25.4, 121.25, 122.1),
    "臺北市": (24.95, 25.22, 121.45, 121.68), "嘉義市": (23.4, 23.55, 120.35, 120.55),
    "臺中市": (24.0, 24.5, 120.4, 121.5), "澎湖縣": (23.1, 23.9, 119.25, 119.8),
    "彰化縣": (23.75, 24.23, 120.25, 120.75), "雲林縣": (23.45, 23.9, 120.1, 120.85),
    "南投縣": (23.4, 24.3, 120.4, 121.5), "金門縣": (24.3, 24.6, 118.1, 118.5),
    "高雄市": (22.45, 23.55, 120.1, 121.1), "桃園市": (24.3, 25.2, 120.9, 121.6),
    "苗栗縣": (24.25, 24.8, 120.6, 121.3), "基隆市": (25.0, 25.25, 121.6, 121.85),
    "屏東縣": (21.8, 22.95, 120.3, 121.0), "宜蘭縣": (24.3, 24.95, 121.3, 122.0),
}


def _clean(row: dict) -> dict:
    return {str(k).lstrip("\ufeff").strip(): str(v or "").strip() for k, v in row.items() if k is not None}


def _require(rows: list[dict], *columns: str) -> None:
    if not rows or not set(columns) <= _clean(rows[0]).keys():
        raise ValueError(f"來源缺少必要欄位：{columns}")


def _camera(source: str, row: dict, report: SourceReport, *, city: str, address: str, lat: str, lon: str,
            items: str, direction: str = "", limit: str = "", key: str = "", district: str = "",
            tech: bool = False, swap: bool = False, conditions: str = "") -> Camera | None:
    coords = parse_float(lat), parse_float(lon)
    south, north, west, east = CITY_BOXES[city]

    def valid(a, b):
        return a is not None and b is not None and south <= a <= north and west <= b <= east

    if not valid(*coords) and swap and valid(*reversed(coords)):
        coords = coords[1], coords[0]
        report.issue(source, key or address, "已依該來源原檔校正反置經緯欄")
    if not valid(*coords):
        report.location(source, key or address, code="invalid_coordinate",
                        reason=f"座標無效或超出{city}範圍：{lat},{lon}")
        return None
    if not address or not items:
        report.location(source, key or address, code="missing_field", reason="地點或取締項目空白")
        return None
    heading = parse_direction(direction)
    kind = "tech" if tech else detect_type(items, address, direction)
    # 條件速限保留原文；不能把不同車種／車道門檻壓成任一數字。
    numeric = parse_limit(limit) if re.fullmatch(r"\d{2,3}", limit) and "速限" not in conditions else None
    notes = "；".join(x for x in (conditions, limit if limit and numeric is None else "") if x)
    if limit and numeric is None:
        report.issue(source, key or address, f"速限有條件或無法解析：{limit}；只提醒、不發超速警示")
    identity = key or hashlib.sha1(address.encode()).hexdigest()[:12]
    report.location(source, key or address, method="official-coordinate", point=coords)
    return Camera(id=f"{source}-{identity}", type=kind, lat=coords[0], lon=coords[1],
                  heading=heading, axis=parse_axis(direction) if heading is None else None,
                  speedLimit=numeric, address=address, city=city, district=district or None,
                  level=parse_level(address), enforcementItems=items, conditions=notes or None,
                  source=source, sourceID=identity, positionMethod="official-coordinate")


def _chinese(rows, report, source, city, *, tech=False, swap=False, limit_col="速限"):
    _require(rows, "設置地點", "取締項目", "座標緯度", "座標經度")
    result = []
    for raw in rows:
        r = _clean(raw)
        camera = _camera(source, r, report, city=city, address=r["設置地點"],
                         lat=r["座標緯度"], lon=r["座標經度"], items=r["取締項目"],
                         direction=r.get("拍攝方向", ""), limit=r.get(limit_col, ""),
                         key=r.get("設備編號", ""), district=r.get("行政區", ""),
                         tech=tech, swap=swap, conditions=r.get("備註", ""))
        if camera:
            result.append(camera)
    return result


def adapt_178144(rows: list[dict], report: SourceReport) -> list[Camera]:
    _require(rows, "地點", "違規取締項目", "經度", "緯度")
    result = []
    for r in map(_clean, rows):
        # 第一階段只發布明列超速的三處；其他科技點仍列待擴充，不猜測啟用／速限／行向。
        if not any(w in r["違規取締項目"] for w in ("超速", "測速")):
            report.count("178144", "excluded")
            continue
        camera = _camera("178144", r, report, city="新竹市", address=r["地點"],
                         lat=r["緯度"], lon=r["經度"], items=r["違規取締項目"], tech=True)
        if camera:
            result.append(camera)
    return result


def adapt_164507(rows: list[dict], report: SourceReport) -> list[Camera]:
    _require(rows, "location", "item", "latitude", "longitude", "direct")
    result = []
    for r in map(_clean, rows):
        camera = _camera("164507", r, report, city="新北市", address=r["location"],
                         lat=r["latitude"], lon=r["longitude"], items=r["item"], direction=r["direct"],
                         key=r.get("seqno", ""), district=r.get("regionname", ""), tech=True)
        if camera:
            result.append(camera)
    return result


def adapt_123740(rows: list[dict], report: SourceReport) -> list[Camera]:
    _require(rows, "address", "latitude", "longitude", "direct", "limit")
    result = []
    for r in map(_clean, rows):
        camera = _camera("123740", r, report, city="新北市", address=r["address"],
                         lat=r["latitude"], lon=r["longitude"], items="超速", direction=r["direct"],
                         limit=r["limit"], key=r.get("seqno", ""), district=r.get("regionname", ""))
        if camera:
            result.append(camera)
    return result


def adapt_52544(rows: list[dict], report: SourceReport) -> list[Camera]:
    _require(rows, "設置地點", "設備型式", "經度", "緯度")
    result = []
    for r in map(_clean, rows):
        camera = _camera("52544", r, report, city="嘉義市", address=r["設置地點"],
                         lat=r["緯度"], lon=r["經度"], items=r["設備型式"], direction=r.get("拍攝方向", ""),
                         limit=r.get("速限", ""), key=r.get("編號", ""))
        if camera:
            result.append(camera)
    return result


def adapt_83881(rows: list[dict], report: SourceReport) -> list[Camera]:
    return _chinese(rows, report, "83881", "臺中市")


def adapt_172940(rows: list[dict], report: SourceReport) -> list[Camera]:
    return _chinese(rows, report, "172940", "澎湖縣", tech=True)


def adapt_130111(rows: list[dict], report: SourceReport) -> list[Camera]:
    _require(rows, "功能", "設置路段", "設置地點", "緯度", "經度", "速限-速度限制")
    result = []
    for r in map(_clean, rows):
        limit = r["速限-速度限制"]
        variants = re.findall(r"(\d{2,3})\(往([東西南北])\)", limit)
        rows_to_add = [(f"往{direction}", number, f"-{direction}") for number, direction in variants] \
            if len(variants) == 2 else [(r.get("拍攝方向", ""), limit, "")]
        for direction, value, suffix in rows_to_add:
            camera = _camera("130111", r, report, city="臺北市", address=r["設置路段"] + r["設置地點"],
                             lat=r["緯度"], lon=r["經度"], items=r["功能"], direction=direction, limit=value,
                             key=r.get("編號", "") + suffix, district=r.get("轄區", ""))
            if camera:
                result.append(camera)
    return result


def adapt_27969(rows: list[dict], report: SourceReport) -> list[Camera]:
    return _chinese(rows, report, "27969", "彰化縣")


def _yunlin(rows, report, source, tech):
    _require(rows, "project", "Address", "direct", "limit", "ban", "Longitude", "Latitude")
    result = []
    for r in map(_clean, rows):
        if r["project"] == "A00":
            report.count(source, "excluded")
            continue
        camera = _camera(source, r, report, city="雲林縣", address=r["Address"], lat=r["Latitude"],
                         lon=r["Longitude"], items=r["ban"], direction=r["direct"], limit=r["limit"],
                         key=r["project"], tech=tech, swap=True)
        if camera:
            result.append(camera)
    return result


def adapt_178358(rows: list[dict], report: SourceReport) -> list[Camera]:
    return _yunlin(rows, report, "178358", False)


def adapt_178357(rows: list[dict], report: SourceReport) -> list[Camera]:
    return _yunlin(rows, report, "178357", True)


def adapt_156415(rows: list[dict], report: SourceReport) -> list[Camera]:
    _require(rows, "設置地點", "取締項目", "座標緯度", "座標經度")
    retained = []
    for row in rows:
        if "20.77" in str(row.get("設置地點", "")) and "通梁" in str(row.get("設置地點", "")):
            report.location("156415", row["設置地點"], code="conflicting_coordinate",
                            reason="對調後23.555,119.65828距7320同里程23.658247,119.555約15.6公里，無第三來源核實；隔離此衝突列")
        else:
            retained.append(row)
    return _chinese(retained, report, "156415", "澎湖縣", swap=True) if retained else []


def adapt_178119(rows: list[dict], report: SourceReport) -> list[Camera]:
    return _chinese(rows, report, "178119", "金門縣", swap=True, limit_col="速限長度")


def adapt_172905(rows: list[dict], report: SourceReport) -> list[Camera]:
    return _chinese(rows, report, "172905", "彰化縣", tech=True)


def adapt_38357(rows: list[dict], report: SourceReport) -> list[Camera]:
    _require(rows, "設置地點", "取締項目", "經度", "緯度", "限速（km／hr）")
    result = []
    for r in map(_clean, rows):
        camera = _camera("38357", r, report, city="南投縣", address=r["設置地點"],
                         lat=r["緯度"], lon=r["經度"], items=r["取締項目"], direction=r.get("拍攝方向", ""),
                         limit=r["限速（km／hr）"], district=r.get("行政區", ""))
        if camera:
            result.append(camera)
    return result


def adapt_173697(rows: list[dict], report: SourceReport, geocoder=None) -> list[Camera]:
    _require(rows, "測站名", "測點地址")
    cameras = []
    for r in map(_clean, rows):
        if geocoder is None:
            report.location("173697", r["測點地址"], code="reference_unavailable",
                            reason="聲音照相原檔無座標，未提供可靠定位資料；不以地名猜位置")
            continue
        district = re.match(r".+?[市鄉鎮]", r["測點地址"])
        camera = _located_camera("173697", "noise", "彰化縣", district[0] if district else "",
                                 r["測點地址"], r.get("測點編號", ""), geocoder, report)
        if camera:
            cameras.append(camera)
    return cameras


def adapt_156743(rows: list[dict], report: SourceReport) -> list[Camera]:
    _require(rows, "路段描述", "行政區")
    for r in map(_clean, rows):
        report.location("156743", r["路段描述"], code="segment_not_point",
                        reason="聲音照相原檔無座標，未發布；不以路段中心冒充設備")
    return []


def _located_camera(source, kind, city, district, address, key, geocoder, report):
    location = geocoder.locate(city, district, address)
    report.location(source, f"{district} {address}", method=location.method, point=location.point,
                    evidence=location.evidence, reason=location.reason, code=location.reason_code,
                    details=location.details)
    if location.point is None:
        return None
    identity = key or hashlib.sha1(f"{district}|{address}".encode()).hexdigest()[:12]
    return Camera(id=f"{source}-{identity}", type=kind, lat=location.point[0], lon=location.point[1],
                  heading=None, axis=location.axis, speedLimit=None, address=address, city=city,
                  district=district, source=source, sourceID=identity, positionMethod=location.method,
                  enforcementItems="聲音照相" if kind == "noise" else "移動測速公告熱點",
                  conditions="定位依據：" + location.evidence)


def _source_direction(text: str, report: SourceReport, source: str, key: str) -> tuple[str, str]:
    text = unicodedata.normalize("NFKC", text).strip()
    compact = re.sub(r"\s+", "", text)
    pair = re.fullmatch(r"([東西南北])(?:向|往)([東西南北])", compact)
    if pair and (parse_direction(pair[1]) - parse_direction(pair[2])) % 180 != 0:
        report.issue(source, key, f"轉向行向「{text}」不是單一直行方位；保留條件、不猜行車方向")
        return "", "原測照行向：" + text
    if (re.fullmatch(r"(?:[東西南北]{1,2})(?:(?:向|往)[東西南北]{1,2}|向|行|上|下)?", compact)
            or parse_axis(compact) is not None):
        return compact, ""
    return "", "原測照方向：" + text if text else ""


def adapt_176549(rows: list[dict], report: SourceReport) -> list[Camera]:
    _require(rows, "Column2", "Column3", "Column4", "Column6", "Column7", "Column8")
    title = next((key for key in _clean(rows[0]) if "固定桿照相設備" in key), None)
    if title is None or len(rows) < 2 or _clean(rows[1]).get("Column7") != "座標緯(N)度":
        raise ValueError("高雄固定桿表頭或座標欄位已變更")
    cameras = []
    for r in map(_clean, rows):
        if not r[title].isdigit():
            report.count("176549", "excluded")
            continue
        direction, note = _source_direction(r["Column3"], report, "176549", r[title])
        camera = _camera("176549", r, report, city="高雄市", address=r["Column2"],
                         lat=r["Column7"], lon=r["Column8"], items=r["Column6"],
                         direction=direction, limit=r["Column4"], key=r[title],
                         district=r.get("Column5", "") + "區",
                         conditions="；".join(x for x in (r.get("Column9", ""), note) if x))
        if camera:
            cameras.append(camera)
    return cameras


def adapt_176561(rows: list[dict], report: SourceReport) -> list[Camera]:
    _require(rows, "行向編號", "設置位置", "取締項目", "測照行向", "座標緯(N)度", "座標經(E)度")
    cameras = []
    for r in map(_clean, rows):
        direction, note = _source_direction(r["測照行向"], report, "176561", r["行向編號"])
        camera = _camera("176561", r, report, city="高雄市", address=r["設置位置"],
                         lat=r["座標緯(N)度"], lon=r["座標經(E)度"], items=r["取締項目"],
                         key=r["行向編號"], direction=direction, tech=True,
                         conditions="；".join(x for x in (r.get("備註", ""), note) if x))
        if camera:
            cameras.append(camera)
    return cameras


def _column_technology(rows, report, source, *, key="Column1", address="Column2", items="Column3",
                       direction="Column4", lat="Column5", lon="Column6", notes="Column7"):
    _require(rows, key, address, items, direction, lat, lon)
    header = _clean(rows[0])
    if (header[key] not in ("行向編號", "編號") or header[address] not in ("設置位置", "地點")
            or header[items] != "取締項目" or header[direction] != "測照行向"
            or header[lat] not in ("座標緯度", "座標緯(N)度")
            or header[lon] not in ("座標經度", "座標經(E)度")):
        raise ValueError(f"{source} 科技表頭或座標欄位已變更")
    report.count(source, "excluded")
    cameras = []
    for r in map(_clean, rows[1:]):
        if not r[key]:
            report.count(source, "excluded")
            continue
        heading, note = _source_direction(r[direction], report, source, r[key])
        camera = _camera(source, r, report, city="高雄市", address=r[address], items=r[items],
                         lat=r[lat], lon=r[lon], key=r[key], direction=heading, tech=True,
                         conditions="；".join(x for x in (r.get(notes, ""), note) if x))
        if camera:
            cameras.append(camera)
    return cameras


def adapt_176555(rows, report):
    return _column_technology(rows, report, "176555")


def adapt_176558(rows, report):
    _require(rows, "行向編號", "地點", "取締項目", "測照行向", "座標緯度", "座標經度")
    normalized = [dict(r, 設備編號=r["行向編號"], 設置地點=r["地點"], 拍攝方向=r["測照行向"])
                  for r in map(_clean, rows)]
    return _standard_source(normalized, report, "176558", "高雄市", tech=True)


def adapt_176560(rows, report):
    return _column_technology(rows, report, "176560", items="Column4", direction="Column3")


def adapt_176551(rows, report):
    return _column_technology(rows, report, "176551")


def adapt_177827(rows, report):
    return _column_technology(rows, report, "177827", key="租賃式車不停讓行人科技執法監測系統設置地點",
                              address="Column1", items="Column2", direction="Column3",
                              lat="Column4", lon="Column5", notes="Column6")


def adapt_135957(rows: list[dict], report: SourceReport) -> list[Camera]:
    _require(rows, "編號", "科技執法種類", "取締項目", "設置地點（路口或路段）", "座標緯度", "座標經度")
    cameras = []
    for r in map(_clean, rows):
        if "區間" in r["科技執法種類"] and r["設置地點（路口或路段）"] in ("自強隧道", "辛亥隧道"):
            report.count("135957", "excluded")
            report.issue("135957", r["編號"], "已知自強／辛亥區間由既有預告及倒數處理，不再造固定點或區間端點")
            continue
        notes = [r.get("備註", ""), "啟用日期：" + r.get("啟用日期", r.get("啟用時間", "未載"))]
        if r["編號"] in ("79", "80"):
            notes.append("來源行政區與路名／座標有出入，保留原文；定位依官方經緯度")
            report.issue("135957", r["編號"], notes[-1])
        camera = _camera("135957", r, report, city="臺北市", address=r["設置地點（路口或路段）"],
                         lat=r["座標緯度"], lon=r["座標經度"], items=r["取締項目"],
                         key=r["編號"], district=r.get("行政區", ""), tech=True,
                         conditions="；".join(x for x in notes if x))
        if camera:
            cameras.append(camera)
    return cameras


def _standard_source(rows, report, source, city, tech=False):
    _require(rows, "設備編號", "座標緯度", "座標經度")
    columns = _clean(rows[0]).keys()
    if (not {"設置地點(路口或路段)", "設置地點_路口或路段", "設置地點"} & columns
            or not {'取締項目(以"、"分隔)', "取締項目"} & columns):
        raise ValueError(f"{source} 缺少設置地點／取締項目欄位")
    key_counts = Counter(_clean(row)["設備編號"] for row in rows)
    cameras = []
    for r in map(_clean, rows):
        address = r.get("設置地點(路口或路段)", r.get("設置地點_路口或路段", r.get("設置地點", "")))
        items = r.get('取締項目(以"、"分隔)', r.get("取締項目", ""))
        direction, note = _source_direction(r.get("拍攝方向", ""), report, source, r["設備編號"])
        camera = _camera(source, r, report, city=city, address=address, items=items,
                         lat=r["座標緯度"], lon=r["座標經度"], key=r["設備編號"],
                         direction=direction, limit=r.get("速限", ""), district=r.get("行政區", ""),
                         tech=tech, swap=source == "178121",
                         conditions="；".join(x for x in (r.get("備註", ""), r.get("設置區域描述", ""), note) if x))
        if camera:
            if key_counts[r["設備編號"]] > 1:
                # 桃園兩張功能子表各自從1編號；sourceID仍保留原號，App ID須能區分原列。
                signature = "|".join((address, items, r.get("拍攝方向", ""), r["座標緯度"], r["座標經度"]))
                camera.id += "-" + hashlib.sha1(signature.encode()).hexdigest()[:12]
            cameras.append(camera)
    return cameras


def adapt_25935(rows, report):
    return _standard_source(rows, report, "25935", "桃園市")


def adapt_178168(rows, report):
    return _standard_source(rows, report, "178168", "桃園市", tech=True)


def adapt_172174(rows, report):
    return _standard_source(rows, report, "172174", "苗栗縣")


def adapt_172178(rows, report):
    return _standard_source(rows, report, "172178", "苗栗縣", tech=True)


def adapt_178159(rows, report):
    return _standard_source(rows, report, "178159", "基隆市", tech=True)


def adapt_178159_fixed(rows, report):
    return _standard_source(rows, report, "178159-fixed", "基隆市")


def adapt_119017(rows, report):
    return _standard_source(rows, report, "119017", "宜蘭縣")


def adapt_178121(rows, report):
    return _standard_source(rows, report, "178121", "金門縣", tech=True)


def adapt_176021(rows, report):
    _require(rows, "設置地點", "取締項目", "經度", "緯度", "拍攝方向")
    cameras = []
    for r in map(_clean, rows):
        camera = _camera("176021", r, report, city="南投縣", address=r["設置地點"],
                         lat=r["緯度"], lon=r["經度"], items=r["取締項目"],
                         direction=r["拍攝方向"], district=r.get("行政區", ""), tech=True)
        if camera:
            cameras.append(camera)
    return cameras


def adapt_146681(rows, report):
    _require(rows, "Address", "Longitude", "Latitude", "direct", "limit")
    cameras = []
    for r in map(_clean, rows):
        camera = _camera("146681", r, report, city="屏東縣", address=r["Address"],
                         lat=r["Latitude"], lon=r["Longitude"], items="超速",
                         direction=r["direct"], limit=r["limit"], district=r.get("RegionName", ""))
        if camera:
            cameras.append(camera)
    return cameras


def adapt_170673(rows, report):
    _require(rows, "編號", "科技執法種類", "設置地點", "取締項目", "經度", "緯度")
    cameras = []
    for r in map(_clean, rows):
        if "區間" in r["科技執法種類"]:
            report.count("170673", "excluded")
            report.issue("170673", r["編號"], "只載區間單點／長度，不新增固定設備或猜雙端")
            continue
        if not r["取締項目"] or r["取締項目"] == r["設置地點"]:
            report.location("170673", r["編號"], code="invalid_enforcement_item",
                            reason="取締項目空白或複製地址；不能依路口多功能題名補猜功能")
            continue
        direction = re.search(r"([東西南北]向)$", r["設置地點"])
        camera = _camera("170673", r, report, city="臺中市", address=r["設置地點"],
                         lat=r["緯度"], lon=r["經度"], items=r["取締項目"], key=r["編號"],
                         direction=direction[1] if direction else "", tech=True, swap=True,
                         conditions="科技執法種類：" + r["科技執法種類"])
        if camera:
            cameras.append(camera)
    return cameras


class TableParser(HTMLParser):
    """保留每層 table，避免地點內的巢狀表格破壞外層資料列。"""
    def __init__(self):
        super().__init__()
        self.stack: list[dict] = []
        self.tables: list[list[list[str]]] = []

    def handle_starttag(self, tag, attrs):
        if tag == "table":
            self.stack.append({"rows": [], "row": None, "cell": None})
        elif self.stack:
            top = self.stack[-1]
            if tag == "tr":
                top["row"] = []
            elif tag in ("td", "th") and top["row"] is not None:
                top["cell"] = []
            elif tag == "br":
                self.handle_data(" ")

    def handle_data(self, data):
        for table in self.stack:
            if table["cell"] is not None:
                table["cell"].append(data)

    def handle_endtag(self, tag):
        if not self.stack:
            return
        top = self.stack[-1]
        if tag in ("td", "th") and top["cell"] is not None:
            if top["row"] is None:
                raise ValueError("公告表格的儲存格沒有資料列")
            top["row"].append(" ".join("".join(top["cell"]).split()))
            top["cell"] = None
        elif tag == "tr" and top["row"] is not None:
            top["rows"].append(top["row"])
            top["row"] = None
        elif tag == "table":
            self.tables.append(self.stack.pop()["rows"])


def parse_ntpc_mobile(raw: bytes) -> list[dict]:
    parser = TableParser()
    parser.feed(sources.decode_text(raw))
    for table in parser.tables:
        if table and table[0] == ["地區別", "地點"]:
            rows = [{"district": row[0], "address": row[1]} for row in table[1:] if len(row) == 2 and row[1]]
            if not rows:
                raise ValueError("新北移動公告沒有資料列")
            return rows
    raise ValueError("新北移動公告找不到地區別／地點表格")


def parse_hccp_tech(raw: bytes) -> list[dict]:
    parser = TableParser()
    parser.feed(sources.decode_text(raw))
    for table in parser.tables:
        for i, row in enumerate(table):
            if len(row) == 5 and row[1] == "違規取締項目":
                return [dict(zip(("地點", "違規取締項目", "經度", "緯度", "備註"), r))
                        for r in table[i + 1:] if len(r) == 5]
    raise ValueError("新竹警方官網找不到科技執法表；不使用授權未核的移動表")


class ParagraphParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.paragraphs = []
        self.current = None

    def handle_starttag(self, tag, attrs):
        if tag == "p":
            self.current = []
        elif tag == "br" and self.current is not None:
            self.current.append(" ")

    def handle_data(self, data):
        if self.current is not None:
            self.current.append(data)

    def handle_endtag(self, tag):
        if tag == "p" and self.current is not None:
            self.paragraphs.append("".join(self.current).strip())
            self.current = None


def parse_douliu_mobile(raw: bytes) -> list[dict]:
    parser = ParagraphParser()
    parser.feed(sources.decode_text(raw))
    digits = "零一二三四五六七八九"
    labels = [digits[n] if n < 10 else ("十" if n < 20 else digits[n // 10] + "十")
              + (digits[n % 10] if n % 10 else "") for n in range(1, 100)]
    rows = []
    for paragraph in parser.paragraphs:
        match = re.fullmatch(r"\(([一二三四五六七八九十]+)\)(.+)",
                             unicodedata.normalize("NFKC", paragraph), re.S)
        if not match:
            continue
        if len(rows) >= len(labels) or match[1] != labels[len(rows)]:
            raise ValueError("斗六公告編號缺漏、重複或順序已變更")
        address = match[2].strip()
        district = re.match(r"(斗六市|莿桐鄉|林內鄉)", address)
        rows.append(dict(address=address, district=district[0] if district else ""))
    _require(rows, "address", "district")
    return rows


def parse_tp_noise(raw: bytes) -> list[dict]:
    path = SNAPSHOTS / "tp-noise.parsed.json"
    manifest = json.loads((SNAPSHOTS / "manifest.json").read_text(encoding="utf-8"))
    parsed = path.read_bytes()
    if hashlib.sha256(parsed).hexdigest() != manifest["tp-noise"]["parsedSHA256"]:
        raise ValueError("臺北聲音照相核實解析表雜湊不符")
    payload = json.loads(parsed)
    if hashlib.sha256(raw).hexdigest() != payload["originalSHA256"]:
        raise ValueError("臺北聲音照相 PDF 版本變更，須重新解析核對；不套舊地址冒充新版")
    rows = payload["rows"]
    _require(rows, "id", "district", "address")
    if [r["id"] for r in rows] != [str(i) for i in range(1, 29)]:
        raise ValueError("臺北11509聲音照相解析表須完整保留28套")
    return rows


def adapt_tp_noise(rows, report, geocoder):
    _require(rows, "id", "district", "address")
    result = []
    for row in rows:
        camera = _located_camera("tp-noise", "noise", "臺北市", row["district"], row["address"],
                                 row["id"], geocoder, report)
        if camera:
            result.append(camera)
    return result


def _douliu_mileage(address: str) -> tuple[str, float] | None:
    text = unicodedata.normalize("NFKC", address)
    roads = re.findall(r"[臺台](\d+[甲乙丙丁]?)線", text)
    miles = re.findall(r"(\d+(?:\.\d+)?)\s*(?:[kK]|公里)(?![/／]|小時|每)(?:\+(\d+)[mM]?)?", text)
    if len(roads) != 1 or len(miles) != 1 or re.search(r"(?:至|到|～|~|-)\s*\d", text):
        return None
    return "台" + roads[0], float(miles[0][0]) + float(miles[0][1] or 0) / 1000


def _single_mileage(address: str) -> tuple[str, float] | None:
    text = unicodedata.normalize("NFKC", address)
    matches = list(re.finditer(
        r"[臺台](\d+[甲乙丙丁]?)線(?:快速公路|快速道路)?\s*(\d+(?:\.\d+)?)\s*(公里|[kK])"
        r"(?:\+(\d+)(?:[mM])?)?", text))
    if len(matches) != 1:
        return None
    match = matches[0]
    if re.search(r"(?:至|到|～|~|—|－|-)\s*\d", text[match.end():]):
        return None
    return "台" + match[1], float(match[2]) + float(match[4] or 0) / 1000


def _place_name(text: str) -> str:
    text = re.sub(r"\s+", "", text).replace("臺", "台")
    text = re.sub(r"方向$", "", text)
    return {"北市": "台北"}.get(text, re.sub(r"[縣市區鄉鎮]$", "", text))


class MobileDirectionIndex:
    """只用同路、明載里程的官方行政區證據，不拿「往某地」本身當作目的地位置。"""

    def __init__(self, rows: list[dict], junctions: list[Camera], mileage_parser=_single_mileage) -> None:
        self.places: dict[tuple[str, str], set[float]] = {}
        for raw in rows:
            row = _clean(raw)
            mileage = mileage_parser(row.get("address", row.get("路段", "")))
            if mileage:
                self._add(*mileage, row.get("district", row.get("行政區", "")))
        for camera in junctions:
            if camera.source == "osm":
                continue
            mileage = _single_mileage(camera.address)
            if mileage:
                for place in (camera.city, camera.district):
                    if place:
                        self._add(*mileage, place)

    def _add(self, road: str, km: float, place: str) -> None:
        # 行政區有時連縣市一起寫；保留縣市與最後的鄉鎮區，不能用任意子字串配對。
        names = re.findall(r"[^縣市區鄉鎮]+[縣市區鄉鎮]", place)
        for name in names or [place]:
            if name:
                self.places.setdefault((road, _place_name(name)), set()).add(km)

    def toward(self, road: str, km: float, destination: str) -> tuple[int | None, str]:
        target = _place_name(destination)
        miles = self.places.get((road, target), set())
        if not miles:
            return None, f"同路官方行政區沒有「{target}」的可核里程"
        low, high = min(miles), max(miles)
        evidence = f"同路官方行政區「{target}」里程 {low:g}–{high:g}K"
        if km < low - .05:
            return 1, evidence
        if km > high + .05:
            return -1, evidence
        return None, evidence + "跨越／接近熱點，無法唯一判向"


def adapt_mobile(rows: list[dict], source: str, report: SourceReport, resolve=None,
                 junctions: list[Camera] = (), geocoder=None) -> list[Camera]:
    result = []
    mileage_parser = _douliu_mileage if source == "douliu-mobile" else _single_mileage
    directions = MobileDirectionIndex(rows, junctions, mileage_parser)
    city = {"169075": "高雄市", "douliu-mobile": "雲林縣"}.get(source, "新北市")
    for raw in rows:
        r = _clean(raw)
        if source == "169075":
            if not r.get("編號", "").isdigit() or not r.get("路段"):
                report.count(source, "excluded")
                continue
            address, district, direction = r["路段"], r.get("行政區", ""), r.get("測照方向", "")
        else:
            address, district = r["address"], r["district"]
            direction = address
        display_address = (re.split(r"[,，]\s*(?:(?:快|慢)車道)?速限", address, maxsplit=1)[0]
                           if source == "douliu-mobile" else address)
        coords = None
        method = None
        location = None
        matched_junctions = []
        # 只接受明確單一省道里程，不把整段的端點／中心當成熱點。
        mileage = mileage_parser(address)
        if mileage:
            road, km = mileage
            coords = resolve(road, km) if resolve else None
            method = "milestone"
        elif geocoder is None and ("路口" in address or "街口" in address or "巷口" in address):
            def key(text):
                return re.sub(r"[\s，,()（）]", "",
                              text.replace("臺", "台").replace(district, "").replace(city.replace("臺", "台"), ""))
            matches = [c for c in junctions if c.city == city and key(c.address) == key(address)]
            if matches and len({(round(c.lat, 4), round(c.lon, 4)) for c in matches}) == 1:
                coords = matches[0].lat, matches[0].lon
                matched_junctions = matches
                method = "intersection"
        if not coords and not mileage and geocoder:
            location = geocoder.locate(city, district, address)
            coords, method = location.point, location.method
        if not coords:
            report.location(source, f"{district} {address}", code=location.reason_code if location else
                            "milestone_unavailable" if mileage else "reference_unavailable",
                            reason=location.reason if location else "無原生座標／可靠單點里程或唯一既有路口")
            continue
        direction_text = re.sub(r"\d+(?:\.\d+)?[kK].*$", "", direction) if source == "douliu-mobile" else direction
        destination = re.search(r"往([^()（）,，]+)", direction_text)
        both = any(word in direction for word in ("雙向", "往返", "雙方向", "兩向"))
        # 「往北市」是地名，不是「往北」；明載八方位才沿用方位角。
        heading = (parse_direction(destination[1].removesuffix("方向").strip())
                   if destination and re.fullmatch(r"[東西南北]{1,2}(?:方向)?", destination[1].strip())
                   else None)
        axis = parse_axis(direction)
        if location and coords:
            axis = location.axis
        evidence = "公告明載雙向" if both else "公告未載可核單向"
        if heading is not None:
            evidence = f"公告明載方位「{destination[1]}」"
        if mileage and resolve:
            a = resolve(road, max(0, km - .05)) or coords
            b = resolve(road, km + .05) or coords
            if a and b and a != b:
                increasing = bearing(*a, *b)
                axis = round(increasing % 180, 1) % 180
                if destination and not both and heading is None:
                    sign, evidence = directions.toward(road, km, destination[1])
                    if sign:
                        heading = round((increasing + (180 if sign < 0 else 0)) % 360, 1) % 360
                        evidence += "，取里程" + ("增加" if sign > 0 else "減少") + "方向"
            else:
                evidence = "缺少相鄰里程座標，無法取得道路軸向"
        elif matched_junctions and heading is None:
            axes = {(c.heading if c.heading is not None else c.axis) % 180
                    for c in matched_junctions if c.heading is not None or c.axis is not None}
            if len(axes) == 1:
                axis = axes.pop()
                evidence = "沿用唯一既有官方路口的道路軸向；公告未載單向"
        if source == "douliu-mobile" and heading is None and not destination:
            heading = parse_direction(direction)
        if both:
            heading = None
        status = "directional" if heading is not None else "bidirectional" if both and axis is not None else "unresolved"
        report.count(source, status)
        report.mobile_directions.append(dict(source=source, address=display_address, district=district,
                                             heading=heading, axis=axis if heading is None else None,
                                             status=status, evidence=evidence))
        if status == "unresolved":
            report.issue(source, f"{district} {address}", evidence + "；維持沿路雙向軸向" if axis is not None
                         else evidence + "；缺道路軸向，未發布")
            if axis is None:
                report.location(source, f"{district} {address}", code="road_axis_missing",
                                reason=evidence + "；缺道路軸向")
                continue
        location_evidence = location.evidence if location else (
            f"7040 省道里程坐標／{mileage[0]} {mileage[1]:g}K（含內插）；相鄰±50 m取軸向"
            if mileage else "唯一既有官方相同公告路口：" + ",".join(c.id for c in matched_junctions))
        report.location(source, f"{district} {address}", method=method, point=coords, evidence=location_evidence,
                        details=location.details if location else {})
        identity = hashlib.sha1(f"{district}|{address}".encode()).hexdigest()[:12]
        conditions = ("定位依據：" + location_evidence + "；" + evidence + "；"
                      + "公告候選地點，非即時執法；原公告有效期間未載明")
        if display_address != address:
            conditions = "原公告：" + address + "；" + conditions
        result.append(Camera(id=f"{source}-{identity}", type="mobile", lat=coords[0], lon=coords[1],
                             heading=heading, axis=axis if heading is None else None, speedLimit=None,
                             address=display_address, city=city,
                             district=district, source=source, sourceID=identity, positionMethod=method,
                             enforcementItems="移動測速公告熱點",
                             conditions=conditions))
    return result


@dataclass(frozen=True)
class OfficialSource:
    id: str
    title: str
    url: str
    adapter: Callable

    @property
    def dataset_id(self):
        return self.id.split("-")[0]

    @property
    def attribution(self):
        return f"{self.title}（{self.dataset_id}），{GOV_LICENSE}"


OFFICIAL_SOURCES = (
    OfficialSource("178144", "新竹市警察局科技執法點位資訊", "https://odws.hccg.gov.tw/001/Upload/25/opendataback/9059/2006/51a0af55-4a9f-43fb-86cc-5ea09ab58bef.csv", adapt_178144),
    OfficialSource("164507", "新北市路口安全自動偵測系統", "https://data.ntpc.gov.tw/api/datasets/b34dbd89-85a9-4489-bf6c-065537661638/csv/file", adapt_164507),
    OfficialSource("123740", "新北市固定式測速照相", "https://data.ntpc.gov.tw/api/datasets/99f3ff6e-0352-4399-a726-775ab765a1dc/csv/file", adapt_123740),
    OfficialSource("52544", "嘉義市固定式測速照相及闖紅燈照相", "https://data.chiayi.gov.tw/opendata/api/getResource?oid=26242d8c-9340-4553-a67f-5084a37552d4&rid=4adcea0f-ee46-4a9f-bb6e-8f4f3a1817bb", adapt_52544),
    OfficialSource("83881", "臺中市科學儀器執法設備取締地點", "https://newdatacenter.taichung.gov.tw/api/v1/no-auth/resource.download?rid=2f64bc33-243b-4b97-9089-a5f3ed1d9298", adapt_83881),
    OfficialSource("172940", "澎湖縣科技執法地點", "https://opendata.penghu.gov.tw/dataset/bbb46c6f-dd1a-4ca4-b4e4-ef25dab065fc/resource/4666f04f-88ef-4ca9-8cad-d4ee82c76d7e/download/pb140300-2025-02-21-1740105639.csv", adapt_172940),
    OfficialSource("130111", "臺北市固定測速照相地點表", "https://data.taipei/api/dataset/745b8808-061f-4f5b-9a62-da1590c049a9/resource/5012e8ba-5ace-4821-8482-ee07c147fd0a/download", adapt_130111),
    OfficialSource("27969", "彰化縣固定式取締違規照相設備", "https://www.chpb.gov.tw/opendata/2XvPDK8t9UC1v65F7FQ4Kw/csv", adapt_27969),
    OfficialSource("178358", "雲林縣固定式測速照相設備", "https://ws.yunlin.gov.tw/001/Upload/539/opendata/0/2492/0f3f7782-6a19-490b-817b-2b075cce6bc7.csv", adapt_178358),
    OfficialSource("156415", "澎湖縣固定測速照相設置地點表", "https://opendata.penghu.gov.tw/dataset/99f233c2-df0b-4291-b899-81ac3684551b/resource/a3e7b949-275a-4896-aca7-45ef2136f3ae/download/pb140320-2022-07-14-1657785496.csv", adapt_156415),
    OfficialSource("38357", "南投縣固定式自動測速照相桿", "https://data.nantou.gov.tw/dataset/c4ce0306-f6e4-4c37-b52e-3ca8ff679d22/resource/5fb393be-b3bf-4290-a036-b3c22ce290aa/download/1150724.csv", adapt_38357),
    OfficialSource("178119", "金門縣固定式科學儀器執法設備", "https://ws.kinmen.gov.tw/001/Upload/0/relfile/0/0/22376e1d-db64-4ab6-a319-3a3174374f0a.csv", adapt_178119),
    OfficialSource("172905", "彰化縣固定式科技執法設備", "https://www.chpb.gov.tw/opendata/deJgXKJjLESCdBNje_-bYA/csv", adapt_172905),
    OfficialSource("178357", "雲林縣科技執法設備", "https://ws.yunlin.gov.tw/001/Upload/539/opendata/0/2491/be1537c9-659a-46a6-940b-0b89e2c594fa.csv", adapt_178357),
    OfficialSource("173697", "彰化縣固定式聲音照相設置點", "https://www.chepb.gov.tw/opendata/%E5%BD%B0%E5%8C%96%E7%B8%A3%E5%9B%BA%E5%AE%9A%E5%BC%8F%E8%81%B2%E9%9F%B3%E7%85%A7%E7%9B%B8%E8%A8%AD%E7%BD%AE%E9%BB%9E.csv", adapt_173697),
    OfficialSource("156743", "臺南市常有聲音照相設備設置地點", "https://data.tainan.gov.tw/File/ResourceCsvDownload/aee8d509-ede0-40b2-b66f-3dc312bd05f2", adapt_156743),
    OfficialSource("176549", "高雄市115年第4次固定桿違規照相設備", "https://openapi.kcg.gov.tw/Api/Service/Get/c5e78ac2-b06d-472f-9eb1-0f1df2b891cf", adapt_176549),
    OfficialSource("176561", "高雄市115年路口科技執法設備", "https://openapi.kcg.gov.tw/Api/Service/Get/406808f2-42a1-49c2-90f1-bca21920a863", adapt_176561),
    OfficialSource("135957", "臺北市科技執法設備取締地點", "https://data.taipei/api/dataset/986fa73e-c470-4ebf-9f35-3a1c9d2a8788/resource/4715904f-6ce1-41c2-8a68-3bc5303f3607/download", adapt_135957),
    OfficialSource("25935", "桃園市固定式違規照相設備", "https://opendata.tycg.gov.tw/api/dataset/ecd45ee5-4489-436b-bd08-7d4e4111c4a4/resource/6aa72aaf-d703-4a9e-acd7-24c17e934dc3/download", adapt_25935),
    OfficialSource("178168", "桃園市科技執法設備", "https://opendata.tycg.gov.tw/api/dataset/46bd8de0-cb90-4149-a530-5f5b1751b450/resource/636bb62e-cc5b-4ad4-ac11-5849ad5c432d/download", adapt_178168),
    OfficialSource("172174", "苗栗縣固定式闖紅燈、測速照相設備", "https://webws.miaoli.gov.tw/Download.ashx?u=LzAwMS9VcGxvYWQvb3BlbmRhdGEvMTcxNC8yZDhiMzg3Ny1hNjE5LTQwMWYtYjRjYi1lMzExMmQ4ODZmNWYuY3N2&n=6IuX5qCX57ij5Zu65a6a5byP6ZeW57SF54eI44CB5ris6YCf54Wn55u46Kit5YKZ5Y%2bW57eg5Zyw6bueLmNzdg%3d%3d&icon=.csv", adapt_172174),
    OfficialSource("172178", "苗栗縣科技執法設備", "https://webws.miaoli.gov.tw/Download.ashx?u=LzAwMS9VcGxvYWQvb3BlbmRhdGEvMTcxNS83MjlmODcxOC0xNGVkLTQ5NmQtOTMzZS1jOTRmZmZkZjNmYzYuY3N2&n=6IuX5qCX57ij56eR5oqA5Z%2b35rOV6Kit5YKZ5Y%2bW57eg5Zyw6bueLmNzdg%3d%3d&icon=.csv", adapt_172178),
    OfficialSource("178159", "基隆市科技執法設備", "https://www.klg.gov.tw/cht/upload/TechArea.csv", adapt_178159),
    OfficialSource("178159-fixed", "基隆市固定式違規照相設備", "https://www.klg.gov.tw/cht/upload/TechAreafixCam.csv", adapt_178159_fixed),
    OfficialSource("119017", "宜蘭縣固定式違規照相設備", "https://opendata.e-land.gov.tw/dataset/f96c8f5c-b518-40b7-9569-a32684667f74/resource/0764f7b0-c639-4663-8607-8333b5ba493f/download/119017-2026-07-22-1784701530.json", adapt_119017),
    OfficialSource("178121", "金門縣科技執法設備", "https://ws.kinmen.gov.tw/001/Upload/0/relfile/0/0/9eaa309e-e67d-42ca-bd22-518d1dc39bb5.csv", adapt_178121),
    OfficialSource("176021", "南投縣道路砂石車禁駛時段科技執法", "https://data.nantou.gov.tw/dataset/1f5bdf50-d743-4f65-96e0-cd5e8cbd7441/resource/f9cb2592-d3cf-4ce2-b6b2-ea96d155394b/download/1150724.csv", adapt_176021),
    OfficialSource("146681", "屏東縣固定式測速照相地點", "https://www-ws.pthg.gov.tw/Upload/2015pthg/0/relfile/0/0/2ad10795-015f-4e80-a694-143c26163af5.csv", adapt_146681),
    OfficialSource("176555", "高雄市115年第4次車不停讓行人科技執法", "https://openapi.kcg.gov.tw/Api/Service/Get/6e200eb8-223a-47bb-9416-8f6ed58d28fa", adapt_176555),
    OfficialSource("176558", "高雄市115年第4次交通局科技執法", "https://openapi.kcg.gov.tw/Api/Service/Get/181e0e72-b21a-4fc6-b377-554053bb4215", adapt_176558),
    OfficialSource("176560", "高雄市115年第4次輕軌科技執法", "https://openapi.kcg.gov.tw/Api/Service/Get/c6c08d77-95a8-4df1-9214-f608f7103d0a", adapt_176560),
    OfficialSource("176551", "高雄市115年第4次限制車種科技執法", "https://openapi.kcg.gov.tw/Api/Service/Get/2bbc0414-f87e-4fb4-9181-3115a56392c5", adapt_176551),
    OfficialSource("177827", "高雄市115年第3次租賃式車不停讓行人科技執法", "https://openapi.kcg.gov.tw/Api/Service/Get/cbc5c9ac-8e34-407e-b759-af6b4aed4a24", adapt_177827),
    OfficialSource("170673", "臺中市科技執法取締地點", "https://newdatacenter.taichung.gov.tw/api/v1/no-auth/resource.download?rid=b3f58c63-53b3-4c01-8203-2a7afa08bb13", adapt_170673),
)


def load_optional(source: str, url: str, parse, validate, *, offline=False, log=print) -> list[dict]:
    """失聯／格式變動／縮減均明示回退；快照也壞掉只略過該新增來源。"""
    saved = []
    path = SNAPSHOTS / f"{source}.raw"
    try:
        saved = parse(path.read_bytes())
        validate(saved)
    except (OSError, ValueError, KeyError) as exc:
        saved = []
        log(f"[警告] {source} 快照無法使用：{exc}")
    if not offline:
        try:
            rows = parse(sources.http_get(url, timeout=15))
            validate(rows)
            if saved and len(rows) < len(saved):
                raise ValueError(f"筆數 {len(rows)} 少於快照 {len(saved)}，需人工確認撤點")
            log(f"官方新增來源 {source}：下載 {len(rows)} 列")
            return rows
        except (OSError, ValueError, KeyError) as exc:
            log(f"[警告] {source} 下載／驗證失敗：{exc}")
    if saved:
        log(f"[警告] {source} 使用 repo 快照 {path.name}（{len(saved)} 列；非即時資料）")
    else:
        log(f"[警告] {source} 未套用：下載與快照都不可用；保留其他來源")
    return saved


def load_official(report: SourceReport, *, offline=False, log=print) -> tuple[list[Camera], list[str]]:
    cameras, attribution = [], []
    for source in OFFICIAL_SOURCES:
        if source.id == "173697":
            continue  # 與其他文字公告共用一次定位資料載入，避免先失敗再重複計數。
        rows = load_optional(source.id, source.url, sources.parse_payload,
                             lambda rows: source.adapter(rows, SourceReport()), offline=offline, log=log)
        report.count(source.id, "downloaded", len(rows))
        if not rows:
            continue
        adapted = source.adapter(rows, report)
        report.count(source.id, "usable", len(adapted))
        for camera in adapted:
            camera.sourceURL = f"https://data.gov.tw/dataset/{source.dataset_id}"
        cameras += adapted
        if adapted:
            attribution.append(source.attribution)
    report.issue("新竹移動", "官網73方向列", "網站開放宣告回403，頁尾另有未經同意勿轉載；授權未核，不收入發布快照或App")
    return cameras, attribution


def load_mobile(report: SourceReport, *, offline=False, resolve=None, junctions=(), log=print):
    cameras, attribution = [], []
    batches = []
    for source, url, parser, title, kind in (
        ("ntpc-mobile", NTPC_MOBILE_URL, parse_ntpc_mobile, "新北市警察局移動式科學儀器執法地點1141126（網站開放宣告，https://www.traffic.police.ntpc.gov.tw/cp-996-14693-27.html）", "mobile"),
        ("169075", "https://openapi.kcg.gov.tw/Api/Service/Get/6926114c-42b4-486a-944d-cabb974c1de5", sources.parse_payload,
         "高雄市113年移動式測速照相地點（169075），" + GOV_LICENSE, "mobile"),
        ("douliu-mobile", DOULIU_URL, parse_douliu_mobile,
         "雲林縣斗六分局移動式測速地點（2026-01-13公告）；網站開放宣告 https://ylhpb.yunlin.gov.tw/Douliu/cp.aspx?n=31410", "mobile"),
        ("173697", next(s.url for s in OFFICIAL_SOURCES if s.id == "173697"), sources.parse_payload,
         "彰化縣固定式聲音照相設置點（173697），" + GOV_LICENSE, "noise"),
        ("tp-noise", TP_NOISE_URL, parse_tp_noise,
         "臺北市環境保護局固定式聲音照相系統設置地點（11509，28套）；CC0 1.0，https://epib.dep.gov.taipei/News_Content.aspx?n=6CC4AC3B13A460B7&s=59C050CA5F72346C&sms=A1B9CBA5326E4DA8", "noise"),
    ):
        def validate(rows):
            columns = (("編號", "路段", "測照方向") if source == "169075" else
                       ("測站名", "測點地址") if source == "173697" else ("district", "address"))
            _require(rows, *columns)
        rows = load_optional(source, url, parser, validate, offline=offline, log=log)
        report.count(source, "downloaded", len(rows))
        batches.append((source, url, title, rows, kind))
    requests = []
    for source, _, _, rows, _ in batches:
        for r in rows:
            if source == "173697":
                district = re.match(r".+?[市鄉鎮]", r["測點地址"])
                requests.append(dict(city="彰化縣", district=district[0] if district else "", address=r["測點地址"]))
            elif source != "169075":
                requests.append(dict(city={"tp-noise": "臺北市", "douliu-mobile": "雲林縣"}.get(source, "新北市"),
                                     district=r["district"], address=r["address"]))
    geocoder = geocoding_sources.load_geocoder(requests, offline=offline, log=log)
    for source, url, title, rows, kind in batches:
        if not rows:
            continue
        adapted = (adapt_tp_noise(rows, report, geocoder) if source == "tp-noise" else
                   adapt_173697(rows, report, geocoder) if source == "173697" else
                   adapt_mobile(rows, source, report, resolve=resolve, junctions=junctions, geocoder=geocoder))
        report.count(source, "usable", len(adapted))
        for camera in adapted:
            camera.sourceURL = url
        cameras += adapted
        if adapted:
            attribution.append(title)
        if source == "169075":
            report.issue(source, "113年公告", "原始182列中95有效路段；無座標且2026現行性未核，不把整條道路變成熱點")
    if any(c.positionMethod in ("door", "lamp", "intersection") for c in cameras):
        attribution.extend(geocoding_sources.ATTRIBUTION)
    return cameras, attribution
