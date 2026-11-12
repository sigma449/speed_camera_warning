"""多來源的方向／功能去重與可追溯建置報告，不改寫主來源的速限或取締方向。"""
from __future__ import annotations

from dataclasses import dataclass, field
import re
import unicodedata

from .normalize import Camera
from .sections import haversine


@dataclass
class SourceReport:
    counts: dict[str, dict[str, int]] = field(default_factory=dict)
    issues: list[str] = field(default_factory=list)
    conflicts: list[str] = field(default_factory=list)
    mobile_directions: list[dict] = field(default_factory=list)

    def count(self, source: str, key: str, amount: int = 1) -> None:
        values = self.counts.setdefault(source, {"downloaded": 0, "usable": 0, "added": 0, "merged": 0})
        values[key] = values.get(key, 0) + amount

    def issue(self, source: str, row: str, reason: str) -> None:
        self.issues.append(f"{source}｜{row}｜{reason}")

    def print(self, cameras: list[Camera], log=print) -> None:
        log("多來源建置報告（讀入原始列可能含重複表頭／空列；淨新增依下列來源順序）")
        for source, n in self.counts.items():
            log(f"  {source}：原始 {n['downloaded']}，可定位 {n['usable']}，"
                f"淨新增 {n['added']}，重疊 {n['merged']}")
            if any(key in n for key in ("directional", "bidirectional", "unresolved")):
                log(f"    熱點行向：單向 {n.get('directional', 0)}，"
                    f"明載雙向 {n.get('bidirectional', 0)}，無法唯一判向 {n.get('unresolved', 0)}")
        for row in self.mobile_directions:
            log(f"  [熱點行向] {row['source']}｜{row['district']} {row['address']}｜{row['status']}"
                f"｜heading={row['heading']} axis={row['axis']}｜{row['evidence']}")
        types = dict.fromkeys(("fixed", "redLight", "redLightSpeed", "section", "tech", "mobile", "noise"), 0)
        for camera in cameras:
            types[camera.type] = types.get(camera.type, 0) + 1
        log("各類型：" + "、".join(f"{key}={value}" for key, value in sorted(types.items())))
        log(f"來源衝突 {len(self.conflicts)} 筆（保留較優先來源，不自動選較小速限）")
        for conflict in self.conflicts:
            log(f"  [衝突] {conflict}")
        log(f"異常／未採用／無法定位 {len(self.issues)} 筆")
        for issue in self.issues:
            log(f"  [待查] {issue}")


def angle_difference(a: float, b: float) -> float:
    return abs((a - b + 180) % 360 - 180)


def direction_matches(a: Camera, b: Camera) -> bool:
    """有向與軸向必須真正覆蓋；完全未知只和同樣未知配對，不宣稱方向已確認。"""
    if a.heading is not None and b.heading is not None:
        return angle_difference(a.heading, b.heading) <= 45
    if a.heading is None and b.heading is None:
        if a.axis is None or b.axis is None:
            return a.axis is None and b.axis is None
        return min(angle_difference(a.axis, b.axis), angle_difference(a.axis + 180, b.axis)) <= 45
    if a.axis is not None and b.heading is not None:
        return min(angle_difference(a.axis, b.heading), angle_difference(a.axis + 180, b.heading)) <= 45
    return False


def opposite(a: Camera, b: Camera) -> bool:
    return a.heading is not None and b.heading is not None and angle_difference(a.heading, b.heading) > 90


def unknown_direction(camera: Camera) -> bool:
    return camera.heading is None and camera.axis is None


def _address(camera: Camera) -> str:
    text = unicodedata.normalize("NFKC", camera.address).replace("臺", "台")
    for prefix in (camera.city, camera.district):
        if prefix:
            text = text.replace(prefix.replace("臺", "台"), "")
    return re.sub(r"[\s，,、()（）]", "", text)


def _same_address(a: Camera, b: Camera) -> bool:
    return bool(a.city and b.city and a.city.replace("臺", "台") == b.city.replace("臺", "台")
                and len(_address(a)) >= 5 and _address(a) == _address(b))


def _same_kind(a: Camera, b: Camera) -> bool:
    if a.level in ("elevated", "surface") and b.level in ("elevated", "surface") and a.level != b.level:
        return False
    if "noise" in (a.type, b.type):
        return a.type == b.type
    if "mobile" in (a.type, b.type):
        return a.type == b.type
    return True


def _merge_items(old: Camera, new: Camera) -> None:
    if not new.enforcementItems:
        return
    inferred = {"fixed": "超速", "redLightSpeed": "超速、闖紅燈", "redLight": "闖紅燈", "section": "區間測速"}
    original = old.enforcementItems or inferred.get(old.type, "")
    if new.enforcementItems not in original:
        old.enforcementItems = "、".join(x for x in (original, new.enforcementItems) if x)
    else:
        old.enforcementItems = original
    if new.conditions and new.conditions not in (old.conditions or ""):
        old.conditions = "；".join(x for x in (old.conditions, new.conditions) if x)
    if new.type == "tech" and old.type != "section":
        old.type = "tech"


def merge_sources(base: list[Camera], additions: list[Camera], report: SourceReport,
                  radius: float = 100) -> list[Camera]:
    result = list(base)
    for new in additions:
        source = new.source or "unknown"
        nearby = [(old, haversine(old.lat, old.lon, new.lat, new.lon)) for old in result]
        # 公告熱點不能和同位置的實際測速設備重複提醒；反向設備仍不能蓋掉熱點。
        if new.type == "mobile":
            fixed = [(old, distance) for old, distance in nearby
                     if old.type not in ("mobile", "noise") and old.enforces_speed and distance <= 150
                     and (direction_matches(old, new) or unknown_direction(old) or unknown_direction(new))]
            if fixed:
                old, distance = min(fixed, key=lambda item: item[1])
                report.issue(source, new.sourceID or new.id,
                             f"距固定測速 {old.source or '主來源'}/{old.id} {distance:.1f} m，固定優先，熱點不另新增")
                report.count(source, "merged")
                continue
        matches = [(old, distance) for old, distance in nearby
                   if _same_kind(old, new) and direction_matches(old, new)
                   and (distance <= (150 if new.type == "mobile" else 5 if source == old.source == "osm" else radius)
                        or source != "osm" and _same_address(old, new))]
        # OSM 沒有方向時只作距離重疊，不能冒稱已驗證同行向；不另造一支重複相機。
        uncertain = [(old, distance) for old, distance in nearby
                     if new.source == "osm" and old.source != "osm" and _same_kind(old, new)
                     and distance <= radius and not opposite(old, new)
                     and (unknown_direction(old) or unknown_direction(new))]
        if not matches and uncertain:
            old, distance = min(uncertain, key=lambda item: item[1])
            report.issue(source, new.sourceID or new.id,
                         f"距官方 {old.id} {distance:.1f} m，方向不足，按距離重疊不新增；未確認同行向")
            report.count(source, "merged")
            continue
        if matches:
            old, distance = min(matches, key=lambda item: item[1])
            if ((old.lat, old.lon) != (new.lat, new.lon) or old.speedLimit != new.speedLimit
                    or old.heading != new.heading or old.axis != new.axis):
                report.conflicts.append(f"{source}/{new.sourceID} {new.address} → {old.source or '主來源'}/{old.id}"
                                        f"｜距離 {distance:.1f} m｜方向 {old.heading}/{old.axis} vs {new.heading}/{new.axis}"
                                        f"｜速限 {old.speedLimit} vs {new.speedLimit}")
            # OSM 不覆寫官方內容，含未知／相反速限；地方同址只補取締項目與條件。
            if source != "osm":
                _merge_items(old, new)
            report.count(source, "merged")
            continue
        for old, distance in nearby:
            if distance <= 30 and _same_kind(old, new) and not direction_matches(old, new):
                report.conflicts.append(f"{source}/{new.sourceID} {new.address} 與 {old.id} 相距 {distance:.1f} m"
                                        f"｜方向不同／未知，保留分列 {old.heading}/{old.axis} vs {new.heading}/{new.axis}")
        result.append(new)
        report.count(source, "added")
    return sorted(result, key=lambda camera: camera.id)
