#!/usr/bin/env bash

assert_running() {
  local list attempt
  for attempt in 1 2 3; do
    if list=$(xcrun simctl spawn "${UDID}" launchctl list 2>&1); then
      printf '%s\n' "${list}" > "${OUT}/process-state.txt"
      if awk -v pid="${APP_PID}" -v bundle="${BUNDLE_ID}" \
        '$1 == pid && index($3, "UIKitApplication:" bundle) == 1 { found = 1 } END { exit !found }' <<<"${list}"; then
        return 0
      fi
      echo "::error::App 在「$1」的本次程序 ${APP_PID} 已停止或被替換"
      xcrun simctl io "${UDID}" screenshot "${OUT}/process-check-failed.png" || true
      return 1
    fi
    printf '%s\n' "${list}" > "${OUT}/process-query-stderr.txt"
    sleep 1
  done
  echo "::error::三次無法查詢「$1」的 App 執行狀態；這是無法判定，不是啟動通過"
  echo "${list}"
  xcrun simctl io "${UDID}" screenshot "${OUT}/process-check-failed.png" || true
  return 2
}

check_search_finished() {
  local tag="$1" start="$2" output attempt
  for attempt in 1 2 3; do
    if output=$(xcrun simctl spawn "${UDID}" log show --start "${start}" --style json \
      --predicate "subsystem == \"tw.speedcammap.app\" AND category == \"search\" AND processID == ${APP_PID}" 2>&1); then
      printf '%s\n' "${output}" > "${OUT}/search-${tag}.json"
      if python3 - "${OUT}/search-${tag}.json" "${APP_PID}" "${start}" <<'PY'
import json, sys
from pathlib import Path
try:
    rows = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, ValueError) as exc:
    print(f"無法解析搜尋紀錄：{exc}", file=sys.stderr)
    sys.exit(1)
if not isinstance(rows, list):
    sys.exit("搜尋紀錄不是事件陣列")
matched = any(isinstance(row, dict) and row.get("processID") == int(sys.argv[2])
              and str(row.get("timestamp", "")).replace("T", " ")[:19] >= sys.argv[3]
              and "typing test finished" in row.get("eventMessage", "") for row in rows)
sys.exit(0 if matched else 1)
PY
      then
        return 0
      fi
    else
      printf '%s\n' "${output}" > "${OUT}/search-${tag}-query-stderr.txt"
    fi
    sleep 1
  done
  echo "::error::搜尋壓測沒有本輪程序 ${APP_PID} 的完成證據（未完成或無法讀取紀錄）"
  return 1
}
