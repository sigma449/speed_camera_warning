"""在 Docker 的原生 volume 編譯 Swift；所有參數原樣交給 swift test。"""
import hashlib
import os
from pathlib import Path
import subprocess
import sys


def main(arguments):
    root = Path(__file__).resolve().parents[1]
    package = root / "Packages" / "SpeedCamCore"
    resources = root / "SpeedCam" / "Resources"
    checkout = hashlib.sha256(os.fsencode(str(root))).hexdigest()[:12]
    volume = f"speedcam-swift62-build-{checkout}"
    command = [
        "docker", "run", "--rm",
        "-v", f"{package}:/pkg",
        "-v", f"{resources}:/SpeedCam/Resources:ro",
        "--mount", f"type=volume,source={volume},target=/pkg/.build,volume-nocopy",
        "-w", "/pkg", "swift:6.2-noble", "swift", "test",
        *arguments,
    ]
    return subprocess.call(command, env=dict(os.environ, MSYS_NO_PATHCONV="1"))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
