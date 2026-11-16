#!/usr/bin/env python3
"""留下每個 job 的證據；彙總時 skipped、缺報告或任一檢查失敗都不是完整驗收通過。"""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
FULL_JOBS = ("data", "tests", "ios26", "ios15", "replay-1108", "replay-1107", "replay-tunnels", "ipa")
FULL_RECORDS = ("core-tests", "pipeline-tests", "ios26", "ios15",
                "replay-1108", "replay-1107", "replay-tunnels", "ipa")


def emit_summary(text):
    print(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as output:
            output.write(text + "\n")


def record(args):
    if not re.fullmatch(r"[a-z0-9-]+", args.job):
        raise ValueError("無效工作名稱")
    directory = Path("build/evidence") / args.job
    directory.mkdir(parents=True, exist_ok=True)
    profile = os.environ.get("CAPTURE_SCENARIOS")
    effective = "smoke（iOS 15 無 Live Activity）" if args.job == "ios15" and profile == "gallery" else profile
    report = {
        "job": args.job, "status": args.status, "commit": os.environ["COMMIT"],
        "manifestSHA256": os.environ.get("MANIFEST_SHA", ""),
        "acceptance": os.environ.get("ACCEPTANCE") == "true",
        "screenshots": profile, "effectiveScreenshots": effective,
        "screenshotFiles": sorted(path.name for path in Path("screenshots").glob("*.png")),
        "pythonVersion": platform.python_version(),
    }
    (directory / "job-result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    emit_summary(f"**{args.job}**：{args.status}；commit `{report['commit']}`；"
                 f"manifest `{report['manifestSHA256'] or '此工作不使用相機資料'}`。"
                 + ("單獨打包不是完整驗收通過。" if args.job == "ipa" and not report["acceptance"] else ""))
    return 0


def summary(args):
    needs = json.loads(os.environ["NEEDS_JSON"])
    commit = os.environ["COMMIT"]
    expected_hash = os.environ.get("MANIFEST_SHA", "")
    docs_only = args.scope == "ci" and needs.get("changes", {}).get("outputs", {}).get("full") == "false"
    required = ("changes",) if docs_only else FULL_JOBS if args.scope == "acceptance" else ("changes", "data", "tests", "ios-build")
    errors = [f"{job}={needs.get(job, {}).get('result', 'missing')}"
              for job in required if needs.get(job, {}).get("result") != "success"]
    lines = [f"## {'完整驗收' if args.scope == 'acceptance' else 'CI'}", f"commit：`{commit}`",
             "", "| Job | 結果 |", "|---|---|"]
    lines += [f"| {job} | {value.get('result', 'missing')} |" for job, value in needs.items()]
    bundle = args.directory / "ci-data"
    manifest = None
    if not docs_only:
        result = subprocess.run([sys.executable, str(ROOT / "scripts/ci/data-bundle.py"), "verify",
                                 "--directory", str(bundle), "--commit", commit, "--manifest-sha", expected_hash, "--release"],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        args.directory.mkdir(parents=True, exist_ok=True)
        (args.directory / "bundle-verification.log").write_bytes(result.stdout)
        if result.returncode:
            errors.append("資料包驗證失敗或未產生")
        else:
            manifest = json.loads((bundle / "manifest.json").read_text(encoding="utf-8"))
            lines += ["", f"資料：**{manifest['cameraCount']} 點／{manifest['sectionCount']} 個方向別區間**；"
                      f"{manifest['completeness']}；來源狀態 `{manifest['sourceHealth']}`。",
                      f"資料 SHA-256：`{manifest['hashes']['cameras.json']}`",
                      "各類型：" + "、".join(f"{key}={value}" for key, value in manifest["cameraTypes"].items()),
                      "來源失聯／快照回退／資料警告請看 `ci-data/sources.json`，不代表所有來源都是即時資料。"]
        expected_records = FULL_RECORDS if args.scope == "acceptance" else ("core-tests", "pipeline-tests", "ios26")
        records = {}
        for path in args.directory.rglob("job-result.json"):
            row = json.loads(path.read_text(encoding="utf-8"))
            name = row["job"]
            if name in records:
                errors.append(f"{name} 有重複結果")
            records[name] = row
        for name in expected_records:
            row = records.get(name, {})
            valid = row.get("status") == "success" and row.get("commit") == commit and row.get("manifestSHA256") == expected_hash
            if args.scope == "acceptance" and name not in ("core-tests", "pipeline-tests"):
                valid = valid and row.get("acceptance") is True
            if not valid:
                errors.append(f"{name} 缺少同 commit／資料的成功證據")
            if name in ("core-tests", "pipeline-tests"):
                lines.append(f"{name}：{row.get('status', '未執行／缺少證據')}")
            if name in ("ios26", "ios15"):
                lines.append(f"{name} 截圖情境：`{row.get('effectiveScreenshots', row.get('screenshots', '未執行'))}`；"
                             f"PNG {len(row.get('screenshotFiles', []))} 張；產圖不等於目視／手勢驗收。")
    conclusions = {}
    if args.scope == "acceptance":
        for suite in ("1108", "1107", "tunnels"):
            matches = []
            for path in args.directory.rglob("checker-result.json"):
                report = json.loads(path.read_text(encoding="utf-8"))
                if report.get("suite") == suite:
                    matches.append(report)
            passed = (len(matches) == 1 and matches[0].get("conclusion") == "success"
                      and matches[0].get("producerExit") == 0 and matches[0].get("errors") == [])
            conclusions[suite] = "success" if passed else "failure／未執行／缺少唯一報告"
            lines.append(f"檢查器 {suite}：**{conclusions[suite]}**")
            if not passed:
                errors.append(f"{suite} 檢查器未通過")
        ipa_reports = list(args.directory.rglob("ipa-manifest.json"))
        ipa = json.loads(ipa_reports[0].read_text(encoding="utf-8")) if len(ipa_reports) == 1 else {}
        if not (manifest and ipa.get("commit") == commit and ipa.get("manifestSHA256") == expected_hash
                and ipa.get("dataSHA256") == manifest["hashes"]["cameras.json"]
                and re.fullmatch(r"[a-f0-9]{64}", ipa.get("ipaSHA256", ""))):
            errors.append("缺少唯一同 commit／同資料的 IPA 指紋證據")
    passed = not errors
    if docs_only:
        lines += ["", "本次只有文件變更，未啟動資料下載、Swift／Python 或 macOS 工作。"]
    if args.scope == "acceptance":
        lines += ["", f"IPA artifact：**{'SpeedCam-ipa' if passed else '無可驗收 IPA'}**",
                  f"結論：**{'通過' if passed else '未通過'}**；不是實機語音、手勢或 CarPlay 驗收。"]
    lines += ["", *("失敗：" + error for error in errors)]
    args.directory.mkdir(parents=True, exist_ok=True)
    (args.directory / "acceptance-result.json").write_text(json.dumps({
        "commit": commit, "manifestSHA256": expected_hash, "conclusion": "success" if passed else "failure",
        "checks": conclusions, "errors": errors, "data": manifest,
        "ipaArtifact": "SpeedCam-ipa" if passed and args.scope == "acceptance" else None,
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    emit_summary("\n".join(lines))
    return 0 if passed else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    job = subparsers.add_parser("record")
    job.add_argument("--job", required=True)
    job.add_argument("--status", required=True, choices=("success", "failure", "cancelled", "skipped"))
    aggregate = subparsers.add_parser("summary")
    aggregate.add_argument("--scope", choices=("acceptance", "ci"), required=True)
    aggregate.add_argument("--directory", type=Path, default=Path("build/summary"))
    args = parser.parse_args(argv)
    try:
        return record(args) if args.command == "record" else summary(args)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"::error::無法產生驗收結果：{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
