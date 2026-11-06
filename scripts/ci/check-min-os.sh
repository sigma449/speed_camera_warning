#!/usr/bin/env bash
# 檢查 App 真的能在 iOS 15 啟動：最低版本設定正確，而且沒有強連結到 iOS 15 沒有的函式庫。
# 強連結到不存在的函式庫，App 一開就會閃退（dyld: Library not loaded），而且編譯時看不出來。
set -euo pipefail

APP="${1:?用法：check-min-os.sh path/to/SpeedCam.app}"
EXPECTED_APP_MIN="15.0"
EXPECTED_WIDGET_MIN="26.0"
# iOS 15 沒有、App 不能強連結的函式庫。
FORBIDDEN='ActivityKit|Observation|libswift_StringProcessing|libswift_RegexParser|libswiftRegexBuilder|libswiftSynchronization|SwiftData|Charts|TipKit'

APP_MIN=$(/usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" "${APP}/Info.plist")
echo "App 最低版本：${APP_MIN}"
if [[ "${APP_MIN}" != "${EXPECTED_APP_MIN}" ]]; then
  echo "::error::App 的 MinimumOSVersion 應該是 ${EXPECTED_APP_MIN}，實際是 ${APP_MIN}"
  exit 1
fi

for PLUGIN in "${APP}"/PlugIns/*.appex; do
  [[ -d "${PLUGIN}" ]] || continue
  WIDGET_MIN=$(/usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" "${PLUGIN}/Info.plist")
  echo "$(basename "${PLUGIN}") 最低版本：${WIDGET_MIN}"
  if [[ "${WIDGET_MIN}" != "${EXPECTED_WIDGET_MIN}" ]]; then
    echo "::error::Widget 的 MinimumOSVersion 應該是 ${EXPECTED_WIDGET_MIN}，實際是 ${WIDGET_MIN}"
    exit 1
  fi
done

BINARY="${APP}/$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "${APP}/Info.plist")"
LOADS=$(xcrun otool -l "${BINARY}" | awk '
  /cmd LC_LOAD_DYLIB/      { kind = "強連結" }
  /cmd LC_LOAD_WEAK_DYLIB/ { kind = "弱連結" }
  /cmd LC_REEXPORT_DYLIB/  { kind = "強連結" }
  kind != "" && /^ *name / { print kind, $2; kind = "" }
')
echo "連結的函式庫："
echo "${LOADS}"

if echo "${LOADS}" | grep "^強連結" | grep -E "${FORBIDDEN}"; then
  echo "::error::強連結到 iOS 15 沒有的函式庫（上面列出的），App 在 iOS 15 一開就會閃退"
  exit 1
fi
if ! echo "${LOADS}" | grep -q "^弱連結.*ActivityKit"; then
  echo "::error::找不到弱連結的 ActivityKit，project.yml 的 OTHER_LDFLAGS 可能沒有生效"
  exit 1
fi
echo "最低版本和連結檢查通過"
