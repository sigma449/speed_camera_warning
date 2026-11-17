#!/usr/bin/env bash
# 由兩版截圖入口共用；只啟動記憶體 gallery，不改手機上的個人照相點檔案。
capture_user_camera_edits() {
  local prefix="$1" text scenario size
  for text in normal large-text; do
    size=large
    if [[ "${text}" == large-text ]]; then size=accessibility-large; fi
    if ! xcrun simctl ui "${UDID}" content_size "${size}"; then
      echo "::error::無法設定我的照相點截圖的文字大小：${size}"
      return 1
    fi
    for scenario in place fixed fixed-current redLight redLight-current both official added modified settings empty; do
      launch_app -autoStartCruise NO -gallery -galleryUserCameras "${scenario}"
      sleep 2
      shot "${prefix}-${scenario}-${text}-375"
      if [[ "${scenario}" == settings ]]; then
        launch_app -autoStartCruise NO -gallery -galleryUserCameras settings -galleryMiddle
        sleep 2
        shot "${prefix}-settings-modified-${text}-375"
        launch_app -autoStartCruise NO -gallery -galleryUserCameras settings -galleryBottom
        sleep 2
        shot "${prefix}-settings-hidden-${text}-375"
      elif [[ "${text}" == large-text ]]; then
        case "${scenario}" in
          fixed|fixed-current|redLight|redLight-current|both|modified)
            launch_app -autoStartCruise NO -gallery -galleryUserCameras "${scenario}" -galleryBottom
            sleep 2
            shot "${prefix}-${scenario}-bottom-${text}-375"
            ;;
        esac
      fi
    done
  done
  if ! xcrun simctl ui "${UDID}" content_size large; then
    echo "::error::無法還原文字大小"
    return 1
  fi
}
