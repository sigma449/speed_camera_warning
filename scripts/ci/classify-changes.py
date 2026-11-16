#!/usr/bin/env python3
"""純文件略過昂貴 job；未知路徑與所有跨層程式／資源變更保守跑完整 CI。"""
import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
CRITICAL = ("SpeedCam/", "SpeedCamWidgets/", "Shared/", "Packages/", "data-pipeline/",
            "scripts/ci/", ".github/workflows/")


def needs_full_ci(paths: list[str]) -> bool:
    if not paths:
        return True
    for path in paths:
        if path.startswith(CRITICAL) or path == "project.yml":
            return True
        if path.startswith("docs/") or path in ("README.md", "CLAUDE.md", "LICENSE"):
            continue
        return True
    return False


def capture_profile(paths: list[str]) -> str:
    return "full" if any(path.startswith(("SpeedCam/", "SpeedCamWidgets/", "Shared/", "scripts/ci/"))
                         or path == "project.yml" for path in paths) else "smoke"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--paths-json", type=Path)
    parser.add_argument("--full", action="store_true")
    args = parser.parse_args(argv)
    paths = []
    if args.paths_json:
        paths = json.loads(args.paths_json.read_text(encoding="utf-8"))
    elif args.base and set(args.base) != {"0"}:
        try:
            paths = subprocess.check_output(["git", "diff", "--name-only", "-z", args.base, args.head],
                                            cwd=ROOT).decode("utf-8").strip("\0").split("\0")
        except subprocess.CalledProcessError:
            print("::warning::無法取得完整差異；保守跑完整 CI")
    full = args.full or needs_full_ci(paths)
    value = f"full={'true' if full else 'false'}"
    screenshots = f"screenshots={'full' if args.full else capture_profile(paths)}"
    print(value)
    print("變更：" + "、".join(paths))
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write(value + "\n" + screenshots + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
