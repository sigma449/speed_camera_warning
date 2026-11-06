#!/usr/bin/env bash
# 編譯並執行路線實測（route-probe.swift）。
# 包成有 bundle ID 的 App 再執行，因為 MapKit 的路線規劃可能不接受沒有 bundle ID 的程式。
set -euo pipefail

OUTPUT="${1:-route-probe-results.jsonl}"
APP="build/RouteProbe.app"

mkdir -p "${APP}/Contents/MacOS"
cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>tw.speedcam.routeprobe</string>
  <key>CFBundleName</key>
  <string>RouteProbe</string>
  <key>CFBundleExecutable</key>
  <string>RouteProbe</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
</dict>
</plist>
PLIST

swiftc -swift-version 5 scripts/ci/route-probe.swift -o "${APP}/Contents/MacOS/RouteProbe"
codesign --force --sign - "${APP}"

# 路名和步驟文字跟著系統語言。CI 的機器用完就丟，改全域設定沒有關係。
defaults write -g AppleLanguages -array zh-Hant-TW en
defaults write -g AppleLocale -string zh_TW
killall geod 2>/dev/null || true

"${APP}/Contents/MacOS/RouteProbe" "${OUTPUT}" -AppleLanguages '(zh-Hant-TW, en)' -AppleLocale zh_TW
