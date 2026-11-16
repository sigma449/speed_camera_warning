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
  local tag="$1" start="$2" attempt query_status
  local json="${OUT}/search-${tag}.json" query_stderr="${OUT}/search-${tag}-query-stderr.txt"
  for attempt in 1 2 3; do
    if xcrun simctl spawn "${UDID}" log show --start "${start}" --style json --info --debug \
      --predicate "subsystem == \"tw.speedcammap.app\" AND category == \"search\" AND processID == ${APP_PID}" \
      > "${json}" 2> "${query_stderr}"; then
      query_status=0
    else
      query_status=$?
    fi
    printf '%s\n' "${query_status}" > "${OUT}/search-${tag}-query-status.txt"
    if python3 - "${json}" "${APP_PID}" "${start}" "${query_stderr}" "${query_status}" <<'PY'
import datetime as dt
import json, sys
from pathlib import Path
try:
    raw = Path(sys.argv[1]).read_bytes()
    diagnostics = Path(sys.argv[4]).read_bytes()
except OSError as exc:
    sys.exit(f"無法讀取搜尋查詢證據：{exc}")
print(f"搜尋紀錄查詢：exit={sys.argv[5]} stdout={len(raw)} bytes stderr={len(diagnostics)} bytes"
      f" PID={sys.argv[2]} start={sys.argv[3]}")
if diagnostics:
    print("搜尋查詢 stderr：" + diagnostics[:2000].decode("utf-8", errors="replace"), file=sys.stderr)
if sys.argv[5] != "0":
    sys.exit("搜尋紀錄查詢指令失敗")
try:
    rows = json.loads(raw.decode("utf-8"))
except ValueError as exc:
    print(f"無法解析搜尋紀錄：{exc}", file=sys.stderr)
    print("搜尋查詢 stdout 開頭：" + repr(raw[:400].decode("utf-8", errors="replace")), file=sys.stderr)
    sys.exit(1)
if not isinstance(rows, list):
    sys.exit("搜尋紀錄不是事件陣列")
started = dt.datetime.fromisoformat(sys.argv[3]).astimezone()
def completed(row):
    if not isinstance(row, dict) or type(row.get("processID")) is not int or row["processID"] != int(sys.argv[2]):
        return False
    message = row.get("eventMessage")
    if not isinstance(message, str) or "typing test finished" not in message:
        return False
    timestamp = row.get("timestamp")
    try:
        if not isinstance(timestamp, str):
            raise ValueError("缺少時間字串")
        return dt.datetime.fromisoformat(timestamp.replace("Z", "+00:00")).astimezone() >= started
    except ValueError as exc:
        print(f"完成紀錄時間無效：{timestamp}（{exc}）", file=sys.stderr)
        return False
matched = any(completed(row) for row in rows)
if not matched:
    print(f"搜尋紀錄有 {len(rows)} 筆，但沒有符合本輪 PID 與開始時間的完成事件", file=sys.stderr)
sys.exit(0 if matched else 1)
PY
    then
      assert_running "搜尋壓測 ${tag} 完成" || return $?
      return 0
    fi
    sleep 1
  done
  echo "::error::搜尋壓測沒有本輪程序 ${APP_PID} 的完成證據（未完成或無法讀取紀錄）"
  return 1
}
