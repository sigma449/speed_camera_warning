#!/usr/bin/env bash
# 搜尋壓力測試：中文介面反覆輸入、刪除「台北車站」，檢查 App 會不會閃退，並印出系統記錄的結束原因。
# 用法：search-stress.sh path/to/SpeedCam.app [輪數]
set -euo pipefail

APP_PATH="${1:?用法：search-stress.sh path/to/SpeedCam.app [輪數]}"
RUNS="${2:-3}"
BUNDLE_ID="tw.speedcammap.app"
OUT="screenshots"
mkdir -p "${OUT}"

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
echo "使用模擬器 ${UDID}"
xcrun simctl boot "${UDID}" || true
xcrun simctl bootstatus "${UDID}" -b > /dev/null
xcrun simctl install "${UDID}" "${APP_PATH}"
xcrun simctl privacy "${UDID}" grant location "${BUNDLE_ID}" || true
xcrun simctl location "${UDID}" set 25.0300,121.5650 || true

failures=0
for run in $(seq 1 "${RUNS}"); do
  echo "================ 第 ${run} 次 ================"
  xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" 2>/dev/null || true
  sleep 2
  ERR="${PWD}/${OUT}/stress-${run}-stderr.txt"
  START=$(date "+%Y-%m-%d %H:%M:%S")
  xcrun simctl launch --terminate-running-process --stderr="${ERR}" "${UDID}" "${BUNDLE_ID}" \
    -autoStartCruise NO -AppleLanguages "(zh-Hant-TW)" -AppleLocale zh_TW -typeSearch "台北車站"
  sleep 58
  xcrun simctl io "${UDID}" screenshot "${OUT}/stress-${run}.png" > /dev/null
  if xcrun simctl spawn "${UDID}" log show --start "${START}" --style compact \
       --predicate 'subsystem == "tw.speedcammap.app" AND category == "search"' 2>/dev/null | grep -q "typing test finished"; then
    echo "結果：完成，沒有閃退"
  else
    echo "::warning::結果：沒有跑完（可能閃退）"
    failures=$((failures + 1))
  fi

  echo "---- App 的進度紀錄 ----"
  xcrun simctl spawn "${UDID}" log show --start "${START}" --style compact \
    --predicate 'subsystem == "tw.speedcammap.app" AND category == "search"' 2>/dev/null | tail -10 || true

  echo "---- 系統記錄的結束原因（runningboardd／SpringBoard／launchd）----"
  xcrun simctl spawn "${UDID}" log show --start "${START}" --style compact \
    --predicate '(process == "runningboardd" OR process == "SpringBoard" OR process == "launchd_sim") AND eventMessage CONTAINS[c] "speedcam"' 2>/dev/null \
    | grep -iE "termin|exit|signal|crash|jetsam|kill|watchdog|memory|limit" | tail -25 || true

  echo "---- App 的錯誤與嚴重錯誤紀錄 ----"
  xcrun simctl spawn "${UDID}" log show --start "${START}" --style compact \
    --predicate 'process == "SpeedCam" AND (messageType == 16 OR messageType == 17)' 2>/dev/null | tail -40 || true

  echo "---- App 的錯誤輸出 ----"
  grep -v "IOSurfaceClientSetSurfaceNotify" "${ERR}" 2>/dev/null | tail -30 || true
done

sleep 10
echo "---- 閃退報告 ----"
find "${HOME}/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports -name "*.ips" -mmin -30 2>/dev/null | while read -r f; do
  echo "${f}"
  if grep -q "SpeedCam" "${f}"; then
    python3 - "${f}" <<'PY' || head -c 4000 "${f}"
import json, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
_, _, body = text.partition("\n")
r = json.loads(body)
print("exception:", json.dumps(r.get("exception"), ensure_ascii=False))
print("termination:", json.dumps(r.get("termination"), ensure_ascii=False)[:800])
print("asi:", json.dumps(r.get("asi"), ensure_ascii=False)[:1500])
images = r.get("usedImages", [])
for t in r.get("threads", []):
    if not t.get("triggered"):
        continue
    for fr in t.get("frames", [])[:45]:
        img = images[fr.get("imageIndex", 0)].get("name", "?") if images else "?"
        print(f"  {img:28} {fr.get('symbol', '?')}  {fr.get('sourceFile', '')}:{fr.get('sourceLine', '')}")
PY
  fi
done

echo "閃退次數：${failures}／${RUNS}"
