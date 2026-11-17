# CI、完整驗收與 macOS 執行對照

## 完整驗收入口

建置環境為 macos-26／Xcode26.6、App最低iOS15／Widget26、Swift5／strict concurrency minimal；
側載名稱、最低OS與強連結檢查仍保留。

由**已在 main 註冊**的 `build-ipa.yml` 接收 `acceptance=true`，呼叫同分支的 `_acceptance.yml`。
新檔只有 `workflow_call`，不必先合併 main 才能使用。驗收者將本機提交更新到遠端同名分支後執行：

```powershell
gh workflow run build-ipa.yml --repo sigma449/speed_camera_warning --ref copilot/test2-1108 -f acceptance=true -f screenshots=full
```

一次 run 的順序：

```text
Linux 準備 ci-data
  → Linux Swift＋Python（平行，兩者都必須成功）
    → iOS 26、iOS 15、1108／1107／tunnels replay＋各自檢查器（平行）
      → 全部成功才建置及上傳 IPA
        → always 彙總結果、資料指紋與檢查器結論
```

所有 checkout 固定到該次 `github.sha`，不是執行到一半再讀分支最新版本。
資料只準備一次；所有消費端下載同 run 的 `ci-data`，並核對 prepare job 傳出的 manifest SHA-256。
`skipped`、缺少或重複證據、不同 commit／資料指紋、檢查器失敗，都不算通過。
摘要寫入 `GITHUB_STEP_SUMMARY` 與 `acceptance-summary`；列 commit、資料點數／方向別區間數／類型數、
各 job、三組檢查器及 `SpeedCam-ipa`。單獨存在 IPA artifact 不代替完整驗收結論。

原來的獨立入口保留：

| 用途 | 指令；`REF` 換成待測分支 |
|---|---|
| 只產生未簽署 IPA | `gh workflow run build-ipa.yml --repo sigma449/speed_camera_warning --ref REF` |
| iOS 15 | `gh workflow run ios15-test.yml --repo sigma449/speed_camera_warning --ref REF -f screenshots=full` |
| 搜尋壓測 | `gh workflow run search-stress.yml --repo sigma449/speed_camera_warning --ref REF -f runs=3` |
| 規劃探索 | `gh workflow run route-probe.yml --repo sigma449/speed_camera_warning --ref REF -f mode=plan -f cases=scripts/ci/route-probe-cases.json` |
| 1108 replay | `gh workflow run route-probe.yml --repo sigma449/speed_camera_warning --ref REF -f mode=replay -f cases=scripts/ci/route-replay-1108.json` |
| 1107／隧道 replay | 上列 `cases` 改為 `scripts/ci/route-replay-1107.json`／`scripts/ci/route-replay-tunnels.json` |

獨立 Build IPA／tag 打包明列「不是完整驗收通過」。`plan`／`compare` 不準備相機資料，仍是原本的探索模式，
允許部分規劃成功；不能據此宣稱 replay 驗收通過。自訂 replay 清單至少執行共通檢查，不冒充三組指定驗收。

## 資料完整性與發布契約

`data-bundle.py prepare` 先移除自己輸出目錄中的舊成功包，再執行真正的 `build_cameras.py`。
產物是 `cameras.json`、`sources.json`、`data-build.log`、`manifest.json`；manifest 含 commit、
產生時間、點數／區間數／各類型數、建置模式、來源健康狀態及前三檔的 SHA-256。
消費端核對外部傳入的 manifest hash 與 commit，不能只相信包內自行宣告的值，也不重新抓資料。

發布政策 v1（`data-bundle.py release_blockers`）同時要求：

- 線上完整建置、多來源及自動區間均開啟，7040 成功且有資料；失聯回 HTML 的模式不算完整。
- 相機至少 500 點，7320 本輪可用原始列至少 500；相機及區間 ID 不重複。
- **至少 70 個方向別區間**，並保留北宜 1～4 雙向、台64 中和東／西、自強／辛亥雙向、
  新店環河路雙向，共 16 個必要 ID。
- 已核斗六四個穩定 ID 仍是 `mobile`、沒有測速門檻；銀河人工點仍是固定測速 40。

70 的依據是已核完整版本 79／82 個方向，保留約 11～15% 的資料變動空間，但攔住曾只剩 19 段的降級產物；
**不是永久鎖死 82，也不是只要滿 70 就可發布**。必要 ID、7040、主來源及關鍵點仍各自把關。
若官方確實停用／重整必要資料，應先核實並更新政策及版本化證據，不能為了綠勾直接調低門檻。

`complete` 只代表上述必要完整性政策過關，不代表所有外部來源都是即時資料。
可選來源的已驗證快照回退／失聯／資料警告會明列於 `sources.json`、摘要與完整建置 log。
缺必要資料時，非發布用途可以明示降級供 smoke；完整 CI、完整驗收、replay 和 IPA 都要求發布閘門。
7040 降級不能靠相機數夠多、舊 repo JSON 或前一輪 artifact 補成可發布資料。

每週更新也產生新資料包，但寫回 repo 前重用 builder 的 `unchanged` 判斷：
只有日期／排版不同時保留原檔，不開日期變更 PR；相機、區間、來源報告或建置狀態改變仍寫入本輪完整位元組。
這項保留日期只限每週更新，測試／App／IPA 的安裝仍一律核對同輪包的精確位元組。

IPA 打包前核對 `.app` 中 cameras 的完整位元組；打包後再開 ZIP 核對，並記錄
`commit`、`manifestSHA256`、`dataSHA256`、`ipaSHA256`。指定 `--ipa` 就強制發布政策，不因漏寫 `--release` 放行。
`SpeedCam-data`（資料、來源與處理程式）成功上傳後才上傳 `SpeedCam-ipa`，維持 ODbL 機讀資料提供。

## CI 分流、截圖與下載

一般 CI 的純文件變更只跑便宜的分類與摘要，不下載資料或啟動 iOS。
`SpeedCam`（含 Resources）、Shared、Widget、Core、資料處理、`scripts/ci`、workflow、`project.yml`
以及未知路徑仍跑完整測試與 iOS；Swift／Python 任一失敗，macOS 不啟動。
手動 CI 可用 `full=true` 覆寫文件分流。

CI 的截圖 `auto`：App／Shared／Widget／`scripts/ci`／`project.yml` 改動擴大為 `full`，其餘預設 `smoke`。
也可明確指定情境。完整驗收預設 `full`，不准 `none`；改選其他情境會在結果列出實際範圍，不代表全套 UI 驗收。

| 情境 | iOS 26 | iOS 15 |
|---|---|---|
| `smoke` | 5 張：啟動、設定、375 pt 照相／區間、過期卡片 | 2 張：啟動、設定 |
| `gallery` | 橫幅、窄版／大字、Live Activity、過期、選點及我的照相點 | 我的照相點 47 張；不載入 Live Activity |
| `map` | 展示、地圖、選點、預覽、新舊地圖 | 對應舊地圖功能 |
| `search` | 語言候選、搜尋壓測 | 候選、搜尋壓測 |
| `full` | 100 張；gallery＋map＋search | 61 張；不含內部對照 |
| `styles` | 明確選取才拍 24 張內部樣式比較 | 2 張內部比較 |
| `all` | 124 張 | 63 張 |
| `none` | 只建置，不宣稱畫面驗收 | 同左 |

沒有縮短展示倒數或外部服務等待。UI-ready 缺失仍警告拍圖；**App 存活查不到、程序被換掉或截圖失敗則失敗**。
PNG 存在不代表 App 存活，也不代表人工看圖、POI／長按手勢、語音或 CarPlay 已驗收。

### H12／H13 我的照相點截圖

兩版入口共用 `scripts\ci\user-camera-screenshots.sh`，`gallery`／`full`／`all` 都拍，不增加 smoke。
每版 47 張：375 pt 內容寬、一般字級與 accessibility-large；變更字級失敗即失敗，不以假大字照片通過。
所有情境都加 `-gallery -galleryUserCameras`，只用記憶體假資料，不讀寫 `userCameraEdits.v1.json`；
iOS 15 也走正式表單／詳情／管理元件，不退為一般啟動畫面。這些是版面示例，不代表已驗證點擊、分享或語音。

檔名如下，其中 `P` 在 iOS 26 為 `47-user-camera`、iOS 15 為 `ios15-17-user-camera`；
`T` 分別為 `normal`、`large-text`，每個組合各有一張：

| 檔名 | 內容 |
|---|---|
| `P-place-T-375.png` | 選點卡原主動作＋次要新增 |
| `P-fixed-T-375.png` | 新增測速、沒有目前行向 |
| `P-fixed-current-T-375.png` | 新增測速、目前行向預設 |
| `P-redLight-T-375.png` | 新增闖紅燈、沒有速限／目前行向 |
| `P-redLight-current-T-375.png` | 新增闖紅燈、目前行向 |
| `P-both-T-375.png` | 雙向的四種軸向選擇 |
| `P-official-T-375.png` | 官方詳情：修改／隱藏 |
| `P-added-T-375.png` | 自增詳情：標記／修改／刪除 |
| `P-modified-T-375.png` | 已修改詳情：標記／還原 |
| `P-settings-T-375.png` | 我的照相點有資料、起始位置 |
| `P-settings-modified-T-375.png` | 已修改清單與還原 |
| `P-settings-hidden-T-375.png` | 已隱藏清單與復原／匯出 |
| `P-empty-T-375.png` | 空清單與新增說明 |
| `P-quick-button-T-375.png` | 行車中快速新增按鈕，位於回中心正上方 |
| `P-quick-confirmation-T-375.png` | 非阻擋確認卡、速限快選與復原 |
| `P-quick-navigation-T-375.png` | 確認卡＋導航橫幅同屏 |
| `P-quick-camera-T-375.png` | 確認卡＋照相橫幅同屏 |
| `P-quick-section-T-375.png` | 確認卡＋區間橫幅同屏 |
| `P-unset-T-375.png` | 速限未設詳情與修改入口 |
| `P-unset-edit-T-375.png` | 速限未設修改表單，不預填猜測速限 |
| `P-fixed-bottom-large-text-375.png` | 測速表單的備註／不阻擋警告 |
| `P-fixed-current-bottom-large-text-375.png` | 目前行向與警告底部 |
| `P-redLight-bottom-large-text-375.png` | 闖紅燈表單備註／警告 |
| `P-redLight-current-bottom-large-text-375.png` | 闖紅燈目前行向與警告底部 |
| `P-both-bottom-large-text-375.png` | 雙向表單備註／警告 |
| `P-modified-bottom-large-text-375.png` | 長詳情底部的還原動作 |
| `P-unset-edit-bottom-large-text-375.png` | 速限未設表單的備註底部 |

需下載真圖逐張確認：選單選項／按鈕不可截斷、≥44 pt、中性動作不似停用，長字可捲動；
另以 iOS 實際操作核對兩版的新增→修改→隱藏／復原→分享流程。尚未跑該 commit 的遠端建置／看圖，不得宣稱通過。
快速新增 gallery 不啟動真定位／背景反查／8 秒倒數，只示範相同按鈕、確認卡與橫幅元件；不讀寫個人檔案。

base64 預設關閉，需時加 `-f print-screenshots=true`。一般用 artifact，將 `RUN_ID` 換成該次執行編號：

```powershell
gh run watch RUN_ID --repo sigma449/speed_camera_warning --exit-status
gh run download RUN_ID --repo sigma449/speed_camera_warning -n screenshots -D build\h3\screenshots
gh run download RUN_ID --repo sigma449/speed_camera_warning -n ios15-screenshots -D build\h3\ios15
gh run download RUN_ID --repo sigma449/speed_camera_warning -n acceptance-summary -D build\h3\summary
gh run download RUN_ID --repo sigma449/speed_camera_warning -n SpeedCam-ipa -D build\h3\ipa
```

其他 artifact：`ci-data`（7 天）、`core-tests-evidence`／`pipeline-tests-evidence`、
`ios26-evidence`／`ios15-evidence`／`replay-1108-evidence`／`replay-1107-evidence`／`replay-tunnels-evidence`／`ipa-evidence`
（macOS 證據 14 天）、`search-stress`；獨立路線工作改從 `route-probe-evidence` 下載完整 route-probe 目錄。
IPA／資料與完整驗收摘要保留 30 天。非驗收 CI 摘要為 `ci-summary`。

手動 concurrency 按 workflow／ref／測試組合區分；route-probe 額外含 mode 與 cases，三組 replay 不互相取消。
同組新手動驗收可取消舊 run；不取消執行中的 tag 打包。reusable 子流程不另設相同群組，避免取消自己的 caller。

## 三組 replay 的檢查政策

`route-probe.sh` 的 replay 分支經 `run-replay.py` 保存 producer stdout＋stderr，再立即執行適用檢查器；
producer 或檢查器任一非零都讓 workflow 失敗，完整結論另存 `checker-result.json`／`checker.log`。

| 清單 | 必要檢查 |
|---|---|
| 1108 | 原 `check-replay-1108.py`，29 案、方向／語音／提示／全域覆蓋等既有要求完全保留 |
| 1107 | 全部指定案例、唯一開始結束、完整結尾、動作點 100%、區間進入→完成且不得中止／殘留；另核五個已隔離區間案例 |
| tunnels | 共通檢查＋同隧道推算預告與語音；非雪山另驗近距，雪山至少八個不同相機預告；辛亥完整區間生命週期 |

1107 五案是台64 西／東、自強南向、辛亥南／北；不把其他僅在名稱寫「經自強」但當天實際繞路的案例硬算必經。
隧道案無折返設定，`entered→aborted` 不能通過。舊 log 不改寫；既有東澳中止可能在真回放再次被揭露。

1108 仍以完整 `route_geometry`／分段折線獨立投影：缺段、假稱 `matched=false`、經過卻漏提醒／語音／navHint 均拒絕。
六個提示點可由不同案例覆蓋，但不能全跳過；必要短段保留起點餘量與前後 300 m 語音／畫面核對。
北宜八方向各需起點前 300 m 餘量的預告→進入→完成。水源校正須實際有 Apple 原文輸入，沒提供不算已驗到。
有 heading／axis 證據的熱點都核，最小夾角 >45° 才失敗；軸向不猜地名單向，折返不豁免方向。
IKEA 非測速例外、近鄰歧義與缺證據拒絕等既有條件保留。
E 已取消的區間內熱點禁報／相鄰 1,000 m 間隔不恢復。

H5（使用者 2026-11-16 決定）讓闖紅燈也走兩段；RouteProbe 的相機預告／近距新增 Core 實算的
`usesTwoStageAlert`，非測速科技近距必須有此資格，不在 Python 重寫中文取締項目比對。
原熱點近距禁令不改，另拒絕聲音照相近距、明載沒有兩段資格的近距，以及非測速近距卻標示超速。
舊測速／闖紅燈紀錄可不帶新欄位，但非測速科技近距不能缺少資格；其他語音、方向、IKEA、門架與全域覆蓋檢查不放寬。

## macOS 變更逐步／逐行對照

以下依實際腳本順序列命令與條件；沒有將 Linux 測試當成 iOS SDK 建置通過。
未列為改動的 App／Widget 建置目標、Release／Debug 用途、語言、展示等待及 runtime 安裝邏輯保持原狀。

### `_macos.yml` 每個 step

| 命令或條件 | 現在的行為／與原本的差異 |
|---|---|
| `timeout-minutes`／env | 一般 job 45、主步驟 35 分鐘；iOS15 為 60／50，留收證據時間。task／label／SHA／manifest／情境／mode／cases／runs／acceptance 明確傳入 |
| checkout `ref: github.sha` | 每台 runner 固定同個 commit；不再各自讀可能移動的 branch |
| `setup-python` | 明確 Python 3.12，不依 runner 預設版本 |
| download `ci-data` 的 `if` | iOS／IPA／replay 才取同輪包；stress、plan、compare 不抓資料 |
| `args=()`／IPA `--release` | IPA 強制發布政策；其他消費端核對同輪包，完整驗收的 prepare 已先要求可發布 |
| `data-bundle.py verify ... --install` | 核 commit、外傳 manifest hash 及各檔 hash 後才安裝；刪掉 macOS 重新下載及 repo 舊資料退路 |
| `mkdir`／`select-xcode.sh ... tee` | 保留原 Xcode 選擇，把 stdout／stderr 完整存 `xcode-selection.log`；pipefail 保留失敗 |
| `macos-job.sh ... tee` | 共用實際執行本體，完整輸出存 `run.log`；非零不再被後續輸出掩蓋 |
| `if: always()` 收集／record | 建置、啟動、截圖或檢查器失敗後仍嘗試取診斷；寫入當時 job 狀態、commit、manifest、情境、PNG 清單及 Python 版本 |
| 可選 base64 的 `if` | 只有明確啟用才印縮圖，預設不增加大量 log |
| 原始 PNG／搜尋 upload | always 保存已產出的內容，缺檔警告不是成功的 UI 證據 |
| `*-evidence` upload | 最後 always 上傳；包含完整建置 log、xcresult、工具版本、來源報告及整個 route-probe，不再只有 JSONL 或截圖前上傳 |
| `SpeedCam-data`／`SpeedCam-ipa` 的 `if` | 僅 IPA job 成功才發布；資料先上傳、IPA 後上傳。完整驗收 caller 的 needs 再保證所有必要工作先通過 |

### `macos-job.sh` 每條執行路徑

| 命令或條件 | 行為與退出碼 |
|---|---|
| `set -euo pipefail` | 未定義參數／命令失敗立即非零；tee 不吞 producer 失敗 |
| `case CI_TASK`／label 正規式 | 僅允許五種工作及小寫英數連字號 label，無效回 64 |
| `EVIDENCE`／`mkdir` | 每個 label 各自留證據，不混三組 replay |
| acceptance＋`none` | iOS26／15 完整驗收不能無截圖，回 64 |
| probe `case PROBE_MODE` | 僅 plan／compare／replay，無效回 64 |
| 內嵌 Python 檢查 cases | 必須是 repo `scripts/ci` 內既存 JSON，不能跳到任意檔案 |
| `export DATA_BUILD_LOG` | replay 檢查器收到的就是同輪資料來源／行向報告 |
| `route-probe.sh`／`exit 0` | 子命令失敗先由 `set -e` 退出；只有成功才到 exit，不是無條件成功 |
| `brew install xcodegen`／`xcodegen generate` | 保留實際產專案，不用舊 xcodeproj 或 DerivedData 快取取代建置 |
| CONFIGURATION／SDK／DESTINATION | iOS26／stress 為 Debug Simulator；iOS15 為 Release Simulator；IPA 為 Release iPhoneOS |
| `COMMAND=(xcodebuild ...)` | 保留 SpeedCam scheme（含 Widget）、unsigned、derivedDataPath；新增完整 `build.xcresult` |
| IPA signing 參數 | 延用 `CODE_SIGNING_REQUIRED=NO`／空 identity，不變成簽署發版 |
| `COMMAND ... tee build.log` | 直接使用 xcodebuild 真退出碼，完整首尾、warning／error 都留存，不 grep 節錄當唯一證據 |
| `APP_PATH` | 依實際 Configuration／SDK 決定，不共用 Debug／Release 二進位 |
| ios26 `screenshots.sh` | 傳情境，保留各情境原等待、最窄／大字及新舊地圖 |
| ios15 `check-min-os` | Release App 先驗最低版本及強連結相容性 |
| ios15 `install-ios15-runtime` | 原冷安裝腳本不改；B09 快取暫緩，沒有拿新版系統冒充 iOS15 |
| ios15 `ios15-run.sh` | 真 iPhone7／iOS15.5 模擬器，傳情境並嚴格驗存活／搜尋完成 |
| stress `search-stress.sh` | 傳 runs；任一輪未完成或無法確認便非零 |
| IPA `mkdir`／`cp -R` | 由本次 Release App 建 Payload，不拿以前 IPA |
| IPA `check-bundle-names`／`check-min-os` | 保留免費側載名稱與舊系統弱連結檢查 |
| IPA `verify --app-data` | zip 前驗內嵌 cameras 與測試包逐位元組相同且可發布 |
| IPA `zip` | 原未簽署 Payload 打包 |
| IPA `verify --ipa`／`cp manifest` | zip 後再驗、產 IPA 指紋，複製到 evidence 供最後摘要核對 |

### 模擬器與 RouteProbe 內部改動

| 位置／每段操作 | 行為變更與保留項 |
|---|---|
| `screenshots.sh`／`ios15-run.sh` 引入 capture-groups、none、各 `if selected` | 原情境只是分組，full 不包含 styles；未知情境回 64，沒有刪原截圖或大幅砍等待 |
| 兩腳本＋search-stress 寫 `simulator-udid.txt` | always 診斷可找回本次模擬器，不靠猜最後一台 |
| `assert_running` 的三次查詢 | 保存 launchctl 輸出；本輪 PID＋bundle 才成功；程序缺失回 1、三次查不到回 2，另嘗試留失敗圖 |
| `STRESS_START`／`check_search_finished` | JSON stdout 與 simctl stderr 分檔，保存真退出碼、列位元組數／PID／開始時間及錯誤片段；仍嚴格驗合法 JSON、本輪 PID／時間與完成訊息，完成後再查程序存活。空輸出、壞 JSON、查詢失敗或缺完成事件都不通過 |
| search-stress `failures`／最後 exit | 拒絕非正整數 runs；失敗輪數大於零回 1，不被診斷 echo 蓋成 0 |
| `route-probe.sh` swiftc 新增 deadline 檔 | 只編進 macOS probe；沒有把新 SDK API 加進 App |
| RouteProbe 指定車種 plan／replay 呼叫 | 整次 RoutePlanner.plan 最多 180 秒，包含實際車種重試路徑；底層原有 cancel handler 保留 |
| 搜尋 resolve／各呼叫端 | 傳案名，60 秒期限；取消會呼叫該次 MKLocalSearch.cancel，不用搜尋中心冒充結果 |
| deadline state／operation／timer／cancel | MainActor 單次續接；到期取消底層工作並回錯，不等待不合作子工作；晚到結果不能二次 resume |
| RouteProbe 最後 return | 全案例成功、動作點數大於零且 100% 相符才回 0；原探索用 plan／compare 不改嚴格度 |
| replay shell 分支 | producer 完整輸出先存檔，再跑分組檢查器，兩者任何非零都失敗 |
| `collect-diagnostics.py` | 每個查詢最多 90 秒；記版本、simctl、已知 UDID 的程序及兩小時 App log（含已保存的 info／debug）、相關 crash／CoreSimulator log；逾時保留已取得輸出並明列失敗 |

診斷工具失敗會留下退出碼／警告，不替代前面的存活或語意閘門；平台硬取消、整個 job 逾時或檔案系統失效時，
`always()` 不能保證補齊所有 artifact。B09 runtime 下載／修包快取未實作，也未共用跨 SDK／工具鏈的二進位。

## 本機契約與界線

快測試／僅 slow／全部測試、Swift 完整與 `--filter` 指令統一見根目錄
[`CLAUDE.md` 的「建置與測試」](../CLAUDE.md#建置與測試)。
日常跑快測試；改 `scripts\ci\` 或 workflow 另跑 slow。pytest.ini 預設以
`-m "not slow"` deselect，**不是 skip**；`_tests.yml` 用 `-m "slow or not slow"`，
因此 CI 的 Python job 仍執行全部，不因本機選取少驗。

H6 的量測發現：契約原本已把 sleep 換成空程式，主要成本是 Windows 為每個
sleep／xcrun／python3 替身反覆啟動 Bash。測試專用 `BASH_ENV` 將相同替身載為函式，
以子 shell 保留原 stdout／stderr／退出碼與程序隔離；仍保留可執行檔供 `command`／`exec` 使用。
`shell_workspace(wait_seconds=0)` 設定測試等待，也可在該次環境覆寫 `CI_CONTRACT_WAIT_SECONDS`。
假 simctl 另記住 create 的 iOS15 runtime，避免已完成的 UI marker 被誤當新系統而空輪詢60次。
只有治本後實測約超過5秒的個別參數案例標 slow；**正式 `.sh` 的內容、等待／輪詢次數完全沒改**。

追蹤版 Swift 入口為 `scripts\swift-test.py`，本機 `build\swift_test.py` 轉接它。
原始碼仍 bind mount `/pkg`、Resources 仍唯讀掛 `/SpeedCam/Resources`；
`/pkg/.build` 另掛 `speedcam-swift62-build-<checkout雜湊>` named volume，
以 `volume-nocopy` 避免首次複製 Windows 舊快取；不同 checkout 不共用編譯狀態。
volume 留供下次執行，其他 Swift 參數與退出碼原樣保留，沒有改 iOS15 runtime／Xcode 快取政策。

Python job 包含實際 shell＋假 simctl、固定小 replay log、YAML／依賴圖／摘要、假 xcodebuild 失敗與診斷逾時契約。
每週更新另外直接抽取 workflow 的 shell 執行，核對僅日期不同不改檔、相機／來源有變仍更新。
完整／7040 失聯 fixture 走真正 builder，再驗資料包到 `.app`／IPA ZIP；原始輸入有 LF 正規化雜湊。
容量展開為 509 點／72 段及降級 505 點／70 段（2026-11-16 加入兩個使用者街景確認的人工點後）；後者即使達數量仍不可發布。
另核斗六五候選→四點、銀河40、北宜門架、區間不能假造雙端等已核參考。
這是小型合成容量／流程契約，**不是完整7040原檔、F版82段新下載或實車 GPS**。

Swift 的新三項回歸在普通本機使用同一 builder 擷取的 7 點／21 段小 fixture；
CI 設 `SPEEDCAM_CURRENT_DATABASE_REQUIRED=1`，必須載入同輪完整 artifact，逐段驗預告→進入→完成及反向不進入，
不能因缺資料跳過或退回 fixture。RouteProbe 期限另有五項純 Swift 取消／晚到回歸。

歷次驗證原文與證據位置見 `HISTORY.md`，H6 的時間／選取／規格對照放 `build\stage-h6\`。
YAML／本機契約通過不是 GitHub 服務端、iOS SDK、真 simctl／MapKit、目視或實播證據；
新的 macOS 編譯、三組回放及外部資料仍須驗收者執行確認，不由 Copilot push／觸發。
