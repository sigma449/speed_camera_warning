#!/usr/bin/env python3
"""產生 App 內建的 road_lines.json（國道和白牌不走的道路的線形）。

用法：
  python3 build_road_lines.py                     # 從 OpenStreetMap 下載
  python3 build_road_lines.py --input osm.json    # 使用本機的 Overpass 結果

國道很少變動，所以結果直接放進 repo，不在每次建置時下載。有新路段通車時再手動重跑。
資料來源與授權：© OpenStreetMap 貢獻者，ODbL。
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from speedcam_data import road_lines  # noqa: E402

DEFAULT_OUTPUT = os.path.join(HERE, "..", "SpeedCam", "Resources", "road_lines.json")
DEFAULT_RESTRICTED = os.path.join(HERE, "manual", "white_plate_restricted.csv")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", help="本機的 Overpass JSON；沒指定就下載")
    parser.add_argument("--output", default=DEFAULT_OUTPUT)
    parser.add_argument("--restricted", default=DEFAULT_RESTRICTED)
    args = parser.parse_args(argv)

    if args.input:
        with open(args.input, encoding="utf-8") as f:
            elements = json.load(f)["elements"]
    else:
        print(f"下載 {road_lines.OVERPASS_URL}")
        elements = road_lines.fetch_elements()
    print(f"取得 {len(elements)} 筆道路")

    with open(args.restricted, encoding="utf-8") as f:
        restricted = road_lines.parse_restricted_names(f.read())

    data = road_lines.build_road_lines(elements, restricted, dt.date.today().isoformat())
    freeway_km = sum(road_lines.line_length_km([tuple(p) for p in line]) for line in data["freeways"])
    if freeway_km < road_lines.MIN_FREEWAY_KM:
        print(f"[錯誤] 國道只有 {freeway_km:.0f} km，少於 {road_lines.MIN_FREEWAY_KM} km，資料可能有問題，不寫入。")
        return 1

    with open(args.output, "w", encoding="utf-8", newline="\n") as f:
        f.write(road_lines.dumps(data))
    print(f"已寫入 {os.path.normpath(args.output)}（{os.path.getsize(args.output) / 1024:.0f} KB）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
