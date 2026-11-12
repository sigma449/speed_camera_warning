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
- **近距語音**（11/08 第二階段 A 已核准）：已預告過的照相點，當下同目標超速時念「100公尺，超速」，沒有超速只念「100公尺」；高速門檻照實際設定念「200公尺」，太近則念實距。讀目前超速狀態，不依賴同秒的開始事件；合句時不另念一則超速語音。第一次提醒已在近距內時仍保留完整句子與既有超速語音，這個分支等使用者決定。
- **超速警示**：接近照相點時超速，每 3 秒嗶一聲，直到降速或通過。一般照相的超速容許值預設 0。
- **方向判斷**：只提醒取締自己行車方向的照相點。開放資料的「雙向」照相點有軸向（南北／東西），兩個方向都提醒，橫向道路不提醒。
- **區間預告**（2026-11-07 使用者要求，實測進去之後才提醒太晚）：接近起點時預告一次，距離和照相點相同（區間速限 ≥ 80 為 600 m，其他 300 m）。
  語音「前方300公尺，進入區間測速，速限70」，橫幅和 Live Activity 沿用照相點的版面（`SectionApproach.asCameraTarget`）。
  要從起點後方、順著進入方向接近才算（`isHeadingToStart`），反方向和橫向路過不提醒；分不出平行的平面道路。
- **進入區間的判定**（`SectionSpeedTracker`）：通過起點 60 m 判定範圍時開始計時。GPS 跳過判定範圍、匝道在起點後才併入時，走在區間前 300 m 也算進入，開始時間依車速往回推。
  起點 300 m 之後才上路（照相機沒拍到起點）不算進入。
- **區間中迴轉**：只有精度 ≤30 m、連續可靠定位、行向與局部道路反向，而且沿路進度至少持續後退 5 秒／60 m 才中止；退回起點前超過 60 m 並持續 3 秒也可中止。發 `.aborted`、清超速，不套五分鐘完成冷卻；之後必須實際經過起點才能重入，不能在段內用 late-entry 重新啟動。沒有可靠路形時只用退回起點的判定；GPS 跳點、失聯和髮夾彎不能只憑方位差中止。
  - **第二階段 C 修正**：稀疏里程牌在髮夾彎會形成相近／交叉的直線。先選最近投影再驗連續性；有正向候選、投影失配或失聯就清反向證據，段內重新取得正向證據後才累積反向，退回起點延伸線仍可重新確認。5 秒／60 m、3 秒／60 m、精度門檻都不改。中途離開的距離保護取公告長度與資料路形長度的較大值，原有 600／1,000 m 餘量不變；不改倒數與公告偵測長度。永久 fixture 覆蓋舊 IPA 全部 79 段（71 有 path、8 走直線），另重現北宜 4 回程原事件定位；不能把插值說成完整實車 GPS。
- **隧道裡沒有定位**：App 每秒呼叫 `SectionSpeedTracker.tick` 和 `CameraAlertEngine.tick`，超過 2.5 秒沒有定位就依最後的車速和時間推算：經過區間起點、倒數、語音、照相的預告和近距都繼續，定位回來再接上（2026-11-07 使用者同意固定照相也這樣做）。
  - 誤差超過 100 m 或沒有車速的定位（隧道裡的基地台定位，`VehicleFix.isReliable`）當作沒有定位，不交給這兩個核心。
  - 固定照相用「最後一筆定位到照相點的直線距離，減掉走過的距離」，不推算位置：隧道有弧度（雪山隧道偏離直線 600 m），直線距離比實際路程短，誤差是提早提醒。
  - 地址寫隧道的（資料裡 54 支，含區間）最遠算到 15 km，不是對向就算；其他只算 1.5 km 內、前方 30° 內的，否則平行道路會誤報（雪山隧道入口旁的宜3線），搭捷運進地下也會一直提醒。最後車速低於 20 km/h 不推算（停車場）。
  - 「通過」要等定位回來才判斷；車速是舊的，所以不嗶，超過 10 秒就結束超速狀態。
- **區間照相機**：落在已知區間路線 300 m 內的區間照相機不再當固定照相提醒（`CameraAlertEngine.isCoveredBySection`），由預告和倒數處理；否則自強隧道中段那支會在隧道裡才跳出來。
  中仁隧道的已核實相機以 `sectionGroupID=zhongren-tunnel` 明確關聯，不放寬全域半徑；資料沒有對應區間的仍照一般照相提醒，建置報告列出全部清單。
- **區間測速倒數**：顯示還要幾秒才能到終點；每分鐘語音一次，最後 30 秒、10 秒各一次，歸零時提醒。最短時間另加 3% 安全餘裕。
- **區間容許值**：預設 **+10**（例如北宜表定 40 → 以 50 計算），可調 0～**+20**，間隔 5。
  可以在「個別區間設定」頁**多選**區間另外設定；同一段的兩個方向共用設定（`SpeedSection.groupID` 會去掉 `-f`／`-r`）。
  倒數、區間內超速嗶聲、區間照相機前的超速嗶聲，都用同一個門檻。
- **區間超速節流**（11/08 第二階段 A 已核准）：獨立的 `sectionOverspeedBeepInterval` 預設 15 秒、`sectionOverspeedVoiceInterval` 預設 30 秒；49／51 km/h 抖動不重設冷卻。歸零後清區間超速狀態，不再發區間門檻的語音／嗶聲；App 和 Live Activity 共用 `SectionStatus.isOverspeed`。固定照相仍每 3 秒，不受歸零影響；容許值及 3% 安全餘裕不變，歸零不是允許超過道路速限。這輪不新增設定頁控制項。
- **區間建議時速**：剩餘距離 ÷ 剩餘最短秒數（以速限＋容許值、含安全餘裕），上限為速限＋容許值，無條件捨去。
  手機橫幅大字顯示（超過時變橘色）、每分鐘語音倒數一起念、Live Activity 顯示「建議≤N・均速 M」（最窄的 170 pt 放不下，改顯示「≤N・均 M」）。
- **北宜公路（台9線）**4 段雙向區間，表定 40：19–23.1K、26.2–32.2K、33.3–37.2K、**56.6**–68.6K（第 4 段經使用者確認是 56.6K）。
  前三段改用 126156 各方向不同的官方門架及公告長度，`beiyi-N-f/r`／`groupID`／既有容許值保留；第 4 段不在 126156，仍用里程牌端點並明列資料缺口。接回里程牌路形前先裁掉門架之外的點，不能先往回接線而把進入方向算反。
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
- **同屏橫幅比例（第二階段 B）**：照相、導航、區間共用 64 pt 圖示欄、46 pt 主要數字、56 pt 主要行槽及 176 pt 最小高度，從上方對齊；長文字可撐高，不能硬鎖高度。區間仍維持三行。375／390 pt 與放大文字的同屏圖尚待 CI 實看。
- **導航文字縮短**（2026-11-07 使用者要求）：CarPlay、鎖定畫面和手機橫幅顯示「動作＋路名」（`ManeuverText.short`），例如「靠右 上五股楊梅高架」「下交流道 95A出口」；語音仍念 Apple 的完整句子。
  區間和照相模式下，轉彎點 300 m 內小字改顯示下一步（`SpeedCamActivityState.navHint`，超速時先顯示超速）。
- **「上高速公路」校正**（11/08 第二階段 A 已核准）：只有動作點之後的接續路形能唯一對上 `road_lines.json` 具名非國道主線時，畫面和完整語音一起改成「上＋路名」，例如「左轉上水源快速道路，朝(永和)、景美前進」／短句「左轉 上水源快速道路」。`RoadInstructionResolver` 在 Core 判斷；國道、平行／橫跨、入口太短、未知或多名稱有歧義都保留 Apple 原文，不猜。
- **人工導航補充提示**（第二階段 C，使用者已提供位置）：`RouteHintMatcher` 只在導航規劃折線依序通過提示點及後續確認點、進入行向相符時補一步；反向、別的分支、平行道路、多次繞回造成歧義、未導航都不提示。現有 5 筆涵蓋 6 個標記：建國下高架、師大地下道、水源南向出口＋秀朗橋分岔、環河地下道、回程上水源。水源兩點僅約 37 m，合成「下匝道 不上秀朗橋」，語音另交代靠右往環河路。
  - 共用既有轉彎提前距離、語音優先順序與各門檻不重播；提示在起點時不在「開始導航」額外念第二次。`RouteProgress.maneuverText` 保留人工短句，手機橫幅及 Live Activity 共用，300 m 內的 `navHint` 與超速優先規則不變。
  - 只取代 40 m 內且符合資料列 `replace_text` 的已核實誤導 Apple 原文；其他 Apple 步驟及動作點位置保留。載入失敗明列警告與系統 log，暫用 Apple 導航，不靜默忽略。
  - 新增方式：編輯 `data-pipeline\manual\route_hints.csv`，填行向、後續點（至少相距 20 m）、12～15 m 匹配半徑、短句／語音／來源；OSM 沒有的車道資訊標「依使用者實測」。必要的取代片段以 `|` 分隔，不能空白萬用比對。執行 `python -I -X utf8 data-pipeline\build_route_hints.py` 並一併提交 `SpeedCam\Resources\route_hints.json`；pytest 檢查兩者完全一致。新增 OSM 分支正／反例及 replay 提示點檢查，不憑座標猜橋上橋下。
- **偏離路線**：離路線 50 m 持續 5 秒，或方向差 50° 以上、離路線 30 m 持續 3 秒（路口轉錯比較快發現）。還沒回到路線上每 15 秒再規劃一次；重新規劃中畫面不顯示舊路線的下一步。
- **Live Activity 開始和更新**：開始失敗會每 5 秒重試（只能在前景開始，剛開 App 太早會被拒絕）；App 重開時接著用已經在跑的，不結束再開；更新不排隊，只留最新一筆；距離和車速最多每 2 秒更新；接上 CarPlay（音訊路徑出現 carAudio）時主動更新一次；設定頁顯示目前狀態和失敗原因。
- **滑掉 App（第二階段 B）**：保留背景巡航；初次 request 與每次更新都設 120 秒 `staleDate`。Widget 各版型（含 `.small` 與動態島）過期顯示「已停止更新」，不再顯示舊車速、距離、倒數或超速底色；過期不等於移除。重開會接手 active／stale 活動，若這次不巡航或已關 Live Activity，就結束殘留活動。按「停止巡航」一併取消預覽與每秒工作、重設核心；要移除卡片可回 App 停止巡航或在鎖定畫面滑掉卡片。不能靠強制結束時收尾清理。
- **Live Activity 提醒**（`ActivityAlertPolicy`）：預告、近距、超速、進入區間、區間歸零時用 `alertConfiguration` 更新，
  一次定位只發一則；每分鐘倒數和持續嗶聲只靠聲音，不跳提醒。Apple 文件說 CarPlay 不在 Dashboard 頁面時會顯示成畫面底部的通知。
  聲音是系統預設音（文件沒有靜音選項），設定頁可以關（`liveActivityAlertsEnabled`，預設開啟）。
- **開啟 App 就自動開始巡航**（預設開啟，設定頁可以關；`AppPreferences.autoStartCruise`）。
- **搜尋目的地**：要像 Google 地圖那樣邊打字邊出現候選（`MKLocalSearchCompleter`），另有快速搜尋（加油站、停車場…）和最近的目的地（最多 15 筆）。
- **地圖選點（第二階段 B）**：iOS 17 以上用 `MapFeature`，iOS 16 的 MKMapView 用 `selectableMapFeatures`；所有版本都能長按任意位置，iOS 15 只有長按。先顯示名稱、地址或原始座標的選點卡，按「開始導航」才進既有地點 3 秒／路線 10 秒預覽，不直接開始導航。導航中與預覽中一律停用選點，照相點仍開詳細資訊；預覽仍隱藏照相點。選點卡開啟時暫停跟隨／自動回中心、隱藏底部操作與回中心按鈕，只留一個主要動作。反查失敗明列提示與 log、仍可用原座標；取消或改選後的舊結果不能覆蓋新點。POI、長按、相機分流及清晰度仍待 iOS 實際操作／截圖驗收。
- **區間在地圖上順著路形畫**：資料處理用里程牌座標產生 `path`（[[緯度, 經度], ...]，Douglas–Peucker 簡化到 6 m），
  App 用 `SpeedSection.displayPath` 畫，沒有 path 時畫起終點直線；同一段的兩個方向只畫一次。
  使用者實機發現里程牌路形在髮夾彎會抄近路，所以 App 再用 Apple 地圖的路線規劃貼齊道路（`SectionPathSnapper`）：
  先試起點 → 終點一次規劃（長度 0.85～1.2 倍、偏離里程牌路形 ≤ 200 m 才採用），不行就沿路形每 1.2 km 分段規劃；
  結果存在 Application Support 的 `snappedSectionPaths.v2.json`，依方向別 `section.id` 和有順序的精確起終點簽章驗證；端點變更就重算，不再讀 v1，也不以 `groupID` 跨方向套用。每個方向只算一次；請求間隔 1.5 秒，地圖中心附近的先做。貼齊結果同步交給區間核心，不重設正在跑的倒數。
- **回到目前位置按鈕**（右下角，`MapFollowController`）：依車速縮放（`MapFollowCamera.distance`），預設行進方向朝上；
  跟隨中再按一次會依序切換「行進方向朝上 → 北方朝上 → 3D」，選擇會記住。巡航中由 App 自己算鏡頭（MapCamera），
  沒有定位時改用系統的 `.userLocation` 跟隨。
- **地圖對照（第二階段 B，未選新預設）**：內部 `MapAppearance` 支援 `current` 純藍線、`whiteCasing` 白框、`darkCasing` 黑框，及 `current`／`muted` 底圖；只用啟動參數、不持久化。藍線仍 7 pt、預覽 8 pt／0.85，描邊各向外 3 pt；新舊地圖的橘色區間線都在導航線下方。MKMapView 的 muted 限 iOS 16 以上，iOS 15 維持原底圖。3D 選擇、55° 與高度樣式不改，對照圖待驗收者決定。
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
- `-gallery -galleryBanners -galleryBannerPair camera|section|zero|rerouting -galleryWidth 375|390`：固定顯示導航＋照相／區間／歸零，或重新規劃＋照相；用最長路名及類型，CI 新增 `29`～`34` 同屏／放大字截圖
- `-gallery -galleryBanners -galleryHints`：內建人工提示的手機橫幅及 170×78 pt 導航／照相＋navHint 預覽；可加 `-galleryBottom`，本輪尚未取得截圖
- `-gallery -galleryLock`：鎖定畫面和動態島展開的預覽頁，動態島外框是示意（可再加 `-galleryBottom`）
- `-gallery -galleryStale`：已停止更新的 `.small` 三種尺寸；再加 `-galleryLock` 顯示鎖定畫面及動態島。CI 新增 `27-stale-activity-lock.png`、`28-stale-activity-small.png`，尚待截圖驗收
- `-gallery -galleryPlaces`：375 pt 選點卡版面示例，含長名稱／地址、反查中、反查失敗；加 `-galleryBottom` 拍下半部。這是狀態預覽，不代表已操作 POI 或長按
- `-search 文字`：打開搜尋並輸入
- `-mapCenter 緯度,經度 -mapSpan 度數`：指定地圖範圍
- `-settings`：打開設定頁
- `-vehicleMode car|motorcycleRedYellow|motorcycleWhite`：指定車種（不會存進設定）
- `-previewTo 緯度,經度,名稱`：導航預覽
- `-selectPlace 緯度,經度,名稱`：走正式選點狀態與反查地址，顯示選點卡、尚未開始預覽；與 `-previewTo` 同時指定時以預覽優先。CI 新增 `39`／`40` 新舊地圖選點卡、`41`／`42` 卡片狀態、`43`／`44` POI＋相機＋區間同屏及 `ios15-15`；不把此參數當成手勢測試
- `-routeLineStyle current|whiteCasing|darkCasing`、`-mapEmphasis current|muted`：新舊地圖的內部對照樣式，不存進設定；未指定就是原樣
- `-routeComparison preview|navigation3D` 搭配 `-previewTo`：CI 固定起點 `(25.0468,121.5366)`；前者停住整線預覽、後者開始導航並固定 700 m／朝南／55° 視角，不改一般預覽倒數。`35`／`36` 各六張，`37`／`38` 舊地圖及 `ios15-14` 檢查備案；同組路線簽章不符就失敗
- `-typeSearch 文字`：搜尋壓力測試（反覆輸入、刪除約 45 秒）
- `-autoStartCruise NO`：不自動巡航
- `-legacyUI`：在新系統上也走舊系統的做法（地圖、定位、NavigationView、不要求避開高速），CI 截圖用

## 建置與測試

- **Swift 核心邏輯**（206 個測試）：本機既有入口 `python -I -X utf8 build\swift_test.py`。Docker 必須同時唯讀掛載 `SpeedCam\Resources` 到 `/SpeedCam/Resources`，不能只掛套件而讓真實道路或人工提示測試跳過；第二階段 B 的 206 項全通過，0 跳過。CI／原生 Swift 用 `swift test --package-path Packages/SpeedCamCore`。
- **Python 資料處理與 replay 檢查器**（274 個測試）：`python -m pytest -q data-pipeline`，第二階段 B 全通過，0 跳過。
- **iOS App** 只能在 GitHub Actions 編譯：
  - `CI`（每次 push）：Swift 測試、pytest、iOS 模擬器建置和截圖。截圖會以 base64 印在 log 裡（`scripts/ci/print-screenshots.sh`），因為雲端 session 下載不了 artifact。
  - `Build IPA`（手動）：`gh workflow run build-ipa.yml --repo sigma449/speed_camera_warning --ref main`。會下載最新資料、編譯未簽署的 IPA（artifact `SpeedCam-ipa`，保留 30 天）。
  - `Refresh camera data`（每週一）：資料有變動就開 PR。需要 repo 設定開啟「Allow GitHub Actions to create and approve pull requests」（2026-11-05 用 GitHub API 確認已開啟）。
  - `路線實測`（手動，約 5 分鐘）：`gh workflow run route-probe.yml --repo sigma449/speed_camera_warning --ref main -f mode=plan -f cases=scripts/ci/route-probe-cases.json`。不用建置 App，在 macOS 上直接編譯 App 的 `RoutePlanner` 和 `SpeedCamCore`，用真正的 MapKit 規劃台灣路線。改了選路規則或 `road_lines.json` 就跑一次。
    `mode=plan` 看三種車種實際選到哪條路；`mode=compare` 比較不同避開設定 Apple 回傳的路線。`route-probe-elevated.json` 沿著各條快速道路和高架規劃，用來確認 Apple 算不算 highway。結果在 log 和 artifact `route-probe`（含步驟文字和路線座標）。
    **`mode=replay`（模擬開車）**：`-f mode=replay -f cases=scripts/ci/route-replay-1107.json`。沿著 Apple 的路線每秒給一筆定位，用真實的照相點和區間資料跑核心程式，印出每個語音和提醒的位置，並檢查每個動作點畫面顯示的對不對（log 最後有「相符 N／M」）。隧道裡不給定位，只呼叫 `tick`。改了提醒、區間或導航就跑一次；使用者回報實測問題時，把路線加進清單就能重現。
    `route-replay-tunnels.json` 專門測隧道（辛亥、文山、懷恩、萬里、過港、東澳、雪山），可以用 `tunnelSpeedFactor` 模擬隧道裡車速變慢，提醒後面會印實際離照相點多遠。隧道範圍在 `route-probe.swift` 的 `tunnels`。
    **11/08 驗收**：`route-replay-1108.json` 的 23 案包含同核心折返、歸零後折返及同向歸零續行。第二階段 C 強制北宜 1～4 雙向完整進入／完成，所有非折返案例不准中途離開，並核對生命週期、全案例數、原有市區照相仍提醒、全案例節流等不變性；原北宜 2 四個官方門架獨立比對保留。不中斷案例改以 MapKit 搜尋「台北市中山區長春路128號」及「坪林 7-ELEVEN」，快取同一對結果供回程反向，印實際門市／地址／座標；門市尚待驗收者核對，搜尋失敗直接失敗、不用搜尋中心冒充。
    `REPLAY1108 ` 的 `hint_check` 逐一列六點的完整路線最近距離、Apple 前後步驟、當時下一步、前後 300 m 語音候選、補充短句及觸發情況；另比對實際 `nav_hint`／`nav_speech` 事件，未經過或不同分支明列「未涵蓋」並非零，不當成通過。replay 的 JSONL 保存完整折線，不再只保留 50 m 取樣。完整回放後執行 `python -I -X utf8 scripts\ci\check-replay-1108.py build\replay-1108-r3.log`，支援 UTF-16 BOM。**舊 `build\replay-1108-fixed.log` 已被新檢查器拒絕（北宜 4 回程誤中止，另缺新提示點報告）**。驗收者提供的 r3 log 六點在不中斷案例已有覆蓋，但補測 03 從提示點開始而失敗（62／63）；B 輪保留 23 案及原門檻，改從 r3 去程 t792、提示點前約 735 m 的位置開始。新起點尚待 macOS 重跑，不修改舊 log，人工 log 單測不能充當驗收。
  - `iOS 15 實際執行`（手動，約 20 分鐘）：`gh workflow run ios15-test.yml --repo sigma449/speed_camera_warning --ref main`。從 Apple 官方 CDN 安裝 iOS 15.5 模擬器（不用登入），在 iPhone 7 模擬器上實際開啟 App 並截圖。改了舊系統的程式就跑一次。截圖一樣在 log 裡。
- 用 `gh run watch <id> --exit-status` 等結果，`gh run view <id> --log` 讀 log。
- 環境：runner `macos-26`、Xcode 26.6、App 最低 iOS 15.0、Widget 最低 iOS 26.0、`SWIFT_VERSION 5.0`、`SWIFT_STRICT_CONCURRENCY minimal`。
  `Build IPA` 會執行 `scripts/ci/check-min-os.sh`，檢查最低版本，也檢查沒有強連結到 iOS 15 沒有的函式庫（否則一開就閃退，編譯時看不出來）。

## 資料來源

- **照相點**：內政部警政署「測速執法設置點」（data.gov.tw 資料集 **7320**，從 opdadm.moi.gov.tw 下載），整理後約 **1,900 處**（11/12 原始資料離線核對為 1,901，舊 IPA 為 1,887）。
  欄位：CityName、RegionName、Address、DeptNm、BranchNm、Longitude、Latitude、direct、limit。
- **國道座標優先來源**：國道警方 **13940**，repo 快照 `manual/freeway_cameras_13940.csv`（2026-11-12 下載，177 列）。以正規化地址及行向校正同名國道點，不新增別的取締類型或刪掉未匹配相機；同名多組／無效座標明確警告。下載失敗或筆數縮減用已驗證快照並印警告；快照也失效則明列未套用、保留原主來源。依國道編號和 OSM 主線稽核距離 >150 m 的點，全列建置報告；13940 本身也可能有錯，不自動刪除。
- **里程牌**：公路局「省道里程坐標」（資料集 **7040**，約 27,000 處），把「台9線 19K」這類里程換算成座標和進入方向。
  經緯度欄位是「坐標-E-WGS84」「坐標-N-WGS84」。
- **區間測速**（舊 IPA **79 段**；本輪離線保留這 79 段並加 3 個方向為 **82 段**，完整線上數量待 CI 確認）：
  - **126156** 新北市方向別雙端及長度，repo 快照 `manual/ntpc_sections_126156.csv`（2026-11-12 下載，14 列）；本輪核實套用北宜 1～3 各雙向、新店環河路中央路至白馬寺雙向、新莊壽山路往新莊，共 9 個方向。各方向端點不能單純反轉；來源失聯同 13940 明確回退。
  - `data-pipeline/manual/sections.csv`：人工維護。北宜（座標寫回 CSV）；台64 中和段（兩個方向範圍不同，分成兩個群組）；自強、辛亥、中仁、仁水隧道（座標是 OSM 的隧道兩端，實際照相位置沒有公告；長度見 CSV 註解）。
  - `manual/section_lengths.csv`：警方公告的偵測長度，依行駛方向（from_km → to_km）蓋過里程差。來源是新北市警局「區間平均速率執法設備設置地點一覽表」（1140919 修訂，`traffic.police.ntpc.gov.tw`）。**開放資料的範圍可能是錯的**：台64 寫「25.2k至28.2k（雙向）」，公告往西只有 28.2K→26.6K。其他縣市的公告還沒查。
  - `speedcam_data/section_text.py`：從開放資料「設置地點」的文字自動產生，例如「台9線68k+600m至56k+600m」。
    離照相點超過 3 km 視為解析錯誤；同一筆裡至少一段通過時，其他段放寬到 15 km。
  - `manual/sections_text.csv`：開放資料沒有、但立法院附件清單（2026-05）有的區間。
  - **還沒有可驗證雙端的**：例如鳳鼻隧道、金門大橋、市道 182、瑪陵隧道、青山路、萬壽路；仍保留單點提醒，不猜終點。11/12 原始資料＋舊區間離線稽核剩 12 處，實際清單每次建置重算。
- **具名接續道路**：`road_lines.json` 新增 `namedRoads`，2026-11-12 OSM 重建為 10 個國道編號、134 筆具名非國道主線（含橋隧）；涵蓋水源、信義、環河、建國、市民、新生、基隆路、洲美等，以及台61／62／64／65／66／68／72／74／76／78／82／84／86／88 有名稱的部分。只取 motorway／trunk 主線，不取 link／一般平面路；不是完整禁行法規清單。完整範圍和限制見 `data-pipeline/README.md`。
- **人工相機與導航提示**：銀河附近新點為使用者街景位置 `(24.9555732,121.5698732)`，約 20 m 誤差、非精確設備座標；OSM way 655367014 北宜路三段局部往新店為 **240.6°**，速限留空待詢，不和 348 號那支合併。導航接續依 2026-11-12 已下載的 Overpass 原始快照，各 CSV 列附 way ID／URL；地下道入口三車道中間等 OSM 未提供的資訊明列依使用者實測。資源與測試 fixture 的 OSM 衍生資料依 ODbL，設定頁附出處。
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
- **資料的方向欄位不一定是行車方向**：過港隧道的「南向」「北向」其實是管道名稱（南孔是旗津往前鎮，實際往東北）。地址寫明方向的改用 `normalize.heading_from_address`。
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
- **ViewBuilder 裡不能宣告型別**：預覽用的 `struct` 要放在檔案層級；只加 `@available` 不會讓它離開 builder，
  也不會讓其他檔案看得到。`StaleActivityGalleryView` 曾同時造成 builder 宣告錯誤與 `SpeedCamApp` 找不到型別。
- **`MKAnnotationView.image` 不能直接放 SF Symbol**：它用符號圖的黑色底圖，上的顏色都會不見，要先畫成點陣圖。
- **CI 腳本不要寫 `指令 | grep -q`**：`grep -q` 比對到就結束，配上 `pipefail` 會因為 SIGPIPE 判斷成失敗，曾經把正常的 App 誤判成閃退。先存成變數再比對。
- **3D 建物遮線**：MapKit 的 `aboveLabels` 仍在 3D 建物下，沒有把 overlay 強制蓋到建物上的公開 API。`muted` 只降低底圖顯著度，不保證建物變平；iOS 16 以上 `showsBuildings` 在有 overlay 時不生效。B 輪保留 3D，沒有以改層級或關開關冒稱修好；需看 `36-route-navigation3d-*.png` 對照及實機。

## Git

- 單人專案，直接 commit 到 `main` 再 push。`Build IPA` 是手動觸發的 workflow，要在預設分支上才會出現在 Actions 頁面。
- **本輪例外**：11/08 第二階段 B（接續 A／C）只在本機 `copilot/test2-1108` commit，一項一個 commit，不 push、不觸發 workflow、不動 main；`docs/speed_camera_detector_test2_1108.docx`、`docs/copilot_review.md` 不加入 git。
- commit 訊息用繁體中文：第一行寫做了什麼，內文寫原因。

## 目前進度和下一步（2026-11-12 更新；IPA 仍是 11/07 版本）

**11/08 第二階段 B 退回修正（編譯）**：完整搜尋 `build\ci-r4.log`、`build\ios15-r4.log` 的 `error:`／`warning:`，
實際 Swift 診斷只有 ViewBuilder 內宣告型別及找不到 `StaleActivityGalleryView`，沒有其他實際 warning。
已將該型別移到同檔案的檔案層級，保留 iOS 17 門檻與原畫面。依 `55fcf5b..919facd` 逐檔複查全部 **17** 個 Swift 檔，
涵蓋型別／API 可用性、單參數 `.onChange`、builder 子項、import、App／Widget 共用檔及 XcodeGen／SPM sources；
iOS 15 的設定 Form 是 10 項，13 項的橫幅 gallery 已限 iOS 17，未再發現需要修改的編譯問題。
Swift 核心 **206** 項通過、0 跳過；Windows 沒有 iOS SDK，本輪未重編 iOS 15／26 App 或 Widget，
不能把核心測試或靜態複查當成 Xcode 建置通過。依本輪規則不 push、不觸發 workflow，待驗收者重跑。

**11/08 第二階段 B**：補測 03 的起點移到提示點前約 735 m，保留原案例及檢查器門檻，待驗收者重跑。第 12 項已接過期畫面、啟動清理與停止巡航取消預覽；第 14 項已統一橫幅比例並加入同屏及放大字截圖入口；第 15 項已接三種線樣式／兩種底圖、同幾何 3×2 預覽與固定 3D 導航對照，預設不變；第 16 項已接分版本 POI／長按選點卡、原預覽流程及導航／預覽中禁選點。Swift **206**／Python **274** 全通過，均 0 跳過，紀錄在 `build\test2-b-swift.log`、`build\test2-b-pytest.log`；未刪除／放寬既有測試。30 張新截圖入口已加入腳本，但尚未取得 iOS 26／15 編譯、實際圖片或手勢操作結果，不能宣稱畫面驗收完成。詳見 `docs\test2_1108_analysis.md` B 節；不做第 13 項、不新增 Xcode 測試 target。

**11/08 第二階段 C（前輪紀錄）**：修正第 8 項髮夾彎錯投影與路形／公告長度不一致的誤中止；舊 IPA 全部 79 段正向完整生命週期回歸通過。第 9 項人工相機已補、速限待詢；第 3／5／10 項及兩個新點以 5 筆定向分支提示接上手機與 Live Activity。Swift **199**／Python **273** 全通過、0 跳過，既有測試未刪除或放寬；詳見 `docs\test2_1108_analysis.md` C 節。尚未取得新 macOS／iOS 編譯、六點真 MapKit 最近距離／提示覆蓋、gallery 截圖或實播；不能宣稱六點已在 Apple 新路線通過。

**前輪 A（歷史）**：第 1、2、4、6、8、11 項及第 7 項前三段已實作，當時 Swift 187／Python 229 通過。驗收者已提供 CI run 43155203504 與 replay run 43155213404；後者完整 log 是 `build\replay-1108-fixed.log`，本輪已確認它的北宜 4 回程誤判，不能再當成通過。前輪離線資料核對為 17 筆國道座標校正、1,901 點／82 個方向、12 處未對應區間相機、8 處國道異常，並非完整 7040 線上建置或新 IPA；本輪未重新宣稱這些數量包含新增人工點。

1. **最新 IPA**：Build IPA run 42379834232（`main` 9bd771c，artifact 13577705562，2026-12-07 到期）。79 段區間、1,887 處照相點，App 最低 15.0、Widget 26.0。包含 2026-11-07 實測問題的修正（見下一項），以及隧道裡的固定照相依時間提醒。
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
   - 從 App 切換器滑掉後，約 2 分鐘卡片是否顯示「已停止更新」、隱藏舊數值，以及定位箭頭是否仍留著。iOS 不保證呼叫收尾，定位箭頭無法由程式控制，也無法在 CI 驗證；請分開記錄正常鎖屏、App 內停止巡航與強制結束。
   - 地圖 POI／空白長按、選點卡關閉／反查失敗、照相點仍開詳情、選點後正常預覽與倒數；iOS 15 長按、iOS 16 原生 POI、iOS 17 以上 MapFeature 都尚未實際操作，CI 啟動參數的畫面不代替手勢或 VoiceOver 驗收。
   - iPhone 7（iOS 15.8.8）：2026-11-07 使用者回報裝得上、開起來正常。還沒回報：背景定位、語音、實機的流暢度
   - 主力手機：狀態管理改成 `ObservableObject` 之後，地圖跟隨順不順（CI 截圖看不出動畫）
   - 上述功能
   - 地圖上的車種選單（CI 點不了選單，沒拍到打開的樣子）；紅黃牌和白牌實際規劃的路線；偏離路線重新規劃時會不會換回同一種走法
   - 提醒時機、方向誤報
   - 隧道裡 iOS 實際給什麼定位（完全沒有、基地台定位，或 iOS 自己推算的定位）：CI 驗證不到，`VehicleFix.isReliable` 是依一般行為寫的。如果 iOS 給誤差小於 100 m 但位置不準的定位，推算不會啟動。
   - 北宜區間開始／結束的時機
   - CarPlay 儀表板上的 Live Activity：實際位置、有沒有持續更新、車機用哪個尺寸
   - 不在 Dashboard 頁面時，接近照相點會不會跳底部通知；提示音和語音有沒有重疊。
     CI 驗證不到這些。沒有跳通知的話，先查通知權限：App 目前沒有要求，Apple 文件也沒說需不需要。
4. **已知問題／待辦**：
   - 北宜第 4 段 56.6–68.6K 未取得方向別官方門架；126156 沒有這段，保留原端點。其他縣市無雙端者也不補假終點。
   - 本輪國道稽核仍有 8 處異常（其中一處地址是匝道，距主線遠可能合理）；只報告，不自動移除。官方快照回退不是即時更新。
   - 反向中止依賴可靠路形；沒有 path 的區間在貼齊完成前，只能等退回起點確認。部分具名路的入口太短／名稱多義時保留「上高速公路」，不為了改字而猜路。
   - 長隧道的推算誤差會累積：雪山隧道裡實際車速比進隧道前慢 15% 時（模擬），最後一支照相機提早約 1.7 km 提醒。車速變快則會太晚，CI 沒有測。
   - 地址沒有方向的照相點（`axis`），走平行的道路會誤報：有定位時就是這樣，例如走國 5 接近頭城時會提醒北宜路的「台9線69k+20m」。
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
