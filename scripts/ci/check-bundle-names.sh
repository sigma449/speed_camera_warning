#!/usr/bin/env bash
# 檢查 App 與擴充功能 Info.plist 裡的名稱只有英數字和空白。
# SideStore／AltStore 會用這些名稱向 Apple 註冊 App ID，含中文會被拒絕：
#   Bundle identifier unavailable: An invalid value '…' was provided for the parameter 'appIdName'.
# 中文名稱請放在 zh-Hant.lproj/InfoPlist.strings。
set -euo pipefail

APP="${1:?用法：check-bundle-names.sh path/to/SpeedCam.app}"
status=0

check_plist() {
  local plist="$1"
  for key in CFBundleDisplayName CFBundleName; do
    local value
    value=$(/usr/libexec/PlistBuddy -c "Print :${key}" "$plist" 2>/dev/null || true)
    [ -z "$value" ] && continue
    if LC_ALL=C grep -qE '^[A-Za-z0-9 ]+$' <<<"$value"; then
      echo "OK  ${plist#"$APP"/}  ${key} = ${value}"
    else
      echo "::error::${plist#"$APP"/} 的 ${key}「${value}」含有英數字以外的字元，SideStore 安裝時會被 Apple 拒絕"
      status=1
    fi
  done
}

check_plist "$APP/Info.plist"
for ext in "$APP"/PlugIns/*.appex; do
  [ -d "$ext" ] && check_plist "$ext/Info.plist"
done

STRINGS="$APP/zh-Hant.lproj/InfoPlist.strings"
if [ -f "$STRINGS" ]; then
  echo "OK  主畫面中文名稱：$(plutil -extract CFBundleDisplayName raw -o - "$STRINGS" 2>/dev/null || echo '（無法讀取）')"
else
  echo "::warning::找不到 $STRINGS，主畫面會顯示英文名稱"
fi

exit $status
