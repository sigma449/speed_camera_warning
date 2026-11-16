#!/usr/bin/env python3
"""從本輪已驗證資料包產生多來源更新 PR 說明。"""
import argparse
import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "data-pipeline"))
from build_cameras import unchanged


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=Path("build/ci-data"))
    parser.add_argument("--output", type=Path, default=Path("build/data-pr-body.md"))
    parser.add_argument("--install", type=Path)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--manifest-sha", required=True)
    args = parser.parse_args(argv)
    result = subprocess.run([sys.executable, str(Path(__file__).with_name("data-bundle.py")), "verify",
                             "--directory", str(args.directory), "--commit", args.commit,
                             "--manifest-sha", args.manifest_sha, "--release"])
    if result.returncode:
        return result.returncode
    if args.install:
        data = (args.directory / "cameras.json").read_bytes()
        if unchanged(str(args.install), json.loads(data)):
            print("資料內容、來源與建置狀態未變，保留 repo 日期，不寫入僅日期變更。")
        else:
            args.install.parent.mkdir(parents=True, exist_ok=True)
            args.install.write_bytes(data)
    manifest = json.loads((args.directory / "manifest.json").read_text(encoding="utf-8"))
    sources = json.loads((args.directory / "sources.json").read_text(encoding="utf-8"))
    lines = ["由「Refresh camera data」流程產生；包含官方、地方公告、OSM 與人工補充，不是只有警政署。",
             f"建置 commit：`{args.commit}`；**{manifest['cameraCount']} 點／{manifest['sectionCount']} 個方向別區間**。",
             f"資料 SHA-256：`{manifest['hashes']['cameras.json']}`；來源狀態：`{manifest['sourceHealth']}`。",
             "", "| 來源 | 原始列 | 可用 | 淨增 | 合併 |", "|---|---:|---:|---:|---:|"]
    for source, counts in sorted(sources["report"]["sources"].items()):
        lines.append(f"| {source} | {counts.get('downloaded', 0)} | {counts.get('usable', 0)} | "
                     f"{counts.get('added', 0)} | {counts.get('merged', 0)} |")
    lines += ["", "### 來源與授權", *("- " + source for source in sources["attributions"]),
              "", "OSM 及融合衍生資料庫依 ODbL 分享；不能將全部來源統稱為政府資料開放授權。"
              "Build IPA 的 `SpeedCam-data` 會附同份機讀資料、來源與處理程式。",
              "", "### 本輪警告／回退"]
    lines += ["- " + line for line in sources["warnings"][:30]] or ["無來源警告。"]
    if len(sources["warnings"]) > 30:
        lines.append(f"另有 {len(sources['warnings']) - 30} 條，見本次 `ci-data` artifact 的 sources.json／data-build.log。")
    lines += ["", "來源使用小型快照不代表即時；必要資料降級不會開此發布用 PR。"
              "合併後須另跑完整驗收，不能把此資料更新當成 iOS／實機驗收通過。"]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
