#!/usr/bin/env python3
"""產生 App 內建的 cameras.json。

用法：
  python3 build_cameras.py                       # 從政府開放資料下載
  python3 build_cameras.py --input raw.csv       # 使用本機檔案（可重複指定）
  python3 build_cameras.py --output path/to/cameras.json --min-count 500

資料來源與授權：內政部警政署「測速執法設置點」，政府資料開放授權條款－第1版。
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from speedcam_data import sources  # noqa: E402
from speedcam_data.normalize import NormalizeReport, normalize_rows  # noqa: E402
from speedcam_data import mileposts  # noqa: E402
from speedcam_data.sections import (  # noqa: E402
    apply_official_lengths, attach_paths, load_sections, manual_range_keys, uses_mileposts,
)
from speedcam_data import section_text  # noqa: E402

DEFAULT_OUTPUT = os.path.join(HERE, "..", "SpeedCam", "Resources", "cameras.json")
DEFAULT_SECTIONS = os.path.join(HERE, "manual", "sections.csv")
DEFAULT_EXTRA = os.path.join(HERE, "manual", "cameras_extra.csv")
DEFAULT_SECTIONS_TEXT = os.path.join(HERE, "manual", "sections_text.csv")
DEFAULT_SECTION_LENGTHS = os.path.join(HERE, "manual", "section_lengths.csv")
TEXT_SOURCE_ATTRIBUTION = "立法院議事附件：全國測速取締設置點清單（2026-05），補充開放資料未收錄的區間測速"
LENGTHS_ATTRIBUTION = "新北市政府警察局「區間平均速率執法設備設置地點一覽表」（1140919 修訂）：區間範圍與偵測長度"
TUNNEL_ATTRIBUTION = "隧道區間的位置：© OpenStreetMap 貢獻者（ODbL）"


class CachedMilepostIndex:
    """里程牌資料只下載一次，人工區間與自動區間共用。"""

    def __init__(self) -> None:
        self._index = None
        self._error: Exception | None = None

    def __call__(self, log=print):
        if self._index is None and self._error is None:
            try:
                self._index = mileposts.fetch_index(log=log)
            except Exception as exc:  # noqa: BLE001
                self._error = exc
        if self._error is not None:
            raise self._error
        return self._index


def auto_sections(rows: list[dict], text_rows: list[dict], manual_path: str, fetch_index, log=print) -> list[dict]:
    """從區間測速的文字描述自動產生區間（開放資料＋補充清單）。"""
    report = section_text.TextParseReport()
    segments = section_text.extract_from_rows(rows + text_rows, report)
    log(f"自動區間：從文字解析出 {len(segments)} 段；無法使用 {len(report.skipped)} 筆")
    for text, why in report.skipped:
        log(f"  略過：{why}")
    if not segments:
        return []
    try:
        index = fetch_index(log=log)
    except Exception as exc:  # noqa: BLE001
        log(f"[警告] 里程牌資料無法取得，自動區間全部略過：{exc}")
        return []
    return section_text.to_sections(segments, index.resolve, exclude=manual_range_keys(manual_path), log=log)


def add_paths(sections: list[dict], fetch_index, log=print) -> None:
    """用里程牌資料替區間加上沿路座標，讓 App 在地圖上順著路形畫。里程牌資料拿不到時就畫直線。"""
    if not any(s.get("road") for s in sections):
        return
    try:
        index = fetch_index(log=log)
    except Exception as exc:  # noqa: BLE001
        log(f"[警告] 里程牌資料無法取得，區間在地圖上會畫成直線：{exc}")
        return
    attach_paths(sections, index.path, log=log)


def build(rows: list[dict], sections: list[dict], now: dt.datetime | None = None,
          extra_sources: tuple = ()) -> tuple[dict, NormalizeReport]:
    now = now or dt.datetime.now(dt.timezone.utc)
    report = NormalizeReport()
    cameras = normalize_rows(rows, report)
    db = {
        "version": now.strftime("%Y-%m-%d"),
        "generatedAt": now.replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "sources": list(sources.ATTRIBUTION) + list(extra_sources),
        "cameras": [c.to_json() for c in cameras],
        "sections": sections,
    }
    return db, report


def unchanged(path: str, db: dict) -> bool:
    """照相點與區間都跟現有檔案相同時回傳 True（避免每週只因日期不同就產生變更）。"""
    try:
        with open(path, encoding="utf-8") as f:
            old = json.load(f)
    except (OSError, ValueError):
        return False
    return old.get("cameras") == db["cameras"] and old.get("sections") == db["sections"] \
        and old.get("sources") == db["sources"]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", action="append", help="本機原始資料（CSV 或 JSON），可重複指定")
    ap.add_argument("--output", default=DEFAULT_OUTPUT)
    ap.add_argument("--sections", default=DEFAULT_SECTIONS)
    ap.add_argument("--extra", default=DEFAULT_EXTRA, help="人工補充的照相點 CSV（欄位同原始資料）")
    ap.add_argument("--sections-text", default=DEFAULT_SECTIONS_TEXT,
                    help="補充的區間測速文字清單（只用來產生區間，不當作照相點）")
    ap.add_argument("--section-lengths", default=DEFAULT_SECTION_LENGTHS, help="警方公告的區間偵測長度")
    ap.add_argument("--no-auto-sections", action="store_true", help="不從文字自動產生區間")
    ap.add_argument("--min-count", type=int, default=0,
                    help="照相點少於這個數量就視為失敗（避免把空資料打包進 App）")
    args = ap.parse_args(argv)

    if args.input:
        rows = sources.read_local_rows(args.input)
    else:
        rows = sources.fetch_national_rows()
    if os.path.exists(args.extra):
        extra = sources.read_local_rows([args.extra])
        print(f"人工補充照相點 {len(extra)} 筆")
        rows += extra

    fetch_index = CachedMilepostIndex()
    sections = load_sections(args.sections, fetch_index=fetch_index)
    manual_count = len(sections)
    auto: list[dict] = []
    text_rows: list[dict] = []
    if not args.no_auto_sections:
        if os.path.exists(args.sections_text):
            text_rows = sources.read_local_rows([args.sections_text])
        auto = auto_sections(rows, text_rows, args.sections, fetch_index)
        sections = sections + auto
    add_paths(sections, fetch_index)
    official = apply_official_lengths(sections, args.section_lengths)
    extra: tuple = ()
    if sections and (auto or uses_mileposts(args.sections)):
        extra += (mileposts.ATTRIBUTION,)
    if any(s["id"].startswith("auto-") for s in auto) and text_rows:
        extra += (TEXT_SOURCE_ATTRIBUTION,)
    if official:
        extra += (LENGTHS_ATTRIBUTION,)
    if any("tunnel" in s["id"] for s in sections):
        extra += (TUNNEL_ATTRIBUTION,)
    db, report = build(rows, sections, extra_sources=extra)
    print(report.summary())
    diag = report.diagnostics()
    if diag:
        print(diag)
    print(f"區間測速 {len(sections)} 段（人工 {manual_count}、自動 {len(sections) - manual_count}）")

    if len(db["cameras"]) < args.min_count:
        print(f"[錯誤] 照相點只有 {len(db['cameras'])} 筆，少於 --min-count={args.min_count}", file=sys.stderr)
        return 1

    if unchanged(args.output, db):
        print("資料沒有變動，保留原本的檔案（不更新版本日期）")
        return 0

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(db, f, ensure_ascii=False, indent=1, sort_keys=False)
        f.write("\n")
    print(f"已寫入 {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
