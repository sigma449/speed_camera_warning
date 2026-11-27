#!/usr/bin/env bash
# 使用記憶體示例，不讀寫個人地點或字卡偏好。
capture_saved_places() {
  local prefix="$1" text scenario size
  for text in normal large-text; do
    size=large
    if [[ "${text}" == large-text ]]; then size=accessibility-large; fi
    if ! xcrun simctl ui "${UDID}" content_size "${size}"; then
      echo "::error::無法設定常用地點截圖的文字大小：${size}"
      return 1
    fi
    for scenario in search assign card card-menu settings rename banner-style; do
      launch_app -autoStartCruise NO -gallery -gallerySavedPlaces "${scenario}"
      sleep 3
      shot "${prefix}-${scenario}-${text}-375"
    done
  done
  if ! xcrun simctl ui "${UDID}" content_size large; then
    echo "::error::無法還原文字大小"
    return 1
  fi
}
