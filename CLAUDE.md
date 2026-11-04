# CLAUDE.md：給 Claude Code 的專案說明

這個檔案會在每次開啟 Claude Code session 時自動讀取。內容是專案的背景、已經跟使用者確認過的決定、
目前進度和容易踩到的坑。**改了規格或完成重要工作時，請一併更新這個檔案。**

## 跟使用者溝通

- 一律用**繁體中文（台灣用語）**回覆。
- 使用者**沒有 Mac**，用 Windows 電腦和 iPhone。會寫程式，但不熟 iOS。
  所以 iOS 的編譯、測試、截圖都靠 GitHub Actions 的 macOS runner，不能要求使用者在本機跑 Xcode。
- 使用者想先**免費**測試（沒有 Apple Developer Program），用 iloader＋SideStore 側載。
- 文件和說明要具體：寫實際的按鈕名稱和指令，不確定的畫面細節寫「依畫面指示」，不要編造。

## 專案是什麼

以地圖為主的**台灣測速照相提醒 App**（iPhone），汽車和重機都能用。跟神盾那類「只有提醒畫面」的 App 不同，主畫面是地圖。

| 階段 | 內容 | 狀態 |
|---|---|---|
| Phase 1 | iPhone App：地圖、巡航、導航（MapKit 逐向導航）、測速提醒、區間倒數；CarPlay 先用 iOS 26 的 Live Activity 顯示 | ✅ 完成，使用者正在安裝測試 |
| Phase 2 | 加入 Apple Developer Program（US$99／年）→ TestFlight → 申請 CarPlay **導航** entitlement → CarPlay 上的地圖 | 未開始 |
| Phase 3 | 重機停車模式（TDX 停車資料＋人工整理／使用者回報） | 未開始 |

CarPlay 的限制：只有「導航」類 App 能畫地圖，而且必須提供逐向導航；一個 App 只能屬於一個類別。
Live Activity 在 iOS 26 會出現在 CarPlay 儀表板，**不需要 entitlement**；尺寸由系統固定（240×78、240×100、170×78 pt），
所以用 `.supplementalActivityFamilies([.small])` 和 `@Environment(\.activityFamily)` 自訂大字版面。

## 已確認的規格（改之前先問使用者）

- **兩段提醒**（每段只提醒一次）：一般道路預告 300 m、近距 100 m；照相點速限 ≥ 80 時預告 600 m、近距 200 m。距離依法規標示的設置距離決定，使用者認為 1,000 m 太遠。
- **超速警示**：接近照相點時超速，每 3 秒嗶一聲，直到降速或通過。一般照相的超速容許值預設 0。
- **方向判斷**：只提醒取締自己行車方向的照相點。開放資料的「雙向」照相點有軸向（南北／東西），兩個方向都提醒，橫向道路不提醒。
- **區間測速倒數**：顯示還要幾秒才能到終點；每分鐘語音一次，最後 30 秒、10 秒各一次，歸零時提醒。最短時間另加 3% 安全餘裕。
- **區間容許值**：預設 **+10**（例如北宜表定 40 → 以 50 計算），可調 0～**+20**，間隔 5。
  可以在「個別區間設定」頁**多選**區間另外設定；同一段的兩個方向共用設定（`SpeedSection.groupID` 會去掉 `-f`／`-r`）。
  倒數、區間內超速嗶聲、區間照相機前的超速嗶聲，都用同一個門檻。
- **北宜公路（台9線）**4 段雙向區間，表定 40：19–23.1K、26.2–32.2K、33.3–37.2K、**56.6**–68.6K（第 4 段經使用者確認是 56.6K）。
- **車種**：汽車／重機；重機路線避開國道與收費道路（`MKDirections` 的 `highwayPreference = .avoid`）。
- **Live Activity**：要大字（使用者覺得神盾的太小）。
- **開啟 App 就自動開始巡航**（預設開啟，設定頁可以關；`AppPreferences.autoStartCruise`）。
- **搜尋目的地**：要像 Google 地圖那樣邊打字邊出現候選（`MKLocalSearchCompleter`），另有快速搜尋（加油站、停車場…）和最近的目的地（最多 15 筆）。
- **區間在地圖上順著路形畫**：資料處理用里程牌座標產生 `path`（[[緯度, 經度], ...]，Douglas–Peucker 簡化到 6 m），
  App 用 `SpeedSection.displayPath` 畫，沒有 path 時畫起終點直線；同一段的兩個方向只畫一次。
- **地圖與搜尋的語言**可以選「跟隨 iPhone／繁體中文／English」。MapKit 沒有指定語言的 API，
  所以寫入 App 自己的 `AppleLanguages`（跟 iOS「個別 App 語言」同一個機制），重新開啟 App 後生效。
  App 有 zh-Hant 和 en 兩個 lproj，兩邊的顯示名稱都是「測速地圖」。

## 程式結構

```
project.yml                  XcodeGen 設定（.xcodeproj 不進 repo，CI 會產生）
SpeedCam/                    iPhone App（SwiftUI、@Observable AppModel）
  App/                       AppModel（中心狀態）、SettingsView、SectionToleranceView（個別區間設定）
  Map/ Navigation/ Location/ Alerts/ LiveActivity/ Data/
  Resources/cameras.json     內建資料。repo 裡是空的佔位檔，Build IPA 時才下載真實資料
  Resources/zh-Hant.lproj/   InfoPlist.strings：主畫面的中文名稱「測速地圖」
SpeedCamWidgets/             Widget Extension（Live Activity 畫面）
Shared/                      App 與 Widget 共用的 ActivityAttributes 和畫面
Packages/SpeedCamCore/       核心邏輯（純 Swift，可以在 Linux 測試）
  CameraAlertEngine          兩段提醒、超速、方向、冷卻；區間照相機會找 500 m 內的區間套用個別容許值
  SectionSpeedTracker        區間倒數；在最接近起點時才開始計時，避免提早觸發
  AlertSettings              所有可調設定和預設值（App 儲存在 UserDefaults 的 alertSettings.v2）
  AnnouncementFormatter      中文語音文字
data-pipeline/               Python（只用標準函式庫）：開放資料 → cameras.json
docs/SETUP.md                安裝教學（iloader＋SideStore）和 Windows 疑難排解
scripts/ci/                  CI 用的腳本（選 Xcode、截圖、檢查 App 名稱）
```

App 的啟動參數（CI 截圖用）：
- `-demo`：展示模式
- `-demoIfEmpty`：沒有資料時改用展示資料
- `-gallery`：Live Activity 預覽頁
- `-search 文字`：打開搜尋並輸入
- `-mapCenter 緯度,經度 -mapSpan 度數`：指定地圖範圍

## 建置與測試

- **Swift 核心邏輯**（58 個測試）：
  `docker run --rm -v "$PWD/Packages/SpeedCamCore":/pkg -w /pkg swift:6.2-noble swift test`
  （雲端 session 裡 Docker 沒在跑的話先執行 `dockerd &`。）
- **Python 資料處理**（152 個測試）：`python3 -m pytest -q data-pipeline`
- **iOS App** 只能在 GitHub Actions 編譯：
  - `CI`（每次 push）：Swift 測試、pytest、iOS 模擬器建置和截圖。截圖會以 base64 印在 log 裡（`scripts/ci/print-screenshots.sh`），因為雲端 session 下載不了 artifact。
  - `Build IPA`（手動）：`gh workflow run build-ipa.yml --repo sigma449/speed_camera_warning --ref main`。會下載最新資料、編譯未簽署的 IPA（artifact `SpeedCam-ipa`，保留 30 天）。
  - `Refresh camera data`（每週一）：資料有變動就開 PR。需要 repo 設定開啟「Allow GitHub Actions to create and approve pull requests」（使用者是否已開啟：未確認）。
- 用 `gh run watch <id> --exit-status` 等結果，`gh run view <id> --log` 讀 log。
- 環境：runner `macos-26`、Xcode 26.6、iOS 26.0 deployment target、`SWIFT_VERSION 5.0`、`SWIFT_STRICT_CONCURRENCY minimal`。

## 資料來源

- **照相點**：內政部警政署「測速執法設置點」（data.gov.tw 資料集 **7320**，從 opdadm.moi.gov.tw 下載），整理後約 **1,887 處**。
  欄位：CityName、RegionName、Address、DeptNm、BranchNm、Longitude、Latitude、direct、limit。
- **里程牌**：公路局「省道里程坐標」（資料集 **7040**，約 27,000 處），把「台9線 19K」這類里程換算成座標和進入方向。
  經緯度欄位是「坐標-E-WGS84」「坐標-N-WGS84」。
- **區間測速**（目前 **71 段** = 人工 8 段＋自動 63 段）：
  - `data-pipeline/manual/sections.csv`：人工維護（北宜），座標和進入方向已經寫回 CSV，不依賴里程牌下載。
  - `speedcam_data/section_text.py`：從開放資料「設置地點」的文字自動產生，例如「台9線68k+600m至56k+600m」。
    離照相點超過 3 km 視為解析錯誤；同一筆裡至少一段通過時，其他段放寬到 15 km。
  - `manual/sections_text.csv`：開放資料沒有、但立法院附件清單（2026-05）有的區間。
  - **無法自動解析**：縣道、市道、只寫隧道或路名的（例如鳳鼻隧道、蘇花改仁水和中仁隧道、自強和辛亥隧道、金門大橋、市道 182）。

## 容易踩到的坑

- **Info.plist 的 `CFBundleDisplayName`／`CFBundleName` 只能用英數字**：SideStore 會拿它向 Apple 註冊 App ID，
  有中文會出現「invalid value … for the parameter 'appIdName'」。中文名稱放 `zh-Hant.lproj/InfoPlist.strings`。
  `scripts/ci/check-bundle-names.sh` 會在 Build IPA 時檢查。
- **免費帳號的限制**：同時最多 3 個側載 App（SideStore 算 1 個）；每 7 天最多 10 個 App ID，這個 App 用 2 個（主程式＋Widget）。
  不能用 App Groups 和推播（APNs），所以 Live Activity 只能由 App 在本機更新。
- **macOS runner 的 Python 3.13** 下載政府資料時會出現憑證錯誤（Missing Subject Key Identifier）：
  `sources.ssl_context()` 關閉了 `VERIFY_X509_STRICT`，憑證鏈仍然會驗證。
- **資料下載失敗時**：Build IPA 會改用 repo 裡的 cameras.json，但那是空的，所以會停止建置。這是刻意的。
- **SideStore 登入錯誤 -80045**（2026-10 起 Apple 的變更）：處理方式寫在 `docs/SETUP.md` 的常見問題。
- **高架道路與平面道路**：App 只用經緯度和方向判斷，分不出高架和平面，兩者重疊的路段會互相誤報。
  例如市民大道：高架照相點（速限 80）和平面照相點（市民大道三段 214 號前，速限 40）只差約 250 m。
  原始資料的「市民高架道下建國南路」「市民高架道下光復南路」是**高架上的照相點**：速限 80、東西雙向，平面道路速限只有 40～50。
  「下」應該是指附近往建國南路、光復南路的下匝道，不是「高架下方」。這個問題還沒處理。

## Git

- 單人專案，直接 commit 到 `main` 再 push。`Build IPA` 是手動觸發的 workflow，要在預設分支上才會出現在 Actions 頁面。
- commit 訊息用繁體中文：第一行寫做了什麼，內文寫原因。

## 目前進度和下一步（2026-11-04）

1. 使用者已經用 iloader 裝好 SideStore，也裝好 App（appIdName 錯誤已修正，App 名稱改成英文 SpeedCam）。
2. 使用者在室內試用後的回饋（2026-11-04）：
   - 希望打開就開始偵測
   - 搜尋要有自動完成
   - 地圖與搜尋的語言要能調整
   這三項已經實作，等 CI 和新的 IPA。
3. 遠端還有臨時分支 `tools/inspect-shimin`（檢查市民高架資料用）。雲端 session 的代理擋下刪除，要請使用者在 GitHub 網頁上刪除。
4. 請使用者實際上路測試，回報這些情況：
   - 提醒的時機
   - 方向誤報
   - 北宜區間開始和結束的時機
   - CarPlay 儀表板上 Live Activity 的顯示
5. 之後再依使用者的決定進行 Phase 2（付費帳號、CarPlay 導航）或 Phase 3（重機停車）。
