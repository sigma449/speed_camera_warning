#!/usr/bin/env bash
# 共用工作本體；下載、驗指紋、always 診斷及 artifact 由 caller 負責。
set -euo pipefail

case "${CI_TASK:?}" in ios26|ios15|ipa|probe|stress) ;; *) echo "::error::未知 macOS 工作"; exit 64 ;; esac
if [[ ! "${CI_LABEL:?}" =~ ^[a-z0-9-]+$ ]]; then
  echo "::error::工作名稱只能包含小寫英數字與連字號"
  exit 64
fi
EVIDENCE="build/evidence/${CI_LABEL}"
mkdir -p "${EVIDENCE}"
if [[ "${ACCEPTANCE:-false}" == true && "${CAPTURE_SCENARIOS:-smoke}" == none &&
      ( "${CI_TASK}" == ios26 || "${CI_TASK}" == ios15 ) ]]; then
  echo "::error::完整驗收不能略過 iOS 截圖"
  exit 64
fi

if [[ "${CI_TASK}" == probe ]]; then
  case "${PROBE_MODE:?}" in plan|compare|replay) ;; *) echo "::error::未知路線模式"; exit 64 ;; esac
  python3 - "${PROBE_CASES:?}" <<'PY'
from pathlib import Path
import sys
root = Path("scripts/ci").resolve()
path = Path(sys.argv[1]).resolve()
if not path.is_relative_to(root) or path.suffix != ".json" or not path.is_file():
    raise SystemExit("案例必須是 scripts/ci 內既存的 JSON")
PY
  export DATA_BUILD_LOG="build/ci-data/data-build.log"
  bash scripts/ci/route-probe.sh "${PROBE_MODE}" "${PROBE_CASES}" build/route-probe/results.jsonl
  exit 0
fi

brew install --quiet xcodegen
xcodegen generate
CONFIGURATION=Debug
SDK=iphonesimulator
DESTINATION='generic/platform=iOS Simulator'
if [[ "${CI_TASK}" == ios15 || "${CI_TASK}" == ipa ]]; then CONFIGURATION=Release; fi
if [[ "${CI_TASK}" == ipa ]]; then SDK=iphoneos; DESTINATION='generic/platform=iOS'; fi
COMMAND=(xcodebuild -project SpeedCam.xcodeproj -scheme SpeedCam -configuration "${CONFIGURATION}"
  -sdk "${SDK}" -destination "${DESTINATION}" -derivedDataPath build
  -resultBundlePath "${EVIDENCE}/build.xcresult" CODE_SIGNING_ALLOWED=NO)
if [[ "${CI_TASK}" == ipa ]]; then COMMAND+=(CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=); fi
"${COMMAND[@]}" build 2>&1 | tee "${EVIDENCE}/build.log"
APP_PATH="build/Build/Products/${CONFIGURATION}-${SDK}/SpeedCam.app"

case "${CI_TASK}" in
  ios26)
    bash scripts/ci/screenshots.sh "${APP_PATH}" "${CAPTURE_SCENARIOS:-smoke}"
    ;;
  ios15)
    bash scripts/ci/check-min-os.sh "${APP_PATH}"
    bash scripts/ci/install-ios15-runtime.sh
    bash scripts/ci/ios15-run.sh "${APP_PATH}" "${CAPTURE_SCENARIOS:-smoke}"
    ;;
  stress)
    bash scripts/ci/search-stress.sh "${APP_PATH}" "${STRESS_RUNS:-3}"
    ;;
  ipa)
    mkdir -p build/ipa/Payload
    cp -R "${APP_PATH}" build/ipa/Payload/
    bash scripts/ci/check-bundle-names.sh build/ipa/Payload/SpeedCam.app
    bash scripts/ci/check-min-os.sh build/ipa/Payload/SpeedCam.app
    python3 scripts/ci/data-bundle.py verify --commit "${COMMIT:?}" --manifest-sha "${MANIFEST_SHA:?}" \
      --release --app-data build/ipa/Payload/SpeedCam.app/cameras.json
    (cd build/ipa && zip -qry SpeedCam.ipa Payload)
    python3 scripts/ci/data-bundle.py verify --commit "${COMMIT}" --manifest-sha "${MANIFEST_SHA}" \
      --ipa build/ipa/SpeedCam.ipa
    cp build/ipa/SpeedCam.manifest.json "${EVIDENCE}/ipa-manifest.json"
    ;;
esac
