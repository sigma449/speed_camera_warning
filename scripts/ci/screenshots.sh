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

# 一律用 --terminate-running-process 重新啟動：App 巡航中被結束時，iOS 會在背景把它重新叫起來（背景定位），
# 這時直接 launch 只會把背景那個帶到前景，啟動參數不會生效。
shot() {
  xcrun simctl io "${UDID}" screenshot "${OUT}/$1.png"
  echo "已截圖 $1"
}

# 1) Live Activity 預覽頁
xcrun simctl launch --terminate-running-process "${UDID}" "${BUNDLE_ID}" -gallery
sleep 10
shot "01-live-activity-gallery"
xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" || true

# 2) 展示模式：假軌跡以 62 km/h 往北開，600 m 處有速限 50 的測速照相，1.2 km 處進入區間
xcrun simctl launch --terminate-running-process "${UDID}" "${BUNDLE_ID}" -demo
sleep 20
shot "02-demo-pre-alert"
sleep 10
shot "03-demo-near-overspeed"
sleep 50
shot "04-demo-section-countdown"
xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" || true

# 3) 一般啟動（使用 App 內建的真實資料；預設會自動開始巡航）
xcrun simctl launch --terminate-running-process "${UDID}" "${BUNDLE_ID}"
sleep 8
shot "05-normal-launch"
xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" || true

# 4) 搜尋候選：模擬器預設語言，以及指定繁體中文（確認地圖與搜尋的語言設定有效）
xcrun simctl launch --terminate-running-process "${UDID}" "${BUNDLE_ID}" -search "台北車站"
sleep 14
shot "06-search-suggestions-default-language"
xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" || true

xcrun simctl launch --terminate-running-process "${UDID}" "${BUNDLE_ID}" -search "台北車站" -AppleLanguages "(zh-Hant-TW)"
sleep 14
shot "07-search-suggestions-zh-Hant"
xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" || true

xcrun simctl launch --terminate-running-process "${UDID}" "${BUNDLE_ID}" -search "Taipei Main Station" -AppleLanguages "(en)"
sleep 14
shot "08-search-suggestions-en"
xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" || true

# 5) 北宜公路：區間要貼著道路畫（App 會用 Apple 地圖的路線規劃貼齊，每段要幾秒）
xcrun simctl launch --terminate-running-process "${UDID}" "${BUNDLE_ID}" -mapCenter "24.905,121.695" -mapSpan 0.16
sleep 40
shot "09-sections-follow-road"
# 放大看彎道：第 1 段（19K–23.1K）全段、23.1K 終點附近的髮夾彎、第 2 段、第 4 段宜蘭端
xcrun simctl launch --terminate-running-process "${UDID}" "${BUNDLE_ID}" -mapCenter "24.9545,121.6107" -mapSpan 0.035
sleep 12
shot "10-beiyi-1"
xcrun simctl launch --terminate-running-process "${UDID}" "${BUNDLE_ID}" -mapCenter "24.9563,121.6215" -mapSpan 0.01
sleep 10
shot "11-beiyi-1-hairpin"
xcrun simctl launch --terminate-running-process "${UDID}" "${BUNDLE_ID}" -mapCenter "24.9473,121.6590" -mapSpan 0.035
sleep 10
shot "12-beiyi-2"
xcrun simctl launch --terminate-running-process "${UDID}" "${BUNDLE_ID}" -mapCenter "24.8590,121.7840" -mapSpan 0.05
sleep 10
shot "13-beiyi-4"

# 6) 導航預覽：先看地點（約 3 秒）→ 路線預覽（倒數 10 秒）→ 開始導航
xcrun simctl launch --terminate-running-process "${UDID}" "${BUNDLE_ID}" -previewTo "25.0478,121.5170,台北車站"
sleep 4
shot "14-preview-place"
sleep 5
shot "15-preview-route"
sleep 14
shot "16-navigation-started"

# 7) 設定頁最上面的「搜尋與導航語言」
xcrun simctl launch --terminate-running-process "${UDID}" "${BUNDLE_ID}" -settings
sleep 8
shot "17-settings-language"

# App 的紀錄（確認啟動參數、sheet、地圖範圍有沒有生效）
xcrun simctl spawn "${UDID}" log show --last 15m --style compact \
  --predicate 'subsystem == "tw.speedcammap.app"' 2>/dev/null | tail -60 || true

ls -la "${OUT}"
