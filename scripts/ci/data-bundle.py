#!/usr/bin/env python3
"""同一 commit 的不可變 CI 資料包；消費端不下載資料，也不退回 repo 舊資料。"""
from __future__ import annotations

import argparse
from collections import Counter
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]
REQUIRED_SECTIONS = {
    *(f"beiyi-{number}-{direction}" for number in range(1, 5) for direction in ("f", "r")),
    "tai64-zhonghe-east", "tai64-zhonghe-west",
    "ziqiang-tunnel-f", "ziqiang-tunnel-r", "xinhai-tunnel-f", "xinhai-tunnel-r",
    "ntpc-huanhe-f", "ntpc-huanhe-r",
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def release_blockers(db: dict) -> list[str]:
    blockers = []
    status = db.get("buildStatus", {})
    if status.get("mode") != "online" or not status.get("supplemental") or not status.get("autoSections"):
        blockers.append("不是本輪完整的線上多來源建置")
    if status.get("mileposts", {}).get("status") != "available":
        blockers.append("必要來源 7040 無法取得；不能發布缺里程區間的降級資料")
    if len(db["cameras"]) < 500:
        blockers.append(f"照相點僅 {len(db['cameras'])}，低於發布下限 500")
    if len(db["sections"]) < 70:
        blockers.append(f"方向別區間僅 {len(db['sections'])}，低於發布下限 70（已核完整版本為 79／82）")
    missing = REQUIRED_SECTIONS - {section["id"] for section in db["sections"]}
    if missing:
        blockers.append("缺少必要雙向區間：" + "、".join(sorted(missing)))
    if not db.get("sourceReport", {}).get("sources", {}).get("7320"):
        blockers.append("缺少當輪 7320 來源報告")
    for key in ("cameras", "sections"):
        ids = [row["id"] for row in db[key]]
        if len(set(ids)) != len(ids):
            blockers.append(f"{key} 有重複 ID")
    return blockers


def create_manifest(directory: Path, commit: str) -> dict:
    db = json.loads((directory / "cameras.json").read_text(encoding="utf-8"))
    log = (directory / "data-build.log").read_text(encoding="utf-8")
    if not log.strip() or not db.get("sources"):
        raise ValueError("資料包缺少本輪完整建置 log 或來源署名")
    warnings = [line for line in log.splitlines() if "[警告]" in line]
    write_json(directory / "sources.json", {
        "attributions": db["sources"], "report": db.get("sourceReport", {}),
        "buildStatus": db.get("buildStatus", {}), "warnings": warnings,
    })
    blockers = release_blockers(db)
    manifest = {
        "schemaVersion": 1, "policyVersion": 1, "commit": commit,
        "createdAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "dataGeneratedAt": db.get("generatedAt"),
        "cameraCount": len(db["cameras"]), "sectionCount": len(db["sections"]),
        "cameraTypes": dict(sorted(Counter(camera["type"] for camera in db["cameras"]).items())),
        "completeness": "degraded" if blockers else "complete",
        "sourceHealth": "warnings" if warnings else "no-warnings",
        "releaseEligible": not blockers, "releaseBlockers": blockers,
        "hashes": {name: sha256(directory / name) for name in ("cameras.json", "sources.json", "data-build.log")},
    }
    write_json(directory / "manifest.json", manifest)
    return manifest


def run_builder(directory: Path) -> int:
    command = [sys.executable, "-I", "-X", "utf8", str(ROOT / "data-pipeline" / "build_cameras.py"),
               "--output", str(directory / "cameras.json"), "--min-count", "500"]
    with (directory / "data-build.log").open("w", encoding="utf-8") as log:
        with subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, encoding="utf-8", errors="replace", bufsize=1) as process:
            for line in process.stdout:
                print(line, end="", flush=True)
                log.write(line)
            return process.wait()


def verify(directory: Path, commit: str, manifest_sha: str, release: bool) -> dict:
    if sha256(directory / "manifest.json") != manifest_sha:
        raise ValueError("manifest SHA-256 不符；拒絕替換或不同輪的資料包")
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("schemaVersion") != 1 or manifest.get("policyVersion") != 1 or manifest.get("commit") != commit:
        raise ValueError("資料包版本或 commit 不符")
    for name in ("cameras.json", "sources.json", "data-build.log"):
        if sha256(directory / name) != manifest["hashes"][name]:
            raise ValueError(f"{name} SHA-256 不符")
    db = json.loads((directory / "cameras.json").read_text(encoding="utf-8"))
    blockers = release_blockers(db)
    if manifest["releaseEligible"] != (not blockers) or manifest["releaseBlockers"] != blockers:
        raise ValueError("資料完整性判定與 manifest 不符")
    if manifest["cameraCount"] != len(db["cameras"]) or manifest["sectionCount"] != len(db["sections"]):
        raise ValueError("資料筆數與 manifest 不符")
    if release and blockers:
        raise ValueError("IPA 發布閘門拒絕：" + "；".join(blockers))
    print(f"資料 SHA-256={manifest['hashes']['cameras.json']}；"
          f"{manifest['cameraCount']} 點／{manifest['sectionCount']} 段；{manifest['completeness']}；"
          f"來源狀態={manifest['sourceHealth']}")
    if blockers:
        print("::warning::僅可降級測試，不可發布 IPA：" + "；".join(blockers))
    return manifest


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "verify"))
    parser.add_argument("--directory", type=Path, default=ROOT / "build" / "ci-data")
    parser.add_argument("--commit", required=True)
    parser.add_argument("--manifest-sha")
    parser.add_argument("--release", action="store_true")
    parser.add_argument("--install", type=Path)
    parser.add_argument("--app-data", type=Path)
    parser.add_argument("--ipa", type=Path)
    args = parser.parse_args(argv)
    try:
        if not re.fullmatch(r"[a-f0-9]{40}", args.commit):
            raise ValueError("必須指定完整的 40 位 commit")
        if args.command == "prepare":
            actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
            if actual != args.commit:
                raise ValueError("checkout commit 與指定 commit 不符")
            args.directory.mkdir(parents=True, exist_ok=True)
            for name in ("cameras.json", "sources.json", "manifest.json"):
                (args.directory / name).unlink(missing_ok=True)
            status = run_builder(args.directory)
            if status:
                print(f"::error::本輪資料建置失敗（exit {status}）；不使用舊資料", file=sys.stderr)
                return 1
            create_manifest(args.directory, args.commit)
            args.manifest_sha = sha256(args.directory / "manifest.json")
            if os.environ.get("GITHUB_OUTPUT"):
                with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
                    output.write(f"manifest-sha={args.manifest_sha}\n"
                                 f"data-sha={sha256(args.directory / 'cameras.json')}\n")
        if not args.manifest_sha:
            raise ValueError("消費資料時必須提供準備 job 的 manifest SHA-256")
        manifest = verify(args.directory, args.commit, args.manifest_sha, args.release or args.ipa is not None)
        if manifest["sourceHealth"] == "warnings":
            print("::warning::來源有失聯、回退或資料警告；完整內容見 sources.json 與 data-build.log")
        if args.install:
            args.install.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(args.directory / "cameras.json", args.install)
        expected = manifest["hashes"]["cameras.json"]
        if args.app_data and sha256(args.app_data) != expected:
            raise ValueError("已建置 App 的 cameras.json 與測試資料不同")
        if args.ipa:
            with zipfile.ZipFile(args.ipa) as archive:
                packaged = archive.read("Payload/SpeedCam.app/cameras.json")
            if hashlib.sha256(packaged).hexdigest() != expected:
                raise ValueError("IPA 內的 cameras.json 與測試資料不同")
            write_json(args.ipa.with_suffix(".manifest.json"), {
                "commit": args.commit, "dataSHA256": expected,
                "manifestSHA256": args.manifest_sha, "ipaSHA256": sha256(args.ipa),
            })
        return 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
