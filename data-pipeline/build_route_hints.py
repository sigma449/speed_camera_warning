#!/usr/bin/env python3
"""將人工核實的定向分支提示轉成 App 內建 JSON；不連網、不猜缺少的欄位。"""
from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from speedcam_data.sections import haversine

DEFAULT_INPUT = HERE / "manual" / "route_hints.csv"
DEFAULT_OUTPUT = HERE.parent / "SpeedCam" / "Resources" / "route_hints.json"


def build(path: Path) -> list[dict]:
    hints = []
    ids = set()
    with path.open(encoding="utf-8-sig", newline="") as stream:
        for number, row in enumerate(csv.DictReader(stream), 2):
            try:
                hint = {
                    "id": row["id"].strip(),
                    "point": {"lat": float(row["lat"]), "lon": float(row["lon"])},
                    "heading": float(row["heading"]),
                    "confirmation": {"lat": float(row["confirmation_lat"]), "lon": float(row["confirmation_lon"])},
                    "radius": float(row["radius_m"]),
                    "shortText": row["short_text"].strip(),
                    "instruction": row["instruction"].strip(),
                    "source": row["source"].strip(),
                    "replaces": [part.strip() for part in row.get("replace_text", "").split("|")] if row.get("replace_text", "").strip() else [],
                }
                if not hint["id"] or hint["id"] in ids:
                    raise ValueError("id 空白或重複")
                for point in (hint["point"], hint["confirmation"]):
                    if not (21.8 <= point["lat"] <= 25.4 and 119.3 <= point["lon"] <= 122.1):
                        raise ValueError("座標不在台灣本島範圍")
                if not (math.isfinite(hint["heading"]) and 0 <= hint["heading"] < 360):
                    raise ValueError("行向必須為0至360度（不含360）")
                if not 0 < hint["radius"] <= 30:
                    raise ValueError("匹配半徑必須大於0且不超過30m")
                if haversine(hint["point"]["lat"], hint["point"]["lon"],
                             hint["confirmation"]["lat"], hint["confirmation"]["lon"]) < 20:
                    raise ValueError("後續點必須與提示點相距至少20m")
                if not all(hint[key] for key in ("shortText", "instruction", "source")):
                    raise ValueError("缺少畫面短句、語音或來源")
                if not all(hint["replaces"]):
                    raise ValueError("要取代的 Apple 原文片段不可空白")
            except (KeyError, TypeError, ValueError) as exc:
                raise ValueError(f"{path.name} 第{number}列：{exc}") from exc
            ids.add(hint["id"])
            hints.append(hint)
    if not hints:
        raise ValueError(f"{path.name} 沒有任何導航提示")
    return hints


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args(argv)
    try:
        hints = build(args.input)
        args.output.write_text(json.dumps(hints, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except (OSError, ValueError) as exc:
        print(f"[失敗] 導航提示建置失敗：{exc}", file=sys.stderr)
        return 1
    print(f"已產生 {len(hints)} 筆導航提示：{args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
