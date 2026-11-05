# CLAUDE.md：給 Claude Code 的專案說明

這個檔案會在每次開啟 Claude Code session 時自動讀取。內容是專案的背景、已經跟使用者確認過的決定、
目前進度和容易踩到的坑。**改了規格或完成重要工作時，請一併更新這個檔案。**

## 跟使用者溝通

- **所有對使用者說的話都用繁體中文（台灣用語）**，沒有例外：回覆、進度報告、等待中的簡短說明、提問、
  選項說明都一樣。使用者已經多次要求「中文說明」，不要因為前面的對話或工具輸出是英文就改用英文。
  程式碼、指令、檔名維持原樣，commit 訊息和文件也用繁體中文。
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
卡片的**位置也由系統決定**，查不到 App 或使用者可以調整的方式（評測文章看到在 Dashboard 右下角，Apple 文件沒有明講）。
要自己決定位置，只能等 Phase 2 的導航 App。

## 已確認的規格（改之前先問使用者）

- **兩段提醒**（每段只提醒一次）：一般道路預告 300 m、近距 100 m；照相點速限 ≥ 80 時預告 600 m、近距 200 m。距離依法規標示的設置距離決定，使用者認為 1,000 m 太遠。
- **超速警示**：接近照相點時超速，每 3 秒嗶一聲，直到降速或通過。一般照相的超速容許值預設 0。
- **方向判斷**：只提醒取締自己行車方向的照相點。開放資料的「雙向」照相點有軸向（南北／東西），兩個方向都提醒，橫向道路不提醒。
- **區間測速倒數**：顯示還要幾秒才能到終點；每分鐘語音一次，最後 30 秒、10 秒各一次，歸零時提醒。最短時間另加 3% 安全餘裕。
- **區間容許值**：預設 **+10**（例如北宜表定 40 → 以 50 計算），可調 0～**+20**，間隔 5。
  可以在「個別區間設定」頁**多選**區間另外設定；同一段的兩個方向共用設定（`SpeedSection.groupID` 會去掉 `-f`／`-r`）。
  倒數、區間內超速嗶聲、區間照相機前的超速嗶聲，都用同一個門檻。
- **區間建議時速**：剩餘距離 ÷ 剩餘最短秒數（以速限＋容許值、含安全餘裕），上限為速限＋容許值，無條件捨去。
  手機橫幅大字顯示（超過時變橘色）、每分鐘語音倒數一起念、Live Activity 顯示「建議≤N・均速 M」（最窄的 170 pt 放不下，改顯示「≤N・均 M」）。
- **北宜公路（台9線）**4 段雙向區間，表定 40：19–23.1K、26.2–32.2K、33.3–37.2K、**56.6**–68.6K（第 4 段經使用者確認是 56.6K）。
- **車種**：汽車／重機；重機路線避開國道與收費道路（`MKDirections` 的 `highwayPreference = .avoid`）。
- **Live Activity**：要大字（使用者覺得神盾的太小）。
- **主畫面橫幅不透明**（`BannerStyle`）：使用者同意的第一項 UI 收斂。底色不透明，地圖路名才不會透出來；
  有顏色的底色要夠深，白字對比至少 4.5:1，小字不要用 `.secondary`（紅底上會變成低對比的粉色）。
- **Live Activity 提醒**（`ActivityAlertPolicy`）：預告、近距、超速、進入區間、區間歸零時用 `alertConfiguration` 更新，
  一次定位只發一則；每分鐘倒數和持續嗶聲只靠聲音，不跳提醒。Apple 文件說 CarPlay 不在 Dashboard 頁面時會顯示成畫面底部的通知。
  聲音是系統預設音（文件沒有靜音選項），設定頁可以關（`liveActivityAlertsEnabled`，預設開啟）。
- **開啟 App 就自動開始巡航**（預設開啟，設定頁可以關；`AppPreferences.autoStartCruise`）。
- **搜尋目的地**：要像 Google 地圖那樣邊打字邊出現候選（`MKLocalSearchCompleter`），另有快速搜尋（加油站、停車場…）和最近的目的地（最多 15 筆）。
- **區間在地圖上順著路形畫**：資料處理用里程牌座標產生 `path`（[[緯度, 經度], ...]，Douglas–Peucker 簡化到 6 m），
  App 用 `SpeedSection.displayPath` 畫，沒有 path 時畫起終點直線；同一段的兩個方向只畫一次。
  使用者實機發現里程牌路形在髮夾彎會抄近路，所以 App 再用 Apple 地圖的路線規劃貼齊道路（`SectionPathSnapper`）：
  先試起點 → 終點一次規劃（長度 0.85～1.2 倍、偏離里程牌路形 ≤ 200 m 才採用），不行就沿路形每 1.2 km 分段規劃；
  結果存在 Application Support 的 `snappedSectionPaths.v1.json`，每段只算一次；請求間隔 1.5 秒，地圖中心附近的先做。
- **回到目前位置按鈕**（右下角，`MapFollowController`）：依車速縮放（`MapFollowCamera.distance`），預設行進方向朝上；
  跟隨中再按一次會依序切換「行進方向朝上 → 北方朝上 → 3D」，選擇會記住。巡航中由 App 自己算鏡頭（MapCamera），
  沒有定位時改用系統的 `.userLocation` 跟隨。
- **自動回到中心**（`AutoRecenterPolicy`）：使用者滑走地圖後，GPS 良好（精度 ≤ 30 m）、車速 ≥ 15 km/h 持續 5 秒、
  而且 10 秒沒碰地圖，就回到目前位置。使用者希望搭捷運或大眾運輸時不要跳回來：
  地下捷運和隧道通常沒有 GPS，所以不會觸發；地面或高架的捷運、台鐵、高鐵目前**分辨不出來**
  （iOS 的動作偵測把火車也算成「汽車」）。之後可以考慮用 TDX 的軌道路線線型判斷。
- **高架／平面標示**：資料處理用地址判斷 `level`（「高架」→ elevated；「高架下」「平面」→ surface；
  高架照相點 350 m 內沒標示的 → surface）。語音念「高架測速照相」「平面測速照相」，橫幅和地圖詳細資訊有標籤。
  **以後的可能性**：用 iPhone 氣壓計（CMAltimeter 相對高度）偵測上下匝道的高度變化，自動忽略另一層的照相點。
- **導航前先預覽**：選好目的地 → 地圖移到地點約 3 秒（或使用者點）→ 整條路線預覽 → 使用者按「開始導航」或倒數 10 秒後開始；
  預覽時拖動地圖就暫停倒數，隨時可取消（`AppModel.NavigationPreview`、`NavigationPreviewCard`）。
  預覽期間地圖上不畫照相點（使用者反映會擋到路線），區間線照常顯示。
- **搜尋與導航語言**放在設定頁最上面（中文／English／跟隨 iPhone），選完可按「立即重新開啟 App」
  （回到主畫面後結束，使用者再點圖示）。使用者的手機是英文，但搜尋和導航想用中文。
  CI 截圖已確認用 zh-Hant-TW 啟動時，搜尋候選和地圖路名都會變中文；地址格式跟著地區，所以同時設定 `AppleLocale`。
- **地圖與搜尋的語言**可以選「跟隨 iPhone／繁體中文／English」。MapKit 沒有指定語言的 API，
  所以寫入 App 自己的 `AppleLanguages`（跟 iOS「個別 App 語言」同一個機制），重新開啟 App 後生效。
  App 有 zh-Hant 和 en 兩個 lproj，兩邊的顯示名稱都是「測速地圖」。

## UI 設計原則（按鈕、提醒文字、橫幅）

新增或修改畫面時照這些原則。部分參考 [taste-skill](https://github.com/Leonxlnx/taste-skill)（MIT，2.5.0）的通用原則，
再依開車情境調整。**不要安裝或直接套用那個 skill**：它是做公司網站的，工具也只能檢查網頁。
現有畫面還沒有全部符合（見「已知問題／待辦」的 UI 收斂）；規格已確認的內容，要改還是先問使用者。

- **開車時看一眼就懂（最優先）**：一個畫面只有一個最重要的資訊，大字只給它（距離、倒數秒數）。其他用小字，用不到就拿掉。
- **按鈕**：
  - 全 App 同一套按鈕樣式和圓角。不用顏色區分功能，顏色只表示狀態。
  - 一個畫面只有一個主要動作，只有它用強調色，不要同時出現兩個綠色按鈕。
  - 灰色只給真的不能按的按鈕，可以按的不要看起來像停用。
  - 主要動作的文字用「動詞＋受詞」（開始導航、結束導航）。圖示按鈕要有 `accessibilityLabel`，點擊範圍至少 44 pt。
- **提醒文字**：
  - 白話、短句，單獨看就懂（「區間時間已到」，不是「通知」）。
  - 同一件事只說一次，同一個畫面裡用同一種說法。
  - 不要只靠顏色傳達，超速要同時有文字（「超速！」）。
  - 放不下時先換短文字，再縮字，不要讓重要資訊被截斷。
- **顏色和對比**：
  - 顏色有固定意義，不要挪用：紅＝超速、黃＝接近照相點、橘＝區間倒數或要注意、綠＝正常或可依速限。
  - 疊在地圖上的底色不透明，白字對比至少 4.5:1，小字不用 `.secondary`（用 `BannerStyle`）。
- **版面**：同一類元件同一種外觀，框裡面最多再一層框，左右邊界對齊。
- **動畫**：只用來回應操作，不做裝飾性動畫，也要顧及「減少動態效果」。
- **驗證**：
  - 實際看過截圖才算完成，不能只看程式碼。新的畫面或狀態要加進 CI 截圖或 `-gallery`，而且要確認真的拍到。
  - 用最窄的尺寸和最長的文字測試（最長的路名、照相類型）。
- **不採用**（網站才需要，或不適合開車）：滑鼠移過去的動畫、一個區塊佔滿一屏、真實照片、Google Fonts（用系統字型）、
  隨機發配色、shader 和捲動特效。

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
- `-gallery`：Live Activity 預覽頁（加 `-galleryMiddle`、`-galleryBottom` 從頁面中段、底部開始顯示）
- `-search 文字`：打開搜尋並輸入
- `-mapCenter 緯度,經度 -mapSpan 度數`：指定地圖範圍
- `-settings`：打開設定頁
- `-previewTo 緯度,經度,名稱`：導航預覽
- `-typeSearch 文字`：搜尋壓力測試（反覆輸入、刪除約 45 秒）
- `-autoStartCruise NO`：不自動巡航

## 建置與測試

- **Swift 核心邏輯**（80 個測試）：
  `docker run --rm -v "$PWD/Packages/SpeedCamCore":/pkg -w /pkg swift:6.2-noble swift test`
  （雲端 session 裡 Docker 沒在跑的話先執行 `dockerd &`。）
- **Python 資料處理**（162 個測試）：`python3 -m pytest -q data-pipeline`
- **iOS App** 只能在 GitHub Actions 編譯：
  - `CI`（每次 push）：Swift 測試、pytest、iOS 模擬器建置和截圖。截圖會以 base64 印在 log 裡（`scripts/ci/print-screenshots.sh`），因為雲端 session 下載不了 artifact。
  - `Build IPA`（手動）：`gh workflow run build-ipa.yml --repo sigma449/speed_camera_warning --ref main`。會下載最新資料、編譯未簽署的 IPA（artifact `SpeedCam-ipa`，保留 30 天）。
  - `Refresh camera data`（每週一）：資料有變動就開 PR。需要 repo 設定開啟「Allow GitHub Actions to create and approve pull requests」（2026-11-05 用 GitHub API 確認已開啟）。
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
  「下」應該是指附近往建國南路、光復南路的下匝道，不是「高架下方」。目前用「高架／平面」標示讓駕駛判斷（見上方規格）。
- **SwiftUI 清單不要用 `ForEach(array.indices)` 再用索引取資料**：資料一直更新、數量變少時會超出範圍閃退。
  使用者在中文介面搜尋「台北車站」時閃退，CI 壓力測試（`-typeSearch`）重現；改成 `SearchSuggestion`／`SearchResultRow` 這種自帶 id 的資料。
  修正後完整 CI 與「搜尋壓力測試」流程（`search-stress.yml`，手動觸發，約 8 分鐘）連跑 3 次都沒有閃退。
- **`Int(...)` 轉換無限大或 NaN 會閃退**：距離、偏差這類可能是 `.infinity` 的值，轉成 Int 前先限制範圍。
- **CI 截圖的啟動參數會被吃掉**：巡航中的 App 被結束後，iOS 會在背景重新叫起它（背景定位），
  下一次 launch 只會把它帶到前景。`screenshots.sh` 的 `launch_app` 會先結束兩次，不需要巡航的截圖加 `-autoStartCruise NO`。
- **剛啟動時太早開 sheet 或改地圖範圍會被系統忽略**：CI 截圖用的啟動參數改在 `.task` 裡等 1.2 秒再做。

## Git

- 單人專案，直接 commit 到 `main` 再 push。`Build IPA` 是手動觸發的 workflow，要在預設分支上才會出現在 Actions 頁面。
- commit 訊息用繁體中文：第一行寫做了什麼，內文寫原因。

## 目前進度和下一步（2026-11-05）

1. **最新 IPA**：Build IPA run 41809928606（`main` 5afbe8e）。包含：
   - 中文搜尋閃退修正
   - 區間建議時速
   - 區間貼齊道路
   - 導航前預覽（預覽時隱藏照相點）
   - 搜尋與導航語言切換
   - 回到目前位置／自動回到中心
   - 高架／平面標示
2. **等使用者實機回報**：
   - 上述功能
   - 提醒時機、方向誤報
   - 北宜區間開始／結束的時機
   - CarPlay 儀表板上的 Live Activity
3. **已知問題／待辦**：
   - 部分快速道路區間貼齊失敗，保留里程牌路形：台61 157.8–151.6、41.5–46.9；台64 1.6–5.4；台9 110.96–108.224。
   - 大眾運輸偵測（TDX 軌道線型）、氣壓計判斷高架／平面：未做。
   - App 被 iOS 背景重新叫起（巡航中被系統結束）時不會自動恢復巡航，可考慮實作。
   - UI 收斂（橫幅不透明已做，其餘等實車測試後由使用者決定）：
     導航預覽時隱藏底部按鈕，「取消」改中性色；底部按鈕統一樣式，停止鍵不要像停用；
     區間橫幅精簡重複的資訊（動到已確認的規格，要先問）；`-gallery` 加入最長文字的壓力測試。
   - 之後依使用者決定進行 Phase 2（付費帳號、CarPlay 導航）或 Phase 3（重機停車）。
4. **新 session 接手**：
   - 先讀本檔和 `docs/SETUP.md`。
   - 改了搜尋就跑 `search-stress.yml`。
   - 改了 UI 就看 CI 截圖：base64 在 log 裡，用 `=====BEGIN-SCREENSHOT` 區塊解碼。
   - 確認沒問題再跑 Build IPA，把 artifact 連結給使用者。
