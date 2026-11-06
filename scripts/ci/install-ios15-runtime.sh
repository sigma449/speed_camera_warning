#!/usr/bin/env bash
# 安裝 iOS 15.5 模擬器（Apple 官方 CDN，不用登入）。
# 這是舊格式的安裝包，預設會裝到 Xcode 裡面，所以要改成 CoreSimulator 的位置再安裝。
set -euo pipefail

URL="https://devimages-cdn.apple.com/downloads/xcode/simulators/com.apple.pkg.iPhoneSimulatorSDK15_5-15.5.1.1653527639.dmg"
DESTINATION="/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 15.5.simruntime"
WORK="${RUNNER_TEMP:-/tmp}/ios15-runtime"
MOUNT="${WORK}/mount"

mkdir -p "${WORK}" "${MOUNT}"
echo "下載 iOS 15.5 模擬器"
curl -fsSL --retry 3 -o "${WORK}/runtime.dmg" "${URL}"
ls -lh "${WORK}/runtime.dmg"

hdiutil attach "${WORK}/runtime.dmg" -mountpoint "${MOUNT}" -nobrowse -quiet
PKG=$(ls "${MOUNT}"/*.pkg | head -1)
echo "安裝包：${PKG}"

pkgutil --expand "${PKG}" "${WORK}/expanded"
python3 - "${WORK}/expanded/PackageInfo" "${DESTINATION}" <<'PY'
import re, sys
path, destination = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
attribute = f'install-location="{destination}"'
if re.search(r'install-location="[^"]*"', text):
    text = re.sub(r'install-location="[^"]*"', attribute, text, count=1)
else:
    text = text.replace("<pkg-info", f"<pkg-info {attribute}", 1)
open(path, "w", encoding="utf-8").write(text)
PY
pkgutil --flatten "${WORK}/expanded" "${WORK}/fixed.pkg"
sudo installer -pkg "${WORK}/fixed.pkg" -target /
hdiutil detach "${MOUNT}" -quiet || true

# CoreSimulator 要一點時間才會發現新的版本
for _ in $(seq 1 30); do
  if xcrun simctl list runtimes | grep -q "iOS 15.5"; then break; fi
  sleep 5
done
xcrun simctl list runtimes
xcrun simctl list runtimes | grep -q "iOS 15.5" || { echo "::error::安裝後找不到 iOS 15.5 模擬器"; exit 1; }
