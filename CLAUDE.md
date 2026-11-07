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

以地圖為主的**台灣測速照相提醒 App**（iPhone），汽車和機車都能用。跟神盾那類「只有提醒畫面」的 App 不同，主畫面是地圖。

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
- **近距語音只念距離**（2026-11-07 使用者要求）：預告過的照相點，近距只念「100公尺」。第一次提醒就已經在近距內時才念完整的句子。
- **超速警示**：接近照相點時超速，每 3 秒嗶一聲，直到降速或通過。一般照相的超速容許值預設 0。
- **方向判斷**：只提醒取締自己行車方向的照相點。開放資料的「雙向」照相點有軸向（南北／東西），兩個方向都提醒，橫向道路不提醒。
- **區間預告**（2026-11-07 使用者要求，實測進去之後才提醒太晚）：接近起點時預告一次，距離和照相點相同（區間速限 ≥ 80 為 600 m，其他 300 m）。
  語音「前方300公尺，進入區間測速，速限70」，橫幅和 Live Activity 沿用照相點的版面（`SectionApproach.asCameraTarget`）。
  要從起點後方、順著進入方向接近才算（`isHeadingToStart`），反方向和橫向路過不提醒；分不出平行的平面道路。
- **進入區間的判定**（`SectionSpeedTracker`）：通過起點 60 m 判定範圍時開始計時。GPS 跳過判定範圍、匝道在起點後才併入時，走在區間前 300 m 也算進入，開始時間依車速往回推。
  起點 300 m 之後才上路（照相機沒拍到起點）不算進入。
- **隧道裡沒有定位**：App 每秒呼叫 `SectionSpeedTracker.tick`，超過 2.5 秒沒有定位就依最後的車速和時間推算：經過起點、倒數、語音都繼續，定位回來再接上。
- **區間照相機**：落在已知區間路線 300 m 內的區間照相機不再當固定照相提醒（`CameraAlertEngine.isCoveredBySection`），由預告和倒數處理；否則自強隧道中段那支會在隧道裡才跳出來。
  資料沒有對應區間的（無法解析的那些）仍然照一般照相提醒。
- **區間測速倒數**：顯示還要幾秒才能到終點；每分鐘語音一次，最後 30 秒、10 秒各一次，歸零時提醒。最短時間另加 3% 安全餘裕。
- **區間容許值**：預設 **+10**（例如北宜表定 40 → 以 50 計算），可調 0～**+20**，間隔 5。
  可以在「個別區間設定」頁**多選**區間另外設定；同一段的兩個方向共用設定（`SpeedSection.groupID` 會去掉 `-f`／`-r`）。
  倒數、區間內超速嗶聲、區間照相機前的超速嗶聲，都用同一個門檻。
- **區間建議時速**：剩餘距離 ÷ 剩餘最短秒數（以速限＋容許值、含安全餘裕），上限為速限＋容許值，無條件捨去。
  手機橫幅大字顯示（超過時變橘色）、每分鐘語音倒數一起念、Live Activity 顯示「建議≤N・均速 M」（最窄的 170 pt 放不下，改顯示「≤N・均 M」）。
- **北宜公路（台9線）**4 段雙向區間，表定 40：19–23.1K、26.2–32.2K、33.3–37.2K、**56.6**–68.6K（第 4 段經使用者確認是 56.6K）。
- **車種**：汽車／紅黃牌機車／白牌機車（`VehicleMode`，2026-11-06 使用者決定）。舊設定的 `motorcycle` 對應到白牌，行為不變。規則在 `RouteRules`：
  - **紅黃牌**：避開國道和收費道路，可以走快速道路和市區高架。做法：只避開收費並要多條路線，排除有收費或走國道的路線，都不行才退回避開高速。
    不能用 `highwayPreference = .avoid`（Apple 的 highway 連快速道路和市區高架都算）；只避開收費又會走免費國道（實測國 2、4、6、8、10 都會），所以要比對線形。
  - **白牌**：只走平面道路。避開高速和收費，再排除 Apple 不算 highway 的高架和快速道路（`data-pipeline/manual/white_plate_restricted.csv`，例如新生高架、洲美快速道路）。
  - **比對國道**（`RoadMatcher`、`Resources/road_lines.json`，資料來自 OSM）：連續 ≥ 800 m 而且距離中位數 ≤ 10 m 才算走在上面。平行的側道會連續幾公里都在 30 m 內（宜蘭的縣道 191 和國 5），所以要看中位數。
    只比平面座標，分不出高架和正下方的平面道路，所以只有 Apple 標示有高速路段的路線才比對國道。線形載入失敗時，紅黃牌退回只走平面道路。
  - 找不到符合規則的路線時，用問題最小的一條，預覽卡片和重新規劃時會提醒。路線仍是用汽車的路網規劃，不知道哪些路段禁行機車，設定頁有說明。
- **舊手機支援**（2026-11-07 使用者要求）：使用者想用 iPhone 7（iOS 15.8.8）測 App 內的功能，所以 App 最低 iOS 15。
  **iOS 17 以上走原本的程式**，舊系統的替代做法集中在 `LegacySupport`：地圖用 `LegacyMapView`（MKMapView）、定位用 CLLocationManager、
  iOS 16.2 以前沒有 Live Activity（設定頁也不顯示）、iOS 18 以前打開搜尋不會自動跳鍵盤。
  iOS 15 不能要求 Apple 避開高速或收費（`highwayPreference`、`tollPreference`），也看不到路線有沒有這些路段（`hasHighways`、`hasTolls`），
  所以高速路段當作有、一定比對國道線形，白牌一定跳提醒，也可能走到快速道路或高架。設定頁有寫。**機車路線要用 iOS 16 以上的手機判斷。**
  Widget Extension 維持 iOS 26，舊系統會裝 App 但不會載入它（iOS 15.5 模擬器確認裝得上）。
- **Live Activity**：要大字（使用者覺得神盾的太小）。
- **區間橫幅只放三行**（使用者看實機覺得字太多，2026-11-06 同意精簡）：
  「區間倒數 N 秒」（使用者指定的寫法，秒數最大，不要「還要」「才能到終點」）、
  建議時速（太快時變橘色，文字改成「請放慢：建議 N 以下」）、「均速 M・剩 Xkm」。
  區間名稱（真實資料 27～32 字）和「以 N 計算」不顯示。
- **其他畫面也要精簡**（2026-11-06 使用者要求）：
  - 不顯示「巡航中」（使用者認為開車時沒有幫助），巡航只顯示車速和「km/h・汽車」。
  - Live Activity 超速時小字只有「超速！」，不再加照相類型。
  - 鎖定畫面巡航時，右邊不重複顯示車速。動態島展開時，速限標誌或圖示只放左上角、車速放右上角，下方只有大字和小字；巡航時不顯示右上角的車速。
  - 照相點橫幅用 `Camera.shortAddress`：18 字以內用原文，太長才拿掉括號內容、多段只留第一段；詳細資訊卡仍顯示完整地址。
- **主畫面橫幅不透明**（`BannerStyle`）：使用者同意的第一項 UI 收斂。底色不透明，地圖路名才不會透出來；
  有顏色的底色要夠深，白字對比至少 4.5:1，小字不要用 `.secondary`（紅底上會變成低對比的粉色）。
- **導航文字縮短**（2026-11-07 使用者要求）：CarPlay、鎖定畫面和手機橫幅顯示「動作＋路名」（`ManeuverText.short`），例如「靠右 上五股楊梅高架」「下交流道 95A出口」；語音仍念 Apple 的完整句子。
  區間和照相模式下，轉彎點 300 m 內小字改顯示下一步（`SpeedCamActivityState.navHint`，超速時先顯示超速）。
- **偏離路線**：離路線 50 m 持續 5 秒，或方向差 50° 以上、離路線 30 m 持續 3 秒（路口轉錯比較快發現）。還沒回到路線上每 15 秒再規劃一次；重新規劃中畫面不顯示舊路線的下一步。
- **Live Activity 開始和更新**：開始失敗會每 5 秒重試（只能在前景開始，剛開 App 太早會被拒絕）；App 重開時接著用已經在跑的，不結束再開；更新不排隊，只留最新一筆；距離和車速最多每 2 秒更新；接上 CarPlay（音訊路徑出現 carAudio）時主動更新一次；設定頁顯示目前狀態和失敗原因。
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
  App/                       AppModel（中心狀態）、SettingsView、SectionToleranceView（個別區間設定）、AdaptiveViews（新舊系統 API 不同的元件）
  Map/ Navigation/ Location/ Alerts/ LiveActivity/ Data/
  Map/LegacyMapView          iOS 15、16 的地圖（MKMapView）。改了 RootView 的地圖內容，這裡也要改
  Data/LegacySupport         舊系統的做法和 -legacyUI 開關
  Resources/cameras.json     內建資料。repo 裡是空的佔位檔，Build IPA 時才下載真實資料
  Resources/road_lines.json  國道和白牌限制道路的線形（OSM）。直接放在 repo，有新路段時手動跑 build_road_lines.py
  Resources/zh-Hant.lproj/   InfoPlist.strings：主畫面的中文名稱「測速地圖」
SpeedCamWidgets/             Widget Extension（Live Activity 畫面）
Shared/                      App 與 Widget 共用的 ActivityAttributes 和畫面
Packages/SpeedCamCore/       核心邏輯（純 Swift，可以在 Linux 測試）
  CameraAlertEngine          兩段提醒、超速、方向、冷卻；區間照相機會找 500 m 內的區間套用個別容許值
  SectionSpeedTracker        區間倒數；在最接近起點時才開始計時，避免提早觸發
  AlertSettings              所有可調設定和預設值（App 儲存在 UserDefaults 的 alertSettings.v2）
  AnnouncementFormatter      中文語音文字
  RouteRules、RoadMatcher    各車種怎麼選路線、路線有沒有走在某組道路上（App 的 RoutePlanner 只負責和 MapKit 溝通）
data-pipeline/               Python（只用標準函式庫）：開放資料 → cameras.json；OSM → road_lines.json
docs/SETUP.md                安裝教學（iloader＋SideStore）和 Windows 疑難排解
scripts/ci/                  CI 用的腳本（選 Xcode、截圖、檢查 App 名稱）
```

App 的啟動參數（CI 截圖用）：
- `-demo`：展示模式
- `-demoIfEmpty`：沒有資料時改用展示資料
- `-gallery`：Live Activity 預覽頁（加 `-galleryMiddle`、`-galleryBottom` 從頁面中段、底部開始顯示）
- `-gallery -galleryBanners`：手機橫幅預覽頁，用真實資料裡最長的文字（可再加 `-galleryBottom`）
- `-gallery -galleryLock`：鎖定畫面和動態島展開的預覽頁，動態島外框是示意（可再加 `-galleryBottom`）
- `-search 文字`：打開搜尋並輸入
- `-mapCenter 緯度,經度 -mapSpan 度數`：指定地圖範圍
- `-settings`：打開設定頁
- `-vehicleMode car|motorcycleRedYellow|motorcycleWhite`：指定車種（不會存進設定）
- `-previewTo 緯度,經度,名稱`：導航預覽
- `-typeSearch 文字`：搜尋壓力測試（反覆輸入、刪除約 45 秒）
- `-autoStartCruise NO`：不自動巡航
- `-legacyUI`：在新系統上也走舊系統的做法（地圖、定位、NavigationView、不要求避開高速），CI 截圖用

## 建置與測試

- **Swift 核心邏輯**（144 個測試）：
  `docker run --rm -v "$PWD/Packages/SpeedCamCore":/pkg -w /pkg swift:6.2-noble swift test`
  （雲端 session 裡 Docker 沒在跑的話先執行 `dockerd &`。）
- **Python 資料處理**（174 個測試）：`python3 -m pytest -q data-pipeline`。
- **iOS App** 只能在 GitHub Actions 編譯：
  - `CI`（每次 push）：Swift 測試、pytest、iOS 模擬器建置和截圖。截圖會以 base64 印在 log 裡（`scripts/ci/print-screenshots.sh`），因為雲端 session 下載不了 artifact。
  - `Build IPA`（手動）：`gh workflow run build-ipa.yml --repo sigma449/speed_camera_warning --ref main`。會下載最新資料、編譯未簽署的 IPA（artifact `SpeedCam-ipa`，保留 30 天）。
  - `Refresh camera data`（每週一）：資料有變動就開 PR。需要 repo 設定開啟「Allow GitHub Actions to create and approve pull requests」（2026-11-05 用 GitHub API 確認已開啟）。
  - `路線實測`（手動，約 5 分鐘）：`gh workflow run route-probe.yml --repo sigma449/speed_camera_warning --ref main -f mode=plan -f cases=scripts/ci/route-probe-cases.json`。不用建置 App，在 macOS 上直接編譯 App 的 `RoutePlanner` 和 `SpeedCamCore`，用真正的 MapKit 規劃台灣路線。改了選路規則或 `road_lines.json` 就跑一次。
    `mode=plan` 看三種車種實際選到哪條路；`mode=compare` 比較不同避開設定 Apple 回傳的路線。`route-probe-elevated.json` 沿著各條快速道路和高架規劃，用來確認 Apple 算不算 highway。結果在 log 和 artifact `route-probe`（含步驟文字和路線座標）。
    **`mode=replay`（模擬開車）**：`-f mode=replay -f cases=scripts/ci/route-replay-1107.json`。沿著 Apple 的路線每秒給一筆定位，用真實的照相點和區間資料跑核心程式，印出每個語音和提醒的位置，並檢查每個動作點畫面顯示的對不對（log 最後有「相符 N／M」）。隧道裡不給定位，只呼叫 `tick`。改了提醒、區間或導航就跑一次；使用者回報實測問題時，把路線加進清單就能重現。
  - `iOS 15 實際執行`（手動，約 20 分鐘）：`gh workflow run ios15-test.yml --repo sigma449/speed_camera_warning --ref main`。從 Apple 官方 CDN 安裝 iOS 15.5 模擬器（不用登入），在 iPhone 7 模擬器上實際開啟 App 並截圖。改了舊系統的程式就跑一次。截圖一樣在 log 裡。
- 用 `gh run watch <id> --exit-status` 等結果，`gh run view <id> --log` 讀 log。
- 環境：runner `macos-26`、Xcode 26.6、App 最低 iOS 15.0、Widget 最低 iOS 26.0、`SWIFT_VERSION 5.0`、`SWIFT_STRICT_CONCURRENCY minimal`。
  `Build IPA` 會執行 `scripts/ci/check-min-os.sh`，檢查最低版本，也檢查沒有強連結到 iOS 15 沒有的函式庫（否則一開就閃退，編譯時看不出來）。

## 資料來源

- **照相點**：內政部警政署「測速執法設置點」（data.gov.tw 資料集 **7320**，從 opdadm.moi.gov.tw 下載），整理後約 **1,887 處**。
  欄位：CityName、RegionName、Address、DeptNm、BranchNm、Longitude、Latitude、direct、limit。
- **里程牌**：公路局「省道里程坐標」（資料集 **7040**，約 27,000 處），把「台9線 19K」這類里程換算成座標和進入方向。
  經緯度欄位是「坐標-E-WGS84」「坐標-N-WGS84」。
- **區間測速**（目前 **79 段** = 人工 18 段＋自動 61 段）：
  - `data-pipeline/manual/sections.csv`：人工維護。北宜（座標寫回 CSV）；台64 中和段（兩個方向範圍不同，分成兩個群組）；自強、辛亥、中仁、仁水隧道（座標是 OSM 的隧道兩端，實際照相位置沒有公告；長度見 CSV 註解）。
  - `manual/section_lengths.csv`：警方公告的偵測長度，依行駛方向（from_km → to_km）蓋過里程差。來源是新北市警局「區間平均速率執法設備設置地點一覽表」（1140919 修訂，`traffic.police.ntpc.gov.tw`）。**開放資料的範圍可能是錯的**：台64 寫「25.2k至28.2k（雙向）」，公告往西只有 28.2K→26.6K。其他縣市的公告還沒查。
  - `speedcam_data/section_text.py`：從開放資料「設置地點」的文字自動產生，例如「台9線68k+600m至56k+600m」。
    離照相點超過 3 km 視為解析錯誤；同一筆裡至少一段通過時，其他段放寬到 15 km。
  - `manual/sections_text.csv`：開放資料沒有、但立法院附件清單（2026-05）有的區間。
  - **還沒有區間的**（只有一個當固定照相提醒的點）：縣道、市道、只寫路名的，例如鳳鼻隧道（OSM 查不到）、金門大橋、市道 182、新店環河路、新莊壽山路（新北市公告有長度，要找起訖座標）。
- **其他清單**（查照相點有沒有漏時用）：臺北市警察局「固定式違規照相設備及區間測速裝置設置地點一覽表」（資料集 **130111**，約 143 處，有座標和方向）；立法院附件全國清單（`ppg.ly.gov.tw`，2026-05）。PDF 用 `pdftotext -enc UTF-8 -layout`。

## 容易踩到的坑

- **`MKRoute.Step` 的指示描述的是這一步「走完時」的動作**，不是開始時。距離 982 m 的「右轉進入環河北路」是開 982 m 之後右轉。
  84 條實測路線：指示裡的左右轉和步驟終點的實際轉向相符 96%，和起點只有 45%。以前寫反，所有提示都提早一步（使用者實測：右轉民生西路時顯示右轉吉林路），模擬實際路線修改前只有 7／55 正確。
- **`MKRoute.Step.distance` 和折線長度差到 2.3%**：轉彎點要用每一步折線的實際長度（`MapItems.stepInfos`），否則開到後面會差幾百公尺。
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
- **App 最低 iOS 15 帶來的限制**：
  - 不能用 `@Observable`（要 iOS 17），狀態用 `ObservableObject`。新系統才有的 API 要包 `#available`，型別不能直接當儲存屬性（存成 `Any` 或 `AnyObject`）。
  - `@ViewBuilder` 一層最多 10 個子項（超過要 iOS 17）。設定頁的 `Form` 已經剛好 10 個，再加要用 `Group` 包。
  - `.onChange` 用一個參數的舊寫法（兩個參數的要 iOS 17）。
  - 新的 SF Symbols 舊系統沒有，畫面會空白；編譯時看不出來，要有備用圖示（`Symbols`）。
- **`MKAnnotationView.image` 不能直接放 SF Symbol**：它用符號圖的黑色底圖，上的顏色都會不見，要先畫成點陣圖。
- **CI 腳本不要寫 `指令 | grep -q`**：`grep -q` 比對到就結束，配上 `pipefail` 會因為 SIGPIPE 判斷成失敗，曾經把正常的 App 誤判成閃退。先存成變數再比對。

## Git

- 單人專案，直接 commit 到 `main` 再 push。`Build IPA` 是手動觸發的 workflow，要在預設分支上才會出現在 Actions 頁面。
- commit 訊息用繁體中文：第一行寫做了什麼，內文寫原因。

## 目前進度和下一步（2026-11-07）

1. **最新 IPA**：Build IPA run 42366929114（`main` 59d5739，artifact 13571942466，2026-12-07 到期）。79 段區間、1,887 處照相點，App 最低 15.0、Widget 26.0。包含 2026-11-07 實測問題的修正（見下一項）。
2. **2026-11-07 第一次長程實測的 12 個問題**（長春路→自強隧道→中油陽明山站→秀朗橋上台64→板橋文化路→長春路，約 60 km，紀錄不在 repo）：
   - **第 11、9 項（轉彎提示錯一步、閘道沒提示）**：指示文字的語意寫反。模擬開車修改前 7／55，修改後 72／72（路線多加 3 段）。修好但要實機確認：Apple 有時候沒有上閘道那一步（2026-11-06 的紀錄）。
   - **第 5 項（自強隧道）**：資料解析不了，只有隧道中段一個固定照相點。現在是真的區間，隧道口前 300 m 預告，隧道裡依時間倒數。起終點用 OSM 的隧道口，實際照相位置要看現場。
   - **第 10 項（台64）**：開放資料的範圍是錯的，往西是 28.2K→26.6K。現在有預告，終點正確。起點仍是里程牌的 28.2K（併入主線後約 360 m），使用者說提醒晚約 150 m，要看現場有沒有差。
   - **第 7、12 項（近距語音、CarPlay 文字）**：已改，截圖和單元測試確認。
   - **第 2 項（重新規劃）**：原本只要求一次，失敗或被擋掉就卡在舊路線。已修，單元測試確認，實際速度要實機看。
   - **第 1、6 項（CarPlay 沒顯示、更新慢）**：找到程式問題（開始失敗不重試、更新排隊）並修正，但模擬器沒有重現「沒顯示」，CI 也驗證不了 CarPlay。設定頁有「目前狀態」可以看原因。**要實機確認。**
   - **第 3 項（iPhone 7 和 12 Pro 提示位置不同）**：同一條汽車路線 iOS 15.5 和 iOS 26 拿到的步驟完全相同（CI log 的 `route plan steps`），排除路線不同。修了累積誤差，原因還沒確定，也還沒確認使用者說的是路上還是畫面上的位置。
   - **第 4、8 項（至善路一段、國安局前的照相點沒收錄）**：警政署 7320、臺北市 130111（2026-03 更新）、立法院 2026-05 清單都沒有這兩支，OSM 也沒有。**等使用者提供位置**，再加進 `manual/cameras_extra.csv`。國安局在 25.1073,121.5360 附近，Apple 的路線經過 25.1058,121.5374。
3. **等使用者實機回報**（使用者只有週末能上車測）：
   - iPhone 7（iOS 15.8.8）：2026-11-07 使用者回報裝得上、開起來正常。還沒回報：背景定位、語音、實機的流暢度
   - 主力手機：狀態管理改成 `ObservableObject` 之後，地圖跟隨順不順（CI 截圖看不出動畫）
   - 上述功能
   - 地圖上的車種選單（CI 點不了選單，沒拍到打開的樣子）；紅黃牌和白牌實際規劃的路線；偏離路線重新規劃時會不會換回同一種走法
   - 提醒時機、方向誤報
   - 北宜區間開始／結束的時機
   - CarPlay 儀表板上的 Live Activity：實際位置、有沒有持續更新、車機用哪個尺寸
   - 不在 Dashboard 頁面時，接近照相點會不會跳底部通知；提示音和語音有沒有重疊。
     CI 驗證不到這些。沒有跳通知的話，先查通知權限：App 目前沒有要求，Apple 文件也沒說需不需要。
4. **已知問題／待辦**：
   - 隧道出口的固定照相（例如辛亥路4段辛亥隧道出口）：隧道裡沒有定位時，模擬到定位恢復才提醒，只剩 22 m。區間已經依時間推算，固定照相還沒有。
   - 區間預告分不出平行的平面道路（高架下的平面道路也會預告）。
   - 只有新北市的區間用公告長度，其他縣市的公告還沒查。還沒有區間的見「資料來源」。
   - 部分快速道路區間貼齊失敗，保留里程牌路形：台61 157.8–151.6、41.5–46.9；台64 1.6–5.4；台9 110.96–108.224。
   - 大眾運輸偵測（TDX 軌道線型）、氣壓計判斷高架／平面：未做。
   - App 被 iOS 背景重新叫起（巡航中被系統結束）時不會自動恢復巡航，可考慮實作。
   - UI 收斂（文字精簡已做，其餘由使用者決定）：
     導航預覽時隱藏底部按鈕，「取消」改中性色；底部按鈕統一樣式，停止鍵不要像停用。
   - 機車路線的實測紀錄（2026-11-06，`路線實測` plan 模式 run 42184382128，28 條路線，週五下午）：
     - **結果**：紅黃牌和白牌都沒有收費、沒有走國道（另外用未簡化的 OSM 線形和導航文字各檢查一次）。台北車站→新竹車站：汽車 84 分（國道）、紅黃牌 96 分（台64＋台61＋台68）、白牌 142 分。
     - **白牌有 4 條跳提醒**：台北→新竹（一小段環河南路快速道路的匝道）、台北→花蓮和深坑→辛亥路（信義快速道路），這 3 條是真的走到；板橋→永和（環河西路貼著新北環河快速道路）很可能是誤判。
     - **怎麼判斷的**：真的走國道時，每一段和線形的距離中位數最多 6.1 m；平行的道路大多超過 10 m，只有一段 7.7 m。有條路線上了國 2 卻完全沒寫（「繼續往航站北路前進」之後就是 19.9 km 的「從18號出口下交流道」），所以不能只看導航文字。
     - **誤判的方向**：平面道路貼著白牌限制道路會被排除或提醒；紅黃牌偶爾會多排除一條路線（台北→花蓮的縣道 191 那段距離 7.7 m）。結果只是路線變慢或多一則提醒，不會走到國道。
     - **沒有驗證**：哪些路段禁行機車、各種牌照實際能走哪些路（法規各來源說法不一，使用者決定紅黃牌可走快速道路和高架，要依現場標誌）；iPhone 實機；白牌限制道路清單只涵蓋實測過的路；竹南到新竹的台61 平面段 Apple 不算 highway，白牌會走。
     - **線形來源**：高公局的路段線型（資料集 166264，`tisvcloud.freeway.gov.tw`）從使用者電腦和 GitHub runner 都連不上（2026-11-06），所以用 OSM，沒有和官方資料交叉比對。OSM 是 ODbL 授權，設定頁有出處。
   - 之後依使用者決定進行 Phase 2（付費帳號、CarPlay 導航）或 Phase 3（重機停車）。
5. **新 session 接手**：
   - 先讀本檔和 `docs/SETUP.md`。
   - 改了搜尋就跑 `search-stress.yml`。
   - 改了提醒、區間或導航就跑 `路線實測` 的 replay 模式。
   - 改了 UI 就看 CI 截圖：base64 在 log 裡，用 `=====BEGIN-SCREENSHOT` 區塊解碼。
   - 確認沒問題再跑 Build IPA，把 artifact 連結給使用者。
