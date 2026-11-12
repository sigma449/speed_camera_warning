"""逐源核實的地方官方設備、公告熱點及未定位聲音照相；只用標準函式庫。"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
from html.parser import HTMLParser
from pathlib import Path
import re
from typing import Callable

from . import sources
from .normalize import Camera, detect_type, parse_axis, parse_direction, parse_float, parse_level, parse_limit
from .sections import bearing
from .source_merge import SourceReport

SNAPSHOTS = Path(__file__).resolve().parents[1] / "snapshots"
GOV_LICENSE = "政府資料開放授權條款－第1版（https://data.gov.tw/license）"
NTPC_MOBILE_URL = "https://www.traffic.police.ntpc.gov.tw/cp-3313-97704-27.html"
HCCP_URL = "https://tra6.hccp.gov.tw/trafficweb/pages/camera"
CITY_BOXES = {
    "新竹市": (24.7, 24.9, 120.85, 121.08), "新北市": (24.65, 25.4, 121.25, 122.1),
    "臺北市": (24.95, 25.22, 121.45, 121.68), "嘉義市": (23.4, 23.55, 120.35, 120.55),
    "臺中市": (24.0, 24.5, 120.4, 121.5), "澎湖縣": (23.1, 23.9, 119.25, 119.8),
    "彰化縣": (23.75, 24.23, 120.25, 120.75), "雲林縣": (23.45, 23.9, 120.1, 120.85),
    "南投縣": (23.4, 24.3, 120.4, 121.5), "金門縣": (24.3, 24.6, 118.1, 118.5),
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
        report.issue(source, key or address, f"座標無效或超出{city}範圍：{lat},{lon}；未發布")
        return None
    if not address or not items:
        report.issue(source, key or address, "地點或取締項目空白；未發布")
        return None
    heading = parse_direction(direction)
    kind = "tech" if tech else detect_type(items, address, direction)
    # 條件速限保留原文；不能把不同車種／車道門檻壓成任一數字。
    numeric = parse_limit(limit) if re.fullmatch(r"\d{2,3}", limit) and "速限" not in conditions else None
    notes = "；".join(x for x in (conditions, limit if limit and numeric is None else "") if x)
    if limit and numeric is None:
        report.issue(source, key or address, f"速限有條件或無法解析：{limit}；只提醒、不發超速警示")
    identity = key or hashlib.sha1(address.encode()).hexdigest()[:12]
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
            report.issue("156415", row["設置地點"],
                         "對調後23.555,119.65828距7320同里程23.658247,119.555約15.6公里，無第三來源核實；隔離此衝突列")
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


def adapt_173697(rows: list[dict], report: SourceReport) -> list[Camera]:
    _require(rows, "測站名", "測點地址")
    for r in map(_clean, rows):
        report.issue("173697", r["測點地址"], "聲音照相原檔無座標，未發布；不以地名猜位置")
    return []


def adapt_156743(rows: list[dict], report: SourceReport) -> list[Camera]:
    _require(rows, "路段描述", "行政區")
    for r in map(_clean, rows):
        report.issue("156743", r["路段描述"], "聲音照相原檔無座標，未發布；不以路段中心冒充設備")
    return []


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


def adapt_mobile(rows: list[dict], source: str, report: SourceReport, resolve=None,
                 junctions: list[Camera] = ()) -> list[Camera]:
    result = []
    for raw in rows:
        r = _clean(raw)
        if source == "169075":
            if not r.get("編號", "").isdigit() or not r.get("路段"):
                continue
            address, district, direction = r["路段"], r.get("行政區", ""), r.get("測照方向", "")
        else:
            address, district = r["address"], r["district"]
            direction = address
        coords = None
        method = None
        # 只接受明確單一省道里程，不把整段的端點／中心當成熱點。
        mileage = re.search(r"[臺台](\d+[甲乙丙丁]?)線(?:快速公路)?\s*(\d+(?:\.\d+)?)\s*(公里|[kKＫｋ])(?:\+(\d+)(?:[mM])?)?", address)
        if mileage and not re.search(r"(?:至|到|～|~|—|－|-)\s*\d", address[mileage.end():]):
            road = "台" + mileage[1]
            km = float(mileage[2]) + float(mileage[4] or 0) / 1000
            coords = resolve(road, km) if resolve else None
            method = "official-milepost"
        elif "路口" in address or "街口" in address or "巷口" in address:
            def key(text):
                return re.sub(r"[\s，,()（）]", "",
                              text.replace("臺", "台").replace(district, "").replace("新北市", ""))
            matches = [c for c in junctions if c.city == "新北市" and key(c.address) == key(address)]
            if matches and len({(round(c.lat, 4), round(c.lon, 4)) for c in matches}) == 1:
                coords = matches[0].lat, matches[0].lon
                method = "existing-official-junction"
        if not coords:
            report.issue(source, f"{district} {address}", "無原生座標／可靠單點里程或唯一既有路口，未發布")
            continue
        heading = parse_direction(direction)
        axis = parse_axis(direction)
        if heading is None and "雙向" in direction and mileage and resolve:
            a, b = resolve(road, max(0, km - .05)), resolve(road, km + .05)
            if a and b and a != b:
                axis = round(bearing(*a, *b) % 180, 1)
        identity = hashlib.sha1(f"{district}|{address}".encode()).hexdigest()[:12]
        result.append(Camera(id=f"{source}-{identity}", type="mobile", lat=coords[0], lon=coords[1],
                             heading=heading, axis=axis if heading is None else None, speedLimit=None,
                             address=address, city="新北市" if source != "169075" else "高雄市",
                             district=district, source=source, sourceID=identity, positionMethod=method,
                             enforcementItems="移動測速公告熱點",
                             conditions=("里程牌定位（含內插）；" if method == "official-milepost" else "")
                             + "公告候選地點，非即時執法；原公告有效期間未載明"))
    return result


@dataclass(frozen=True)
class OfficialSource:
    id: str
    title: str
    url: str
    adapter: Callable

    @property
    def attribution(self):
        return f"{self.title}（{self.id}），{GOV_LICENSE}"


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
)


def load_optional(source: str, url: str, parse, validate, *, offline=False, log=print) -> list[dict]:
    """失聯／格式變動／縮減均明示回退；快照也壞掉只略過該新增來源。"""
    saved = []
    path = SNAPSHOTS / f"{source}.raw"
    try:
        saved = parse(path.read_bytes())
        validate(saved)
    except (OSError, ValueError, KeyError) as exc:
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
        rows = load_optional(source.id, source.url, sources.parse_payload,
                             lambda rows: source.adapter(rows, SourceReport()), offline=offline, log=log)
        report.count(source.id, "downloaded", len(rows))
        if not rows:
            continue
        adapted = source.adapter(rows, report)
        report.count(source.id, "usable", len(adapted))
        for camera in adapted:
            camera.sourceURL = f"https://data.gov.tw/dataset/{source.id}"
        cameras += adapted
        if adapted:
            attribution.append(source.attribution)
    report.issue("新竹移動", "官網73方向列", "網站開放宣告回403，頁尾另有未經同意勿轉載；授權未核，不收入發布快照或App")
    return cameras, attribution


def load_mobile(report: SourceReport, *, offline=False, resolve=None, junctions=(), log=print):
    cameras, attribution = [], []
    for source, url, parser, title in (
        ("ntpc-mobile", NTPC_MOBILE_URL, parse_ntpc_mobile, "新北市警察局移動式科學儀器執法地點1141126（網站開放宣告，https://www.traffic.police.ntpc.gov.tw/cp-996-14693-27.html）"),
        ("169075", "https://openapi.kcg.gov.tw/Api/Service/Get/6926114c-42b4-486a-944d-cabb974c1de5", sources.parse_payload,
         "高雄市113年移動式測速照相地點（169075），" + GOV_LICENSE),
    ):
        def validate(rows):
            _require(rows, *(("district", "address") if source == "ntpc-mobile" else ("編號", "路段", "測照方向")))
        rows = load_optional(source, url, parser, validate, offline=offline, log=log)
        report.count(source, "downloaded", len(rows))
        adapted = adapt_mobile(rows, source, report, resolve=resolve, junctions=junctions)
        report.count(source, "usable", len(adapted))
        for camera in adapted:
            camera.sourceURL = url
        cameras += adapted
        if adapted:
            attribution.append(title)
        if source == "169075":
            report.issue(source, "113年公告", "原始182列中95有效路段；無座標且2026現行性未核，不把整條道路變成熱點")
    return cameras, attribution
