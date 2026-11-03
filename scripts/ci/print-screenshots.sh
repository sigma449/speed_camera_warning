#!/usr/bin/env bash
# 把截圖縮小成 JPEG，以 base64 印在 log 裡。
# 用途：有些環境（例如雲端開發環境的網路限制）下載不了 GitHub artifact，
# 但讀得到 job log，這樣仍然可以檢查畫面。
set -euo pipefail
DIR="${1:-screenshots}"
shopt -s nullglob
for f in "${DIR}"/*.png; do
  name=$(basename "${f}" .png)
  tmp="${RUNNER_TEMP:-/tmp}/${name}.jpg"
  sips -Z 900 -s format jpeg -s formatOptions 70 "${f}" --out "${tmp}" >/dev/null
  echo "=====BEGIN-SCREENSHOT ${name}"
  base64 -b 76 -i "${tmp}"
  echo "=====END-SCREENSHOT ${name}"
done
