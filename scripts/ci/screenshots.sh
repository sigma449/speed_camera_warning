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

# 巡航中的 App 被結束後，iOS 會在背景把它重新叫起來（背景定位）；這時直接 launch 只會把背景那個帶到前景，
# 啟動參數不會生效。所以：
# - 每次啟動前先結束兩次（中間等一下，把背景重新叫起來的那個也結束）
# - 不需要巡航的截圖加上「-autoStartCruise NO」，就不會再被背景叫起來
launch_app() {
  xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" 2>/dev/null || true
  sleep 2
  xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" 2>/dev/null || true
  sleep 1
  local result
  result=$(xcrun simctl launch --terminate-running-process "${UDID}" "${BUNDLE_ID}" "$@")
  echo "${result}"
  APP_PID="${result##*: }"
  if [[ ! "${APP_PID}" =~ ^[0-9]+$ ]]; then
    echo "::error::無法取得 App PID"
    return 1
  fi
}

wait_for_ui() {
  local marker="$1"
  for ((attempt=0; attempt<60; attempt++)); do
    if ! UI_READY_LOG=$(xcrun simctl spawn "${UDID}" log show --last 3m --style compact \
      --predicate "subsystem == \"tw.speedcammap.app\" AND category == \"ui\" AND processID == ${APP_PID}" 2>&1); then
      echo "::warning::無法讀取本次 App 的畫面狀態；仍繼續截圖"
      echo "${UI_READY_LOG}"
      return 0
    fi
    if [[ "${UI_READY_LOG}" == *"${marker}"* ]]; then
      return 0
    fi
    sleep 1
  done
  echo "::warning::未取得畫面狀態：${marker}；Apple 路線、搜尋或載入時間可能改變，仍繼續截圖"
  echo "${UI_READY_LOG}"
  return 0
}

wait_for_comparison() {
  local marker="map comparison ready mode=$1 style=$2 emphasis=$3 legacy=$4 source=demo"
  wait_for_ui "${marker}"
  sleep 6
}

assert_running() {
  local list
  if ! list=$(xcrun simctl spawn "${UDID}" launchctl list); then
    echo "::warning::無法讀取 App 執行狀態；仍嘗試截圖"
    return 0
  fi
  if ! grep -Fq "UIKitApplication:${BUNDLE_ID}" <<<"${list}"; then
    echo "::error::App 在「$1」已停止執行（閃退）"
    return 1
  fi
}

shot() {
  assert_running "$1"
  xcrun simctl io "${UDID}" screenshot "${OUT}/$1.png"
  if [[ ! -s "${OUT}/$1.png" ]]; then
    echo "::error::截圖沒有產生：$1"
    return 1
  fi
  echo "已截圖 $1"
}

# 1) Live Activity 預覽頁
launch_app -gallery
sleep 10
shot "01-live-activity-gallery"
# 預覽頁比一個畫面長，另外拍中段（170 pt 的導航與巡航）和底部（240×100 pt、鎖定畫面）
launch_app -gallery -galleryMiddle
sleep 8
shot "01b-live-activity-gallery-middle"
launch_app -gallery -galleryBottom
sleep 8
shot "01c-live-activity-gallery-bottom"
# 手機橫幅的各種狀態（展示模式不一定碰得到，文字也比真實資料短）
launch_app -gallery -galleryBanners
sleep 8
shot "01d-banners-top"
launch_app -gallery -galleryBanners -galleryBottom
sleep 8
shot "01e-banners-bottom"
# 鎖定畫面和動態島展開的各種狀態
launch_app -gallery -galleryLock
sleep 8
shot "01f-lock-top"
launch_app -gallery -galleryLock -galleryBottom
sleep 8
shot "01g-lock-bottom"
launch_app -autoStartCruise NO -gallery -galleryStale -galleryLock
sleep 8
shot "27-stale-activity-lock"
launch_app -autoStartCruise NO -gallery -galleryStale
sleep 8
shot "28-stale-activity-small"
launch_app -autoStartCruise NO -gallery -galleryBanners -galleryBannerPair camera -galleryWidth 375
sleep 8
shot "29-banners-navigation-camera-375"
launch_app -autoStartCruise NO -gallery -galleryBanners -galleryBannerPair section -galleryWidth 375
sleep 8
shot "30-banners-navigation-section-375"
launch_app -autoStartCruise NO -gallery -galleryBanners -galleryBannerPair zero -galleryWidth 390
sleep 8
shot "31-banners-navigation-zero-390"
launch_app -autoStartCruise NO -gallery -galleryBanners -galleryBannerPair rerouting -galleryWidth 390
sleep 8
shot "32-banners-rerouting-camera-390"
xcrun simctl ui "${UDID}" content_size accessibility-large || echo "::warning::無法切換放大文字"
launch_app -autoStartCruise NO -gallery -galleryBanners -galleryBannerPair camera -galleryWidth 375
sleep 8
shot "33-banners-navigation-camera-large-text-375"
launch_app -autoStartCruise NO -gallery -galleryBanners -galleryBannerPair section -galleryWidth 375
sleep 8
shot "34-banners-navigation-section-large-text-375"
xcrun simctl ui "${UDID}" content_size large || echo "::warning::無法還原文字大小"

# 2) 展示模式：假軌跡以 62 km/h 往北開，600 m 處有速限 50 的測速照相，1.2 km 處進入區間
launch_app -demo
sleep 20
shot "02-demo-pre-alert"
sleep 10
shot "03-demo-near-overspeed"
# 約 70 秒才會進入區間，CI 的速度又不固定，多等一點才一定拍得到倒數橫幅
sleep 65
shot "04-demo-section-countdown"

# 3) 一般啟動（使用 App 內建的真實資料；預設會自動開始巡航）
launch_app
sleep 8
shot "05-normal-launch"

# 4) 搜尋候選：模擬器預設語言、繁體中文、英文（確認搜尋與導航語言的設定有效）
launch_app -autoStartCruise NO -search "台北車站"
sleep 14
shot "06-search-suggestions-default-language"

launch_app -autoStartCruise NO -search "台北車站" -AppleLanguages "(zh-Hant-TW)" -AppleLocale zh_TW
sleep 14
shot "07-search-suggestions-zh-Hant"

launch_app -autoStartCruise NO -search "Taipei Main Station" -AppleLanguages "(en)"
sleep 14
shot "08-search-suggestions-en"

# 4b) 搜尋壓力測試（中文）：反覆輸入、刪除「台北車站」約 45 秒，檢查 App 有沒有閃退
xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" 2>/dev/null || true
sleep 2
xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" 2>/dev/null || true
STRESS_ERR="${PWD}/${OUT}/search-stress-stderr.txt"
xcrun simctl launch --terminate-running-process --stderr="${STRESS_ERR}" "${UDID}" "${BUNDLE_ID}" \
  -autoStartCruise NO -AppleLanguages "(zh-Hant-TW)" -AppleLocale zh_TW -typeSearch "台北車站"
sleep 55
shot "08b-search-typing-stress"
echo "---- App 的錯誤輸出（最後 40 行）----"
tail -40 "${STRESS_ERR}" 2>/dev/null || echo "（沒有錯誤輸出）"
# 以 App 自己記錄的「typing test finished」判斷（launchctl 的檢查曾經誤判）
if xcrun simctl spawn "${UDID}" log show --last 3m --style compact \
     --predicate 'subsystem == "tw.speedcammap.app" AND category == "search"' 2>/dev/null | grep -q "typing test finished"; then
  echo "搜尋壓力測試：完成，沒有閃退"
else
  echo "::warning::搜尋壓力測試：沒有跑完（可能閃退），請看截圖 08b"
fi
sleep 3
CRASH=$(find "${HOME}/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports -name "SpeedCam*.ips" -mmin -20 2>/dev/null | head -1 || true)
if [[ -n "${CRASH}" ]]; then
  echo "::warning::找到閃退報告 ${CRASH}"
  python3 - "${CRASH}" <<'PY' || head -c 6000 "${CRASH}"
import json, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
header, _, body = text.partition("\n")
report = json.loads(body)
print("exception:", json.dumps(report.get("exception"), ensure_ascii=False))
print("termination:", json.dumps(report.get("termination"), ensure_ascii=False)[:600])
images = report.get("usedImages", [])
for t in report.get("threads", []):
    if not t.get("triggered"):
        continue
    for f in t.get("frames", [])[:40]:
        img = images[f.get("imageIndex", 0)].get("name", "?") if images else "?"
        print(f"  {img:28} {f.get('symbol', '?')}  {f.get('sourceFile', '')}:{f.get('sourceLine', '')}")
PY
else
  echo "沒有 SpeedCam 的閃退報告"
fi

# 5) 北宜公路：區間要貼著道路畫（App 會用 Apple 地圖的路線規劃貼齊，近的先做，每段要幾秒）
launch_app -autoStartCruise NO -mapCenter "24.905,121.695" -mapSpan 0.16
sleep 45
shot "09-sections-follow-road"
# 放大看彎道：第 1 段（19K–23.1K）全段、23.1K 終點附近的髮夾彎、第 2 段、第 4 段宜蘭端
launch_app -autoStartCruise NO -mapCenter "24.9545,121.6107" -mapSpan 0.035
sleep 12
shot "10-beiyi-1"
launch_app -autoStartCruise NO -mapCenter "24.9563,121.6215" -mapSpan 0.01
sleep 10
shot "11-beiyi-1-hairpin"
launch_app -autoStartCruise NO -mapCenter "24.9473,121.6590" -mapSpan 0.035
sleep 10
shot "12-beiyi-2"
launch_app -autoStartCruise NO -mapCenter "24.8590,121.7840" -mapSpan 0.05
sleep 10
shot "13-beiyi-4"

# 6) 設定頁最上面的「搜尋與導航語言」
launch_app -autoStartCruise NO -settings
sleep 8
shot "14-settings-language"

# 7) 導航預覽：先看地點（約 3 秒）→ 路線預覽（倒數 10 秒）→ 開始導航（會開始巡航，所以放最後）
launch_app -autoStartCruise NO -previewTo "25.0478,121.5170,台北車站"
sleep 4
shot "15-preview-place"
sleep 5
shot "16-preview-route"
sleep 14
shot "17-navigation-started"

# 8) 車種：設定頁、底部按鈕的小字、兩種機車的路線預覽（從台北到新竹，紅黃牌應該走快速道路，白牌走平面道路）
launch_app -autoStartCruise NO -settings -vehicleMode motorcycleRedYellow
sleep 8
shot "18-settings-red-yellow"
launch_app -autoStartCruise NO -vehicleMode motorcycleRedYellow -previewTo "24.8016,120.9717,新竹車站"
sleep 9
shot "19-preview-red-yellow"
launch_app -autoStartCruise NO -vehicleMode motorcycleWhite -previewTo "24.8016,120.9717,新竹車站"
sleep 9
shot "20-preview-white"

# 9) 舊系統的做法（-legacyUI：MKMapView、CLLocationManager、NavigationView、不要求避開高速）。
# 在這裡看外觀和流程，真正的舊系統要靠實機。
launch_app -legacyUI -demo
sleep 25
shot "21-legacy-demo-camera"
launch_app -legacyUI -autoStartCruise NO -mapCenter "24.905,121.695" -mapSpan 0.16
sleep 20
shot "22-legacy-sections"
launch_app -legacyUI -autoStartCruise NO -settings
sleep 8
shot "23-legacy-settings"
launch_app -legacyUI -autoStartCruise NO -search "台北車站" -AppleLanguages "(zh-Hant-TW)" -AppleLocale zh_TW
sleep 14
shot "24-legacy-search"
launch_app -legacyUI -autoStartCruise NO -vehicleMode motorcycleWhite -previewTo "24.8016,120.9717,新竹車站"
sleep 9
shot "25-legacy-preview-white"
# 最後一張會開始巡航（用 CLLocationManager 定位），確認畫面跟著定位
launch_app -legacyUI
sleep 12
shot "26-legacy-cruise"

# 10) 內建示範折線與固定鏡頭的 3×2 對照，不向 Apple 請求路線。
for style in current whiteCasing darkCasing; do
  for emphasis in current muted; do
    launch_app -autoStartCruise NO -routeStyleDemo \
      -routeLineStyle "${style}" -mapEmphasis "${emphasis}" -routeComparison preview
    wait_for_comparison preview "${style}" "${emphasis}" false
    shot "35-route-preview-${style}-${emphasis}"
    launch_app -autoStartCruise NO -routeStyleDemo \
      -routeLineStyle "${style}" -mapEmphasis "${emphasis}" -routeComparison navigation3D
    wait_for_comparison navigation3D "${style}" "${emphasis}" false
    shot "36-route-navigation3d-${style}-${emphasis}"
  done
done

# 舊地圖用同一條示範線、同一組 2D／3D 鏡頭。
for style in current whiteCasing darkCasing; do
  for emphasis in current muted; do
    launch_app -legacyUI -autoStartCruise NO -routeStyleDemo \
      -routeLineStyle "${style}" -mapEmphasis "${emphasis}" -routeComparison preview
    wait_for_comparison preview "${style}" "${emphasis}" true
    shot "37-route-legacy-preview-${style}-${emphasis}"
    launch_app -legacyUI -autoStartCruise NO -routeStyleDemo \
      -routeLineStyle "${style}" -mapEmphasis "${emphasis}" -routeComparison navigation3D
    wait_for_comparison navigation3D "${style}" "${emphasis}" true
    shot "38-route-legacy-navigation3d-${style}-${emphasis}"
  done
done

# 11) 選點卡使用正式選點狀態與預覽入口；此參數不代表已測到手勢。
launch_app -autoStartCruise NO -selectPlace "25.0478,121.5170,台北車站" \
  -AppleLanguages "(zh-Hant-TW)" -AppleLocale zh_TW
wait_for_ui "place selection ready legacy=false"
sleep 6
shot "39-map-selected-place"
launch_app -legacyUI -autoStartCruise NO -selectPlace "25.0478,121.5170,台北車站" \
  -AppleLanguages "(zh-Hant-TW)" -AppleLocale zh_TW
wait_for_ui "place selection ready legacy=true"
sleep 6
shot "40-map-selected-place-legacy"
launch_app -autoStartCruise NO -gallery -galleryPlaces
sleep 8
shot "41-map-place-card-states-top"
launch_app -autoStartCruise NO -gallery -galleryPlaces -galleryBottom
sleep 8
shot "42-map-place-card-states-bottom"

# IKEA 區間附近同時看 POI、照相點和區間線；導航預覽仍由原有截圖檢查隱藏相機。
launch_app -autoStartCruise NO -mapCenter "24.9715,121.5300" -mapSpan 0.018
sleep 15
shot "43-map-poi-cameras-sections"
launch_app -legacyUI -autoStartCruise NO -mapCenter "24.9715,121.5300" -mapSpan 0.018
sleep 15
shot "44-map-poi-cameras-sections-legacy"

for TYPE in mobile tech noise; do
  launch_app -autoStartCruise NO -gallery -galleryBanners -galleryTypes "${TYPE}" -galleryWidth 375
  sleep 2
  shot "45-reminder-banner-${TYPE}"
  launch_app -autoStartCruise NO -gallery -galleryTypes "${TYPE}"
  sleep 2
  shot "46-reminder-activity-${TYPE}"
done

# App 的紀錄（確認啟動參數、sheet、地圖範圍、區間貼齊、路線選擇有沒有生效）
xcrun simctl spawn "${UDID}" log show --last 20m --style compact \
  --predicate 'subsystem == "tw.speedcammap.app"' 2>/dev/null | grep -E "arguments|appeared|applied|opened|preview|typing|beiyi|一次規劃|分段|route plan|road_lines|live activity" | tail -120 || true

ls -la "${OUT}"
