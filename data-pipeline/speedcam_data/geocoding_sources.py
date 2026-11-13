"""只保留查中的官方定位列；線上資料不可用時明示使用小型、可溯源的回退快照。"""
from __future__ import annotations

import csv
import gzip
import hashlib
import io
import json
import math
from pathlib import Path
import re
import urllib.parse
import urllib.request
import zlib

from . import sources
from .geocoding import Geocoder, RoadIndex, normalize_address, parse_address, twd97_to_wgs84
from .normalize import in_taiwan, parse_float

SNAPSHOTS = Path(__file__).resolve().parents[1] / "snapshots" / "geocoding"
OSM_ENDPOINTS = ("https://overpass-api.de/api/interpreter", "https://overpass.kumi.systems/api/interpreter")
ATTRIBUTION = (
    "新北市政府門牌位置168887／路燈123962、臺北市政府門牌155472、彰化縣政府門牌170727，"
    "政府資料開放授權條款－第1版（https://data.gov.tw/license）；只用於已公告地點定位，非設備實測座標",
    "公告地址貼齊與路口拓樸：© OpenStreetMap 貢獻者（ODbL 1.0，https://www.openstreetmap.org/copyright）",
)


def _snapshot(name: str) -> dict:
    manifest = json.loads((SNAPSHOTS / "manifest.json").read_text(encoding="utf-8"))
    raw = (SNAPSHOTS / name).read_bytes()
    if hashlib.sha256(raw).hexdigest() != manifest[name]["sha256"]:
        raise ValueError(f"{name} 快照雜湊不符")
    payload = json.loads(gzip.decompress(raw) if name.endswith(".gz") else raw)
    required = ("sources", "areas", "records", "coverage") if name == "addresses.json" else ("regions",)
    if not isinstance(payload, dict) or not all(k in payload for k in required):
        raise ValueError(f"{name} 快照格式無效")
    if name == "addresses.json":
        if (not isinstance(payload["areas"], dict)
                or not all(isinstance(payload[k], list) for k in ("sources", "records", "coverage"))
                or any(not isinstance(r, dict) or not {"city", "district", "kind", "key", "dataset", "version"} <= r.keys()
                       for r in payload["records"])
                or any(not isinstance(s, dict) or not {"city", "kind", "dataset", "version", "url", "columns", "encoding", "crs"} <= s.keys()
                       for s in payload["sources"])
                or any(not isinstance(row, list) or len(row) != 4 or not all(isinstance(v, str) for v in row)
                       for row in payload["coverage"])):
            raise ValueError("官方定位快照欄位／型別無效")
    else:
        if not isinstance(payload["regions"], list):
            raise ValueError("OSM 行政區清單無效")
        for region in payload["regions"]:
            validate_region(region)
    return payload


def validate_region(region: dict) -> None:
    if (not isinstance(region, dict) or not {"city", "district", "coverage", "ways", "insideNodes", "version"} <= region.keys()
            or not all(isinstance(region[k], list) for k in ("coverage", "ways", "insideNodes"))
            or not all(isinstance(region[k], str) for k in ("city", "district", "version"))
            or not all(isinstance(n, str) for n in region["coverage"])
            or any(not isinstance(n, int) for n in region["insideNodes"])):
        raise ValueError("OSM 行政區道路欄位／型別無效")
    for way in region["ways"]:
        if (not isinstance(way, dict) or not {"id", "nodes", "geometry", "tags"} <= way.keys()
                or not isinstance(way["tags"], dict) or not isinstance(way["nodes"], list)
                or not isinstance(way["geometry"], list) or len(way["nodes"]) != len(way["geometry"])
                or any(not isinstance(n, int) for n in way["nodes"])):
            raise ValueError("OSM 道路缺節點／幾何")
        for p in way["geometry"]:
            if (not isinstance(p, dict) or any(not isinstance(p.get(k), (int, float)) or not math.isfinite(p[k])
                                              for k in ("lat", "lon")) or not in_taiwan(p["lat"], p["lon"])):
                raise ValueError("OSM 道路座標無效")


def requested_keys(requests: list[dict]) -> dict[tuple[str, str, str], set[str]]:
    wanted: dict[tuple, set] = {}
    for row in requests:
        query = parse_address(row["city"], row["district"], row["address"])
        if query and query.kind in ("door", "lamp"):
            wanted.setdefault((row["city"], row["district"], query.kind), set()).add(query.key)
    return wanted


def collect_references(stream, spec: dict, wanted: dict, areas: dict) -> tuple[list[dict], int]:
    reader = csv.DictReader(stream)
    return collect_reference_rows(reader, spec, wanted, areas)


def collect_reference_rows(rows, spec: dict, wanted: dict, areas: dict) -> tuple[list[dict], int]:
    columns = spec["columns"]
    required = {v for v in columns.values() if v}
    found = {}
    count = 0
    for row in rows:
        count += 1
        if count == 1 and not required <= row.keys():
            raise ValueError(f"{spec['dataset']} 官方定位原檔欄位已變更")
        if spec["kind"] == "lamp":
            district = row[columns["district"]].strip()
            key = row[columns["key"]].strip()
        else:
            district = areas.get(row[columns["district"]].strip())
            number = normalize_address(row[columns["number"]])
            match = re.match(r"\d+(?:之\d+)?號", number)
            if not district or not match:
                continue
            key = normalize_address("".join(row[columns[k]] for k in ("road", "area", "lane", "alley"))
                                    + match[0])
        if key not in wanted.get((spec["city"], district, spec["kind"]), set()):
            continue
        a, b = parse_float(row[columns["x"]]), parse_float(row[columns["y"]])
        lat = lon = None
        if a is not None and b is not None:
            if spec["crs"] == "EPSG:4326":
                lat, lon = b, a
            elif spec["crs"] == "EPSG:3826":
                try:
                    lat, lon = twd97_to_wgs84(a, b)
                except ValueError:
                    pass  # 保留命中的無效原列，交給定位器明列失敗，不以舊座標掩蓋。
            else:
                raise ValueError("定位來源未核實座標系統")
        identity = (district, key, lat, lon)
        if identity not in found:
            found[identity] = dict(city=spec["city"], district=district, kind=spec["kind"], key=key,
                                   lat=lat, lon=lon, dataset=spec["dataset"], version=spec["version"],
                                   sourceURL=spec["url"], crs=spec["crs"], raw=row, duplicateRows=0)
        found[identity]["duplicateRows"] += 1
    if not count:
        raise ValueError("官方定位原檔沒有資料列")
    return list(found.values()), count


def _fetch_references(spec, wanted, areas):
    request = urllib.request.Request(spec["url"], headers={"User-Agent": sources.USER_AGENT})
    with urllib.request.urlopen(request, timeout=30, context=sources.ssl_context()) as response:
        digest = hashlib.sha256()

        class DigestReader(io.RawIOBase):
            def readable(self):
                return True

            def readinto(self, buffer):
                count = response.readinto(buffer)
                if count:
                    digest.update(memoryview(buffer)[:count])
                return count

        with io.TextIOWrapper(io.BufferedReader(DigestReader()), encoding=spec["encoding"], newline="") as stream:
            rows, count = collect_references(stream, spec, wanted, areas)
        sha256 = digest.hexdigest()
        for row in rows:
            row["originSHA256"] = sha256
            row["version"] = spec["version"] if sha256 == spec.get("originSHA256") else "SHA256:" + sha256
        return rows, count


def _road_regex(names: set[str]) -> str:
    numerals = {str(n): t for n, t in enumerate("零一二三四五六七八九")}
    def variants(match):
        value = match[0]
        return "(" + value + "|" + numerals[value] + ")" if value in numerals else value
    return "^(" + "|".join(re.sub(r"\d+(?=段)", variants, re.escape(n)).replace("台", "[台臺]")
                            for n in sorted(names)) + ")$"


def fetch_roads(city: str, district: str, names: set[str], endpoint: str) -> dict:
    quote = lambda s: json.dumps(s, ensure_ascii=False)
    pattern = quote(_road_regex(names))
    refs = {re.sub(r"^台|線$", "", n) for n in names if re.fullmatch(r"(?:台|北)\d+[甲乙丙丁]?線", n)}
    selections = "".join(f'way(area.a)["highway"]["{key}"~{pattern}];'
                         for key in ("name", "name:zh", "official_name"))
    if refs:
        selections += 'way(area.a)["highway"]["ref"~' + quote("^(" + "|".join(sorted(refs)) + ")$") + "];"
    query = (f'[out:json][timeout:15];area["boundary"="administrative"]["name"={quote(city)}]->.c;'
             f'rel(area.c)["boundary"="administrative"]["admin_level"~"^(7|8)$"]["name"={quote(district)}]->.b;'
             '.b out tags;.b map_to_area->.a;(' + selections + ')->.w;.w out meta geom;'
             'node(w.w)(area.a);out;')
    raw = sources.http_get(endpoint + "?" + urllib.parse.urlencode({"data": query}), timeout=20)
    obj = json.loads(raw)
    if (not isinstance(obj, dict) or not isinstance(obj.get("elements"), list)
            or any(not isinstance(e, dict) or not isinstance(e.get("tags", {}), dict) for e in obj["elements"])):
        raise ValueError("OSM 回應不是完整資料物件")
    elements = obj.get("elements", [])
    boundaries = [e for e in elements if e.get("type") == "relation" and e.get("tags", {}).get("name") == district]
    ways = [e for e in elements if e.get("type") == "way"]
    nodes = [e["id"] for e in elements if e.get("type") == "node"]
    timestamp = obj.get("osm3s", {}).get("timestamp_osm_base")
    if len(boundaries) != 1 or not timestamp or obj.get("remark"):
        raise ValueError("OSM 行政區不唯一、查詢不完整或缺版本")
    region = dict(city=city, district=district, coverage=sorted(names), ways=ways, insideNodes=nodes,
                  boundaryRelation=boundaries[0]["id"], version=timestamp)
    validate_region(region)
    return region


def load_geocoder(requests: list[dict], *, offline=False, log=print) -> Geocoder:
    addresses, saved_roads = {}, {}
    for name in ("addresses.json", "roads.json.gz"):
        try:
            payload = _snapshot(name)
            if name == "addresses.json":
                addresses = payload
            else:
                saved_roads = payload
        except (OSError, ValueError, KeyError, zlib.error, EOFError) as exc:
            log(f"[警告] 公告定位 {name} 快照無法使用：{exc}")
    wanted = requested_keys(requests)
    references = []
    coverage = set()
    for spec in addresses.get("sources", []):
        saved = [r for r in addresses.get("records", []) if r["dataset"] == spec["dataset"]]
        rows = saved
        required = {(d, k) for (c, d, kind), keys in wanted.items() if c == spec["city"] and kind == spec["kind"] for k in keys}
        if not required:
            continue
        used_snapshot = True
        if not offline:
            try:
                rows, count = _fetch_references(spec, wanted, addresses["areas"].get(spec["city"], {}))
                if count < spec.get("rawRows", 0):
                    raise ValueError(f"官方定位原檔縮減為 {count} 列，需人工確認版本")
                old_keys = {(r["district"], r["key"]) for r in saved} & required
                if not old_keys <= {(r["district"], r["key"]) for r in rows}:
                    raise ValueError("既有已命中門牌／桿號從原檔消失，需人工確認版本")
                used_snapshot = False
                log(f"官方公告定位 {spec['dataset']}：掃描 {count} 列，保留 {len(rows)} 個候選座標")
            except (OSError, ValueError, KeyError, csv.Error, UnicodeError) as exc:
                rows = saved
                log(f"[警告] 官方公告定位 {spec['dataset']} 線上查核失敗：{exc}")
        if used_snapshot:
            log(f"[警告] 官方公告定位 {spec['dataset']} 使用 repo 小型查中列快照（{spec['version']}；非即時）")
            coverage.update((normalize_address(c), d, kind, key) for c, d, kind, key in addresses.get("coverage", [])
                            if c == spec["city"] and kind == spec["kind"])
        else:
            coverage.update((normalize_address(spec["city"]), d, spec["kind"], key) for d, key in required)
        references.extend(rows)
    groups: dict[tuple, set] = {}
    for row in requests:
        query = parse_address(row["city"], row["district"], row["address"])
        if query:
            groups.setdefault((row["city"], row["district"]), set()).update(n for n in (query.road, query.other_road) if n)
    regions = []
    online_available = not offline
    for (city, district), names in sorted(groups.items()):
        saved = next((r for r in saved_roads.get("regions", []) if (r["city"], r["district"]) == (city, district)), None)
        region = None
        if online_available:
            for endpoint in OSM_ENDPOINTS:
                try:
                    region = fetch_roads(city, district, names, endpoint)
                    if saved and set(saved["coverage"]) <= names and len(region["ways"]) < len(saved["ways"]):
                        raise ValueError("同名道路筆數縮減，需人工確認")
                    break
                except (OSError, ValueError, KeyError) as exc:
                    region = None
                    log(f"[警告] 公告道路 {city}{district} 下載／驗證失敗：{exc}")
            if region is None:
                online_available = False
                log("[警告] OSM 定位服務本次不可用，其餘行政區明示回退，避免連續重試壓垮公共服務")
        if region is None:
            if saved:
                region = saved
                log(f"[警告] 公告道路 {city}{district} 使用 repo OSM 快照（{saved['version']}；非即時）")
            else:
                log(f"[警告] 公告道路 {city}{district} 無可用快照，該區未驗證位置不發布")
        if region:
            regions.append(region)
    return Geocoder(references, RoadIndex(regions), coverage)
