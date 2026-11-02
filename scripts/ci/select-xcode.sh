#!/usr/bin/env bash
# 選用 runner 上最新的 Xcode 26 以上版本（需要 iOS 26 SDK）。
set -euo pipefail

echo "可用的 Xcode："
ls -d /Applications/Xcode*.app || true

XCODE=$(ls -d /Applications/Xcode_2[6-9]*.app 2>/dev/null | grep -v -i beta | sort -V | tail -1 || true)
if [[ -z "${XCODE}" ]]; then
  XCODE=$(ls -d /Applications/Xcode_2[6-9]*.app 2>/dev/null | sort -V | tail -1 || true)
fi
if [[ -z "${XCODE}" ]]; then
  echo "::error::找不到 Xcode 26 以上的版本（需要 iOS 26 SDK）"
  exit 1
fi

echo "使用 ${XCODE}"
sudo xcode-select -s "${XCODE}/Contents/Developer"
xcodebuild -version
xcrun simctl list runtimes | grep -i ios || true
