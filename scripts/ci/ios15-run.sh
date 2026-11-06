#!/usr/bin/env bash
# 在 iPhone 7、iOS 15.5 模擬器上實際開啟 App：確認裝得上、開得起來、主要畫面正常、沒有閃退。
# 截圖存到 screenshots/。
set -euo pipefail

APP_PATH="${1:?用法：ios15-run.sh path/to/SpeedCam.app}"
BUNDLE_ID="tw.speedcammap.app"
OUT="screenshots"
mkdir -p "${OUT}"

UDID=$(xcrun simctl create "iPhone 7 iOS 15" com.apple.CoreSimulator.SimDeviceType.iPhone-7 com.apple.CoreSimulator.SimRuntime.iOS-15-5)
echo "模擬器 ${UDID}"
xcrun simctl boot "${UDID}"
xcrun simctl bootstatus "${UDID}" -b
xcrun simctl install "${UDID}" "${APP_PATH}"
echo "App 裝得上（含最低版本 iOS 26 的 Widget Extension）"
xcrun simctl privacy "${UDID}" grant location "${BUNDLE_ID}" || true
xcrun simctl privacy "${UDID}" grant location-always "${BUNDLE_ID}" || true
xcrun simctl location "${UDID}" set 25.0300,121.5650 || true

launch_app() {
  xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" 2>/dev/null || true
  sleep 2
  xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" 2>/dev/null || true
  sleep 1
  xcrun simctl launch --terminate-running-process "${UDID}" "${BUNDLE_ID}" "$@"
}

shot() {
  xcrun simctl io "${UDID}" screenshot "${OUT}/$1.png"
  echo "已截圖 $1"
}

# App 還在不在。一開就閃退的話，launch 本身不會失敗，要這樣才看得出來。
assert_running() {
  # 先存成變數再比對：grep -q 比對到就結束，配上 pipefail 會因為 SIGPIPE 被誤判成失敗。
  local list
  list=$(xcrun simctl spawn "${UDID}" launchctl list)
  if ! grep -q "UIKitApplication:${BUNDLE_ID}" <<<"${list}"; then
    echo "::error::App 在「$1」已經不在執行了（閃退）"
    # 閃退報告要幾秒才會寫好
    sleep 8
    report_crashes || true
    xcrun simctl spawn "${UDID}" log show --last 2m --style compact --predicate 'process == "SpeedCam"' 2>/dev/null | tail -40 || true
    exit 1
  fi
  echo "「$1」App 正常執行中"
}

report_crashes() {
  CRASH=$(find "${HOME}/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports -name "SpeedCam*.ips" -mmin -40 2>/dev/null | head -1 || true)
  if [[ -z "${CRASH}" ]]; then
    echo "沒有 SpeedCam 的閃退報告"
    return 0
  fi
  echo "::error::找到閃退報告 ${CRASH}"
  python3 - "${CRASH}" <<'PY' || head -c 6000 "${CRASH}"
import json, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
header, _, body = text.partition("\n")
report = json.loads(body)
print("exception:", json.dumps(report.get("exception"), ensure_ascii=False))
print("termination:", json.dumps(report.get("termination"), ensure_ascii=False)[:800])
images = report.get("usedImages", [])
for t in report.get("threads", []):
    if not t.get("triggered"):
        continue
    for f in t.get("frames", [])[:40]:
        img = images[f.get("imageIndex", 0)].get("name", "?") if images else "?"
        print(f"  {img:28} {f.get('symbol', '?')}  {f.get('sourceFile', '')}:{f.get('sourceLine', '')}")
PY
  return 1
}

# 1) 一般啟動：自動巡航（CLLocationManager 定位）、MKMapView
launch_app
sleep 25
assert_running "一般啟動"
shot "ios15-01-cruise"

# 2) 展示模式：假軌跡以 62 km/h 往北開，會碰到照相點提醒、超速、區間倒數
launch_app -demo
sleep 22
assert_running "展示模式（接近照相點）"
shot "ios15-02-demo-camera"
sleep 12
shot "ios15-03-demo-near"
sleep 60
assert_running "展示模式（區間倒數）"
shot "ios15-04-demo-section"

# 3) 設定頁（NavigationView、LabeledValue，沒有 Live Activity 那一段）
launch_app -autoStartCruise NO -settings
sleep 10
assert_running "設定頁"
shot "ios15-05-settings"

# 4) 搜尋候選
launch_app -autoStartCruise NO -search "台北車站" -AppleLanguages "(zh-Hant-TW)" -AppleLocale zh_TW
sleep 15
assert_running "搜尋"
shot "ios15-06-search"

# 5) 搜尋壓力測試：反覆輸入、刪除約 45 秒
launch_app -autoStartCruise NO -AppleLanguages "(zh-Hant-TW)" -AppleLocale zh_TW -typeSearch "台北車站"
sleep 55
assert_running "搜尋壓力測試"
shot "ios15-07-search-stress"

# 6) 北宜區間：MKMapView 上畫區間
launch_app -autoStartCruise NO -mapCenter "24.905,121.695" -mapSpan 0.16
sleep 30
assert_running "區間"
shot "ios15-08-sections"

# 7) 導航預覽：汽車、紅黃牌、白牌（iOS 15 不能要求避開高速，機車應該會跳提醒）
launch_app -autoStartCruise NO -previewTo "25.0478,121.5170,台北車站"
sleep 5
shot "ios15-09-preview-place"
sleep 5
assert_running "導航預覽"
shot "ios15-10-preview-route"
sleep 14
assert_running "開始導航"
shot "ios15-11-navigation"
launch_app -autoStartCruise NO -vehicleMode motorcycleRedYellow -previewTo "24.8016,120.9717,新竹車站"
sleep 10
shot "ios15-12-preview-red-yellow"
launch_app -autoStartCruise NO -vehicleMode motorcycleWhite -previewTo "24.8016,120.9717,新竹車站"
sleep 10
assert_running "機車導航預覽"
shot "ios15-13-preview-white"

xcrun simctl spawn "${UDID}" log show --last 20m --style compact \
  --predicate 'subsystem == "tw.speedcammap.app"' 2>/dev/null | grep -E "arguments|appeared|applied|opened|preview|typing|route plan|road_lines" | tail -60 || true

report_crashes
ls -la "${OUT}"
echo "iOS 15.5 測試完成，沒有閃退"
