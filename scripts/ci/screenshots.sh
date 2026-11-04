#!/usr/bin/env bash
# 在 iPhone 模擬器上啟動 App 並截圖（展示模式與 Live Activity 預覽頁），
# 讓沒有 Mac 的情況下也能看到畫面。截圖存到 screenshots/。
set -euo pipefail

APP_PATH="${1:?用法：screenshots.sh path/to/SpeedCam.app}"
BUNDLE_ID="tw.speedcammap.app"
OUT="screenshots"
mkdir -p "${OUT}"

# 挑一台可用的 iPhone 模擬器（優先 iOS 26 以上）
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys, re
data = json.load(sys.stdin)["devices"]
best = None
for runtime, devices in data.items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    ver = (int(m.group(1)), int(m.group(2)))
    if ver < (26, 0):
        continue
    for d in devices:
        if d["name"].startswith("iPhone") and "Pro Max" not in d["name"]:
            if best is None or ver > best[0]:
                best = (ver, d["udid"], d["name"])
if best:
    print(best[1])
')
if [[ -z "${UDID}" ]]; then
  echo "::error::找不到 iOS 26 以上的 iPhone 模擬器"
  xcrun simctl list devices available
  exit 1
fi
echo "使用模擬器 ${UDID}"

xcrun simctl boot "${UDID}" || true
xcrun simctl bootstatus "${UDID}" -b
xcrun simctl status_bar "${UDID}" override --time "9:41" --batteryState charged --batteryLevel 100 || true
xcrun simctl install "${UDID}" "${APP_PATH}"
xcrun simctl privacy "${UDID}" grant location "${BUNDLE_ID}" || true
xcrun simctl privacy "${UDID}" grant location-always "${BUNDLE_ID}" || true
xcrun simctl location "${UDID}" set 25.0300,121.5650 || true

shot() {
  xcrun simctl io "${UDID}" screenshot "${OUT}/$1.png"
  echo "已截圖 $1"
}

# 1) Live Activity 預覽頁
xcrun simctl launch "${UDID}" "${BUNDLE_ID}" -gallery
sleep 6
shot "01-live-activity-gallery"
xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" || true

# 2) 展示模式：假軌跡以 62 km/h 往北開，600 m 處有速限 50 的測速照相，1.2 km 處進入區間
xcrun simctl launch "${UDID}" "${BUNDLE_ID}" -demo
sleep 20
shot "02-demo-pre-alert"
sleep 10
shot "03-demo-near-overspeed"
sleep 50
shot "04-demo-section-countdown"
xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" || true

# 3) 一般啟動（使用 App 內建的真實資料；預設會自動開始巡航）
xcrun simctl launch "${UDID}" "${BUNDLE_ID}"
sleep 8
shot "05-normal-launch"
xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" || true

# 4) 搜尋候選：模擬器預設語言，以及指定繁體中文（確認地圖與搜尋的語言設定有效）
xcrun simctl launch "${UDID}" "${BUNDLE_ID}" -search "台北車站"
sleep 10
shot "06-search-suggestions-default-language"
xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" || true

xcrun simctl launch "${UDID}" "${BUNDLE_ID}" -search "台北車站" -AppleLanguages "(zh-Hant-TW)"
sleep 10
shot "07-search-suggestions-zh-Hant"
xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" || true

xcrun simctl launch "${UDID}" "${BUNDLE_ID}" -search "Taipei Main Station" -AppleLanguages "(en)"
sleep 10
shot "08-search-suggestions-en"

ls -la "${OUT}"
