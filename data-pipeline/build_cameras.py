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
from speedcam_data.sections import load_sections  # noqa: E402

DEFAULT_OUTPUT = os.path.join(HERE, "..", "SpeedCam", "Resources", "cameras.json")
DEFAULT_SECTIONS = os.path.join(HERE, "manual", "sections.csv")
DEFAULT_EXTRA = os.path.join(HERE, "manual", "cameras_extra.csv")


def build(rows: list[dict], sections: list[dict], now: dt.datetime | None = None) -> tuple[dict, NormalizeReport]:
    now = now or dt.datetime.now(dt.timezone.utc)
    report = NormalizeReport()
    cameras = normalize_rows(rows, report)
    db = {
        "version": now.strftime("%Y-%m-%d"),
        "generatedAt": now.replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "sources": list(sources.ATTRIBUTION),
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

    sections = load_sections(args.sections)
    db, report = build(rows, sections)
    print(report.summary())
    diag = report.diagnostics()
    if diag:
        print(diag)
    print(f"區間測速 {len(sections)} 段")

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
    print(f"已寫入 {os.path.relpath(args.output)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
