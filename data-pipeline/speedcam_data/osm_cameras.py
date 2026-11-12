"""Overpass 分區擷取及 OSM 執法關聯解析；設備面向不直接當作受測車行向。"""
from __future__ import annotations

import gzip
import json
from pathlib import Path
import re
import urllib.parse
import zlib

from . import sources
from .normalize import Camera, in_taiwan, parse_float, parse_level
from .sections import bearing, haversine
from .source_merge import SourceReport, direction_matches, merge_sources, unknown_direction

ATTRIBUTION = ("© OpenStreetMap 貢獻者，測速設備與 enforcement 關聯（ODbL 1.0）；"
               "https://www.openstreetmap.org/copyright；融合衍生資料庫與來源快照依 ODbL 分享，"
               "https://github.com/sigma449/speed_camera_warning")
REGIONS = {
    "south": (21.8, 119.3, 22.7, 122.1),
    "central-south": (22.7, 119.3, 23.6, 122.1),
    "central-north": (23.6, 119.3, 24.5, 122.1),
    "north": (24.5, 119.3, 25.4, 122.1),
    "kinmen": (24.3, 118.1, 24.6, 118.5),
    "matsu": (25.9, 119.8, 26.4, 120.6),
}
ENDPOINTS = ("https://overpass-api.de/api/interpreter", "https://overpass.kumi.systems/api/interpreter")
SNAPSHOTS = Path(__file__).resolve().parents[1] / "snapshots" / "osm"


def query_for_region(bounds) -> str:
    bbox = ",".join(map(str, bounds))
    return ('[out:json][timeout:25];area["ISO3166-1"="TW"][admin_level=2]->.tw;('
            f'nwr({bbox})(area.tw)["highway"="speed_camera"];'
            f'rel({bbox})(area.tw)["type"="enforcement"];);out body;>;out body qt;')


def validate(raw: bytes, *, snapshot=False) -> dict:
    obj = json.loads(raw)
    if not isinstance(obj, dict):
        raise ValueError("OSM 回應不是物件")
    if obj.get("remark") or not isinstance(obj.get("elements"), list):
        raise ValueError(obj.get("remark") or "OSM 回應缺少 elements")
    metadata = obj.get("osm3s", {})
    if not isinstance(metadata, dict):
        raise ValueError("OSM 時間欄位格式錯誤")
    if not metadata.get("timestamp_osm_base") and not (
        snapshot and obj.get("sourceTimestamp") and obj.get("pbfMD5") and obj.get("license") == "ODbL-1.0"
    ):
        raise ValueError("OSM 回應缺少資料時間")
    for element in obj["elements"]:
        if not isinstance(element, dict) or element.get("type") not in ("node", "way", "relation") or not isinstance(element.get("id"), int):
            raise ValueError("OSM 元素缺少有效類型／ID")
        tags = element.get("tags", {})
        if not isinstance(tags, dict) or any(not isinstance(value, str) for value in tags.values()):
            raise ValueError("OSM tags 格式錯誤")
        if not isinstance(element.get("version", 0), int):
            raise ValueError("OSM version 格式錯誤")
        if element["type"] == "node" and ("lat" in element or "lon" in element):
            coords = element.get("lat"), element.get("lon")
            if (not all(isinstance(v, (int, float)) and not isinstance(v, bool) and parse_float(v) is not None
                        for v in coords) or not -90 <= coords[0] <= 90 or not -180 <= coords[1] <= 180):
                raise ValueError("OSM 點座標不是有效經緯數值")
        members = element.get("members", [])
        if not isinstance(members, list) or any(
            not isinstance(m, dict) or m.get("type") not in ("node", "way", "relation")
            or not isinstance(m.get("ref"), int) for m in members
        ):
            raise ValueError("OSM 關聯成員格式錯誤")
    return obj


def load_elements(*, offline=False, log=print) -> list[dict]:
    unique = {}
    for region, bounds in REGIONS.items():
        saved = None
        try:
            saved = validate(gzip.decompress((SNAPSHOTS / f"{region}.json.gz").read_bytes()), snapshot=True)
        except (OSError, EOFError, ValueError, zlib.error) as exc:
            log(f"[警告] OSM {region} 快照失效：{exc}")
        obj = None
        if not offline:
            query = query_for_region(bounds)
            for endpoint in ENDPOINTS:
                try:
                    url = endpoint + "?" + urllib.parse.urlencode({"data": query})
                    obj = validate(sources.http_get(url, timeout=35))
                    old_count = sum(e.get("tags", {}).get("highway") == "speed_camera" for e in saved["elements"]) if saved else 0
                    new_count = sum(e.get("tags", {}).get("highway") == "speed_camera" for e in obj["elements"])
                    if new_count < old_count:
                        raise ValueError(f"測速物件縮減 {old_count} → {new_count}，需人工確認")
                    break
                except (OSError, ValueError) as exc:
                    log(f"[警告] OSM {region} 下載失敗 {endpoint}：{exc}")
                    obj = None
        if obj is None:
            obj = saved
            if obj:
                timestamp = obj.get("osm3s", {}).get("timestamp_osm_base") or obj["sourceTimestamp"]
                origin = "Overpass" if "osm3s" in obj else "Geofabrik PBF 擷取"
                log(f"[警告] OSM {region} 使用 repo {origin} 快照（{timestamp}；非即時）")
            else:
                log(f"[警告] OSM {region} 未套用，不能宣稱完整全臺擷取")
                continue
        log(f"OSM {region}：{len(obj['elements'])} 個原始元素（含跨區重複成員）")
        for element in obj["elements"]:
            key = element.get("type"), element.get("id")
            previous = unique.get(key)
            if previous is None or element.get("version", 0) >= previous.get("version", 0):
                unique[key] = element
    return list(unique.values())


def _headings(tags: dict, report: SourceReport, identity: str) -> list[float | None]:
    raw = tags.get("direction", "")
    if raw:
        report.issue("osm", identity, f"direction={raw} 為設備面向或相對way標記，不據此猜車行向；僅採可驗證from→to")
    return [None]


def _limit(tags: dict, report: SourceReport, identity: str) -> tuple[int | None, str | None]:
    raw = str(tags.get("maxspeed", ""))
    conditional = tags.get("maxspeed:conditional")
    if conditional:
        report.issue("osm", identity, f"速限有條件 maxspeed={raw}, conditional={conditional}；App不猜適用條件，只提醒")
        return None, "；".join(x for x in (raw, conditional) if x)
    match = re.fullmatch(r"(\d{2,3})(?:\s*(km/h|kph|mph))?", raw)
    if match:
        number = round(int(match[1]) * (1.609344 if match[2] == "mph" else 1))
        if 10 <= number <= 130:
            return number, conditional
    if raw:
        report.issue("osm", identity, f"無法確認一般速限 maxspeed={raw}；只提醒")
    return None, "；".join(x for x in (raw, conditional) if x) or None


def parse_cameras(elements: list[dict], report: SourceReport) -> list[Camera]:
    nodes = {e["id"]: e for e in elements if e.get("type") == "node"}
    relations = [e for e in elements if e.get("type") == "relation" and e.get("tags", {}).get("type") == "enforcement"]
    used = set()
    result = []

    def camera(node, identity, headings, tags, items="超速"):
        lat, lon = parse_float(node.get("lat")), parse_float(node.get("lon"))
        if lat is None or lon is None or not in_taiwan(lat, lon):
            report.issue("osm", identity, "設備沒有有效點座標；不以 way／relation 中心代替")
            return
        speed, conditions = _limit(tags, report, identity)
        if tags.get("direction"):
            note = f"OSM direction={tags['direction']}（未直接用作車行向）"
            conditions = "；".join(x for x in (conditions, note) if x)
        name = tags.get("name") or tags.get("addr:street") or f"OSM 測速照相（{identity}）"
        for i, heading in enumerate(headings):
            result.append(Camera(id=f"osm-{identity}" + (f"-{i}" if len(headings) > 1 else ""), type="fixed",
                                 lat=lat, lon=lon, heading=heading, speedLimit=speed, address=name,
                                 city=tags.get("addr:city"), district=tags.get("addr:suburb"),
                                 level=parse_level(name), enforcementItems=items, conditions=conditions,
                                 source="osm", sourceID=identity,
                                 sourceURL="https://www.openstreetmap.org/" + identity.replace("-", "/", 1),
                                 positionMethod="osm-device-node"))

    for relation in relations:
        tags = relation.get("tags", {})
        identity = f"relation-{relation['id']}"
        if tags.get("enforcement") != "maxspeed":
            report.issue("osm", identity, f"enforcement={tags.get('enforcement', '未標')}，非已確認單點測速；未發布")
            continue
        members = relation.get("members", [])
        devices = [nodes[m["ref"]] for m in members if m.get("type") == "node" and m.get("role") == "device" and m["ref"] in nodes]
        origins = [nodes[m["ref"]] for m in members if m.get("type") == "node" and m.get("role") == "from" and m["ref"] in nodes]
        destinations = [nodes[m["ref"]] for m in members if m.get("type") == "node" and m.get("role") == "to" and m["ref"] in nodes]
        if not devices:
            report.issue("osm", identity, "無已確認的 device 點；不把 from 或包圍盒中心當設備")
            continue
        for device in devices:
            combined = device.get("tags", {}) | tags
            headings = _headings(device.get("tags", {}), report, identity)
            if len(origins) == len(destinations) == len(devices) == 1:
                a, b = origins[0], destinations[0]
                if all(k in point for point in (a, b) for k in ("lat", "lon")) and haversine(a["lat"], a["lon"], b["lat"], b["lon"]) >= 10:
                    heading = round(bearing(a["lat"], a["lon"], b["lat"], b["lon"]), 1)
                    headings = [heading]
            elif any(h is None for h in headings):
                report.issue("osm", identity, "沒有唯一 from→to，不能以路旁 device 的斜角推車行向")
            old_limit = device.get("tags", {}).get("maxspeed")
            if old_limit and tags.get("maxspeed") and old_limit != tags["maxspeed"]:
                combined = combined | {"maxspeed": ""}
                report.issue("osm", identity, f"device/relation 速限衝突 {old_limit}/{tags['maxspeed']}，只提醒")
            camera(device, identity, headings, combined)
            used.add(device["id"])
    for node in nodes.values():
        if node["id"] not in used and node.get("tags", {}).get("highway") == "speed_camera":
            identity = f"node-{node['id']}"
            camera(node, identity, _headings(node.get("tags", {}), report, identity), node.get("tags", {}))
    for element in elements:
        if element.get("type") != "node" and element.get("tags", {}).get("highway") == "speed_camera":
            report.issue("osm", f"{element['type']}-{element['id']}", "測速物件不是設備點，未猜中心座標")
    # 同一 device 的多個 relation 只合同行向；反向 relation 仍獨立。
    temporary = SourceReport()
    deduped = merge_sources([], result, temporary, radius=5)
    report.conflicts += temporary.conflicts
    return deduped


def comparison(cameras: list[Camera], official: list[Camera], radius=100) -> dict:
    matched, uncertain, missing = [], [], []
    official = [c for c in official if c.type not in ("mobile", "noise")]
    for camera in cameras:
        nearby = [c for c in official if haversine(c.lat, c.lon, camera.lat, camera.lon) <= radius]
        if any(direction_matches(old, camera) and not unknown_direction(old) and not unknown_direction(camera)
               for old in nearby):
            matched.append(camera)
        elif any(unknown_direction(old) or unknown_direction(camera) for old in nearby):
            uncertain.append(camera)
        else:
            missing.append(camera)
    return {"osmDirectionalPoints": len(cameras), "radiusMeters": radius, "directionMatched": len(matched),
            "distanceOverlapUnknownDirection": len(uncertain), "osmOnly": len(missing),
            "osmOnlyWithHeadingAndLimit": sum(c.heading is not None and c.speedLimit is not None for c in missing)}
