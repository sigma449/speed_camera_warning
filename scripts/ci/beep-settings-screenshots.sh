#!/usr/bin/env bash
# 只開記憶體設定示例，使用正式滑桿；不改使用者的偏好設定。
capture_beep_settings() {
  local prefix="$1" text scenario size
  for text in normal large-text; do
    size=large
    if [[ "${text}" == large-text ]]; then size=accessibility-large; fi
    if ! xcrun simctl ui "${UDID}" content_size "${size}"; then
      echo "::error::無法設定嗶聲滑桿截圖的文字大小：${size}"
      return 1
    fi
    for scenario in min default max; do
      launch_app -autoStartCruise NO -gallery -galleryBeepInterval "${scenario}"
      sleep 2
      shot "${prefix}-${scenario}-${text}-375"
    done
  done
  if ! xcrun simctl ui "${UDID}" content_size large; then
    echo "::error::無法還原文字大小"
    return 1
  fi
}
