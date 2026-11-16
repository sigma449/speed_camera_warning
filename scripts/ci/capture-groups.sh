#!/usr/bin/env bash

configure_capture() {
  CAPTURE_PROFILE="${1:-smoke}"
  case "${CAPTURE_PROFILE}" in
    smoke|gallery|map|search|styles|full|all|none) ;;
    *)
      echo "::error::未知截圖情境：${CAPTURE_PROFILE}（smoke/gallery/map/search/styles/full/all/none）" >&2
      return 64
      ;;
  esac
  echo "截圖情境：${CAPTURE_PROFILE}；full 不含內部樣式對照"
}

selected() {
  case "${CAPTURE_PROFILE}" in
    all) [[ "$1" != smoke ]] ;;
    full) [[ "$1" != styles && "$1" != smoke ]] ;;
    *) [[ "${CAPTURE_PROFILE}" == "$1" ]] ;;
  esac
}
