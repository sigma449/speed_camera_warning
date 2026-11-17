# CLAUDE.md：專案說明

先讀本檔／`docs\SETUP.md`，重要變更同步更新；歷史原文見 [HISTORY.md](docs/HISTORY.md)，非現行指示。

## 跟使用者溝通

- **對使用者全用繁體中文（台灣用語）**，文件／commit亦同；程式碼／指令／檔名不改。
- 使用者會寫程式但不熟 iOS，只有 Windows、iPhone，沒有 Mac；iOS 編譯、測試、截圖靠 GitHub Actions 的 macOS runner，不要求本機 Xcode。
- 先用免費 Apple ID、iloader＋SideStore 側載。說明寫實際按鈕／指令；不確定的畫面寫「依畫面指示」，不要編造。

## 專案是什麼

台灣測速照相提醒 iPhone App，**主畫面是地圖**，汽／機車皆可。Phase 1 地圖、巡航、MapKit 逐向導航、測速／區間已完成，待實機驗收。
Phase 2 才付 US$99／年入 Apple Developer Program、TestFlight、申請 CarPlay **導航** entitlement／地圖；Phase 3 重機停車（TDX＋人工／回報），均未開始。
CarPlay 畫地圖須逐向導航、一App一類。iOS26 Live Activity免 entitlement，位置由系統定；240×78／240×100／170×78 pt，用 `.supplementalActivityFamilies([.small])`／`@Environment(\.activityFamily)` 做大字。

## 已確認的規格（改之前先問使用者）

- **兩段提醒**：每段一次；一般預告 300 m／近距 100 m，照相點速限 ≥80 時為 600 m／200 m。依法規設置距離，不用使用者認為太遠的 1,000 m。
- **近距語音**：已預告且同目標當下超速念「100公尺，超速」，未超速只念「100公尺」；高速用實際設定的「200公尺」，太近念實距。讀目前狀態，不依賴同秒開始事件；合句不另播超速。首次已在近距內仍保留完整句與既有超速語音，此分支待使用者決定。
- **超速警示**：接近照相點時每 3 秒嗶一次，降速或通過停止；一般照相超速容許值預設 0。
- **多來源與新提醒類型（第二階段 D，第 13 項已核准）**：接受官方與 OSM，不碰商業私庫；使用者回報先不做。
  - `mobile`＝「常見移動測速」，橫幅補「公告熱點・非即時執法」；`noise`＝「聲音照相」；`tech`＝「路口科技執法」，保留取締項目與適用條件。
  - 熱點、聲音與其他非測速只預告一次，沒有近距／超速嗶聲。科技明列「超速／測速」走兩段；僅可靠一般速限可嗶，未知／條件速限只提醒；原測速距離、3 秒嗶聲及區間規格不變。
  - **闖紅燈近距（2026-11-16）**：`redLight`／項目明列闖紅燈的 `tech` 共用原兩段距離／語音／合句／隧道 `tick`；未知速限依當下車速選門檻。已預告只念距離，首次近距完整念類型／項目；手機、Live Activity及300 m內 `navHint` 優先不變。
    共用 `enforcementItemList`，切分後含完整「闖紅燈」即算，含「闖紅燈及路口淨空」／括號內；不推定紅燈右轉／越線／泛稱號誌，不看地址／條件。純停車不報，混合闖紅燈兩段；`mobile`／`noise`不隨文字升級。
    兩段非測速；超速判斷／語音／嗶聲仍只由 `enforcesSpeed` 控制，語意不變；純闖紅燈不新增超速，`redLightSpeed`／測速科技不變。
  - 里程熱點「往某地」僅依**同條省道官方行政區里程證據**選增加／減少方向，再取當地 ±50 m 里程牌方位；新北門牌／燈桿分向車道可依 H7 的 OSM 地物位置＋單行方向唯一核對（H10，2026-11-17 同意）。缺證據保留軸向、不猜地名；方向證據衝突不發布單向、列報告。「雙向」沿道路，缺軸向不發布。
  - 熱點在區間內外皆可單次預告，沒有距折線 100 m 消音或倒數禁報；區間預告／倒數／相機 300 m 覆蓋不變。App／RouteProbe 正常定位、隧道 `tick` 的相機 API 均已移除 `sectionActive`。
  - 不同熱點不設語音間隔；`mobileHotspotVoiceDistance`、累計行駛／消音狀態完整移除，非設為 0。忽略舊設定該欄、保留其他偏好；同相機通過冷卻不變。
  - 已追蹤熱點在 30 m 內仍驗 45° 單向／軸向，只放寬「是否在前方」；最後定位距熱點 30 m 內的 `tick` 也須判向。未知方向備案、其他類型、冷卻與隧道公式不變，不依地址／案例名消音。
  - 同秒「近距／超速 > 區間 > 熱點預告 > 導航」；含熱點先處理區間再排熱點，定位／隧道同入口。Core管排序／跨批插播，低優先urgent不得打斷近距／超速，同級原規則；其他相機／緊急插播不變，不另建佇列／補播。
  - 科技取締**全是停車**才不成核心目標，仍保留地圖／原始詳情；混合項目仍提醒，語音／橫幅／Live Activity 穩定排序「非停車在前、停車在後」。未知項目、「停車再開」「不停讓行人」不算純停車。
  - 「移動式熱點」「科技執法（非測速）」「聲音照相」各預設開啟（`mobileHotspotsEnabled`、`nonSpeedTechEnabled`、`noiseCamerasEnabled`）；含測速科技不受非測速開關影響。關閉移除該類地圖／核心目標，不重設其他測速／區間。
  - 三類接近用黃、望遠鏡／錄影／喇叭，無可靠測速門檻不畫速限牌。手機列完整項目；Live Activity 放不下先縮第一項「取締：闖紅燈等」，再只留類型；超速／近距導航優先不變。
- **方向判斷**：只報自己行車方向；雙向相機有南北／東西軸向，沿路兩向提醒，橫向不報。
- **自行新增／修改／隱藏照相點（2026-11-17）**：選點卡次要新增固定測速／闖紅燈；八方位／四軸雙向／未知正前方30°，近點可靠行向可存實角。H13巡航／導航可靠定位時，回中心上方相機加號一鍵記目前固定點、最後≥8km/h可靠行向、速限nil；背景補路名。8秒確認卡可選40／50／60／70／其他或復原，不停跟隨、不蓋橫幅；卡消失及至少3秒才能再按，本次開啟快速新增點50m內重顯、不重複存。立即套通過冷卻，補速限／地址不清冷卻；未知速限兩段但不嗶，詳情／管理顯「速限未設・只提醒不嗶」。預覽／卡片／表單不顯按鈕，原導航禁選點不變。詳情修改／隱藏／復原，自增可改類型／確認刪除，section不可動。`userCameraEdits.v1.json`本機原子存檔、壞檔改名警告；Core增量套用，不重設其他相機／區間狀態。設定管理與分享CSV＋核對JSON，不上傳／匯入；CSV斜向退未知軸、空速限仍未知，精確值留JSON，完整規格／操作見SETUP。
- **區間預告**：接近起點一次；速限 ≥80 用 600 m，其他 300 m。語音「前方300公尺，進入區間測速，速限70」；橫幅／Live Activity 用 `SectionApproach.asCameraTarget`。須從起點後方順向接近（`isHeadingToStart`），反向／橫向不報；分不出平行平面道路。
- **進入區間的判定**：`SectionSpeedTracker` 通過起點 60 m 範圍開始；GPS 跳過或匝道併入可在區間前 300 m late-entry，以車速回推時間，超過起點 300 m 才上路不算。arming 後仍須順向沿路跨起點；起點前迴轉、橫離、停等漂移不算。
- **區間中迴轉**：須精度≤30 m、連續可靠定位、行向逆局部道路且持續後退5秒／60 m；或退起點前>60 m持續3秒。發 `.aborted`、清超速、不套五分鐘完成冷卻；須實過起點重入、禁段內late-entry。無可靠路形只判退起點，不憑跳點／失聯／髮夾彎方位差中止。
  最近投影後驗連續性；正向候選／投影失配／失聯均清反向證據，段內須重新有正向證據才累積，起點延伸線仍可重確認；5秒／60 m、3秒／60 m及精度不變。中途離開距離保護取公告／路形長度較大值、留600／1,000 m餘量，不改倒數／公告長度。fixture保留79段（71 path／8直線）及北宜4回程，插值非完整實車GPS。
- **隧道裡沒有定位**：每秒呼叫 `SectionSpeedTracker.tick`／`CameraAlertEngine.tick`，超過 2.5 秒沒定位依最後車速／時間延續區間預告、進入、倒數及相機預告／近距；定位恢復接回。
  - 區間保留「預告距離＋200 m」的有向候選但不提前顯示／發聲，失聯進 300／600 m 才預告、再推算進入；沿用 8 km/h 門檻／方向，不套固定相機 20 km/h。
  - 失聯預告／進入須最後行向射線在既有道路寬容＋門架半徑內經起點，避免國5誤入北宜。可靠定位恢復時，前後線段順向跨終點門架才補完成並回推均速時間，不靠 `tick` 宣告通過、不改迴轉門檻。
  - 精度誤差 >100 m 或無車速的 `VehicleFix.isReliable` 不可靠定位不交兩核心，當作無定位。
  - 固定相機用「最後定位直線距離－行駛距離」，不推算位置；雪山隧道偏離直線 600 m，彎道可能提早報。地址寫隧道（原資料含區間 54 支）最遠 15 km、非對向即可；其他只算 1.5 km 內／前方 30°，避免宜3等平行道路／捷運地下誤報。最後車速 <20 km/h 不推算。
  - 通過等定位恢復；舊車速不嗶，超過 10 秒結束超速狀態。
- **區間照相機**：已知區間路線300 m內由 `CameraAlertEngine.isCoveredBySection` 排固定提醒，交預告／倒數；中仁已核點以 `sectionGroupID=zhongren-tunnel` 關聯，不放寬全域半徑。未對應仍一般提醒、報告列全單；區間相機找500 m內區間套個別容許值。
- **區間測速倒數**：顯示到終點尚需秒數；每分鐘語音、最後 30／10 秒各一次、歸零提醒；最短時間另加 3% 安全餘裕。
- **區間容許值**：預設 +10（北宜 40→50），0～+20、每 5 一格；「個別區間設定」可多選，同段雙向共用 `SpeedSection.groupID`（去 `-f`／`-r`）。倒數、區間超速及區間相機前嗶聲同門檻。
  **A06 重算**：途中改容許值／安全餘裕，立即依原起始時間重算；下次核心輸出的倒數、建議時速、門檻、歸零狀態一致，不重設超速冷卻。最短時間變長可恢復倒數並再歸零一次；提高容許值只縮短時間，不反轉公式。
- **區間超速節流**：`sectionOverspeedBeepInterval` 預設 15 秒、`sectionOverspeedVoiceInterval` 預設 30 秒，49／51 km/h 抖動不重設冷卻。歸零清區間超速、不再發區間語音／嗶聲；App／Live Activity 共用 `SectionStatus.isOverspeed`。固定相機仍 3 秒、不受歸零影響；容許值／3% 不變，歸零非准許超過道路速限。不新增設定頁控制項。
- **區間建議時速**：剩餘距離÷剩餘最短秒數（速限＋容許值、含安全餘裕），上限速限＋容許值、無條件捨去。手機橫幅大字、超過變橘，每分鐘倒數一起念；Live Activity「建議≤N・均速 M」，170 pt 放不下用「≤N・均 M」。
- **北宜公路（台9線）**：4 段雙向、表定 40；19–23.1K、26.2–32.2K、33.3–37.2K、56.6–68.6K。前三段用 126156 方向別官方門架／公告長度，保留 `beiyi-N-f/r`／`groupID`／容許值；第 4 段不在該來源，留里程牌端點並列缺口。接路形前裁掉門架外點，不可往回接線造成反向。
- **車種**：汽車／紅黃牌／白牌（`VehicleMode`），舊 `motorcycle` 對應白牌不變，規則在 `RouteRules`。
  - 請求／路線綁車種世代，預覽切換取消重算、完成前禁開始／舊倒數，說明用實際車種；導航切換重規劃，舊結果不得覆新。
  - 紅黃牌避國道／收費，可走快速／高架；先只避收費取多線，排收費／國道，全不符才退避高速。不可直接 `highwayPreference = .avoid`（會擋快速／高架）；免費國2／4／6／8／10用線形排除。
  - 白牌只走平面，避高速／收費，再排 `data-pipeline/manual/white_plate_restricted.csv`（含新生高架、洲美）。
  - `RoadMatcher`／`Resources/road_lines.json`（OSM）：連續≥800 m且距離中位數≤10 m；平行縣道191／國5僅30 m內不夠。無法分層，僅Apple標高速才比國道；線形載入失敗紅黃牌退平面。
  - 無合規路線選問題最少者，預覽／重規劃提醒。用汽車路網，無完整禁行機車資訊，設定須說明。
- **舊手機支援**：App 最低 iOS 15（iPhone 7／15.8.8）；iOS 17 以上原流程，替代集中 `LegacySupport`：`LegacyMapView`／MKMapView、CLLocationManager。16.2 前無 Live Activity 且隱藏設定；18 前開搜尋不自動鍵盤。
  iOS 15 無 `highwayPreference`／`tollPreference`／`hasHighways`／`hasTolls`，視為有高速、一定比國道，白牌一定提醒，仍可能走快速／高架，設定說明；機車路線用 iOS 16 以上判斷。Widget 維持 26，舊機安裝但不載入（15.5 模擬器已證實）。
- **Live Activity**：使用者要求大字，不做成神盾的小字版面。
- **區間橫幅只放三行**：「區間倒數 N 秒」（秒數最大，不加「還要／才能到終點」）；建議時速（超過變橘、改「請放慢：建議 N 以下」）；「均速 M・剩 Xkm」。不顯示名稱（原資料 27～32 字）或「以 N 計算」。
- **其他畫面也要精簡**：不顯「巡航中」，只車速及「km/h・汽車」；Live Activity 超速小字只「超速！」。鎖定巡航右側不重複車速；動態島展開左上只速限／圖示、右上車速、下方大／小字，巡航隱藏右上車速。`Camera.shortAddress`：18 字內原文，過長移括號、多段取首段；詳情留完整地址。
- **主畫面橫幅不透明**：用 `BannerStyle`，地圖路名不得透出；深色底白字對比 ≥4.5:1，小字不用 `.secondary`。
- **同屏橫幅比例（第二階段 B）**：照相／導航／區間共用 64 pt 圖示欄、46 pt 主數字、56 pt 主行槽、176 pt 最小高，頂端對齊；長字可撐高不可鎖死，區間仍三行。375／390 pt 與放大文字須 CI 看圖。
- **導航文字縮短**：CarPlay／鎖屏／手機用 `ManeuverText.short`「動作＋路名」（如「靠右 上五股楊梅高架」「下交流道 95A出口」），語音保留 Apple 完整句。區間／相機模式轉彎點 300 m 內以 `SpeedCamActivityState.navHint` 顯示下一步，超速優先。
- **「上高速公路」校正**：Core `RoadInstructionResolver` 只在動作點後路形唯一對上 `road_lines.json` 具名非國道主線時，畫面／完整語音一起改「上＋路名」（如「左轉上水源快速道路，朝(永和)、景美前進」／「左轉 上水源快速道路」）；國道、平行／橫跨、入口短、未知／多名歧義均保留 Apple，不猜。
- **人工導航補充提示**：`RouteHintMatcher` 限導航折線依序過提示／確認點且進入行向相符；反向／別支／平行／繞回歧義／未導航不報。5筆6標記：建國下高架、師大地下道、水源南出＋秀朗橋分岔、環河地下道、回程上水源；水源兩點37 m合句「下匝道 不上秀朗橋」，語音靠右往環河路。
  共用提前距離／優先／門檻不重播，起點不在開始導航重念；`RouteProgress.maneuverText` 留短句、手機／Live Activity共用，300 m `navHint`／超速優先不變。僅40 m內且符 `replace_text` 才取代已核Apple原文，其餘步驟／位置不動；載入失敗警告＋log、暫用Apple。
  編輯 `data-pipeline\manual\route_hints.csv`：行向、後續距≥20 m、半徑12～15 m、短句／語音／來源，缺OSM車道資訊標「依使用者實測」。取代片段 `|` 分隔，禁空白萬用；跑 `python -I -X utf8 data-pipeline\build_route_hints.py`、提交 `SpeedCam\Resources\route_hints.json`，pytest驗一致、補OSM分支正反例／replay，不憑座標猜橋上橋下。
- **偏離路線**：離線 50 m 持續 5 秒，或方向差 ≥50° 且離線 30 m 持續 3 秒；未回線每 15 秒重規劃，規劃中不顯舊下一步。
- **Live Activity 開始和更新**：前景開始失敗每 5 秒重試；重開接手既有，不結束重開。更新不排隊、只留最新，距離／車速最多每 2 秒；接 CarPlay（carAudio）主動更新；設定列狀態／失敗原因。
- **滑掉 App（第二階段 B）**：保留背景巡航，初次 request／每次更新設 120 秒 `staleDate`。Widget 各版（含 `.small`／動態島）過期顯「已停止更新」、隱藏舊車速／距離／倒數／超速底色，非移除。重開接 active／stale；本次不巡航或關 Live Activity 則結束殘留。停止巡航同時取消預覽／每秒工作、重設核心；移除卡片回 App 停巡航或鎖屏滑掉，不能依靠強制結束收尾。
- **Live Activity 提醒**：`ActivityAlertPolicy` 對預告／近距／超速／進區間／歸零以 `alertConfiguration` 更新，每次定位最多一則；每分鐘倒數／持續嗶聲只聲音。非 CarPlay Dashboard 時 Apple 說會底部通知；系統預設音、無靜音選項，可用預設開啟的 `liveActivityAlertsEnabled` 關提醒。
- **開啟 App 就自動開始巡航**：`AppPreferences.autoStartCruise` 預設開啟、設定可關。
- **定位恢復（H2）**：定位工作退出清對應世代並記原因；巡航且有權限時每秒／回前景檢查，至少隔 5 秒重啟；舊工作不能清新工作，舊版暫時性 `locationUnknown` 保留工作。
- **搜尋目的地**：`MKLocalSearchCompleter` 邊打邊出候選、快速搜尋（加油站／停車場等）、最近目的地最多 15 筆。搜尋／選候選共用可取消工作，以世代／查詢／畫面存活驗回填；關閉／選定立即失效化，晚到不得改目的地。
- **地圖選點（第二階段 B）**：17+ `MapFeature`、16 MKMapView的 `selectableMapFeatures`，全版長按任意點、15僅長按。先卡片名稱／地址／原座標，主動作「開始導航」外觀不變、另有中性次要「新增照相點」；按開始導航才進3秒地點／10秒路線預覽，不直導航。導航／預覽禁選點，相機仍詳情、預覽藏相機；開卡停跟隨／自動回中心、藏底部／回中心，只一主動作。反查失敗提示＋log、仍用原座標；取消／改選使舊結果失效。POI／長按／相機分流／清晰度須iOS操作看圖。
- **區間在地圖上順著路形畫**：里程牌產 `path`（[[緯度, 經度], ...]），Douglas–Peucker 簡化 6 m；`SpeedSection.displayPath` 畫、無 path 用直線，同段雙向只畫一次。`SectionPathSnapper` 以 Apple 貼路：先起終點一次規劃，長度 0.85～1.2 倍／偏路形 ≤200 m 才採，否則每 1.2 km 分段。
  Application Support的 `snappedSectionPaths.v2.json` 按方向別 `section.id`＋有序精確端點簽章驗，端點變重算、不讀v1／跨 `groupID`。每向一次、間隔1.5秒、近中心優先；同步核心不重設倒數。背景估長按ID就地套用、保留active／原起時／預告／超速節流／重入及完成冷卻，不覆新路形，長度未變也不重設。
- **回到目前位置按鈕**：右下 `MapFollowController` 依 `MapFollowCamera.distance` 車速縮放，預設行向朝上；跟隨再按依序行向→北方→3D、記住選擇。巡航 App 自算 MapCamera，無定位用 `.userLocation` 系統跟隨。
- **地圖對照（第二階段 B／E，僅內部用途）**：`MapAppearance` 的 `current` 純藍／`whiteCasing` 白框／`darkCasing` 黑框及 `current`／`muted` 底圖僅啟動參數、不持久化；藍線 7 pt、預覽 8 pt／0.85、外描 3 pt，新舊橘區間線皆在導航線下。muted 限 MKMapView iOS 16+，15 原底圖；3D 選擇／55°／高度不改。使用者 2026-11-13 不採新樣式，預設保持原樣。
- **自動回到中心**：`AutoRecenterPolicy`：滑走後精度 ≤30 m、車速 ≥15 km/h 持續 5 秒，且 10 秒沒碰地圖才回中心。地下無 GPS 通常不觸發，地面／高架捷運、台鐵、高鐵無法分辨（iOS 也算汽車）；TDX 軌道線形留待之後。
- **高架／平面標示**：地址 `level`：「高架」→elevated，「高架下／平面」→surface，高架相機 350 m 內未標者→surface；語音「高架測速照相／平面測速照相」、橫幅／詳情標籤。CMAltimeter 高度變化排除另一層留待之後。
- **導航前先預覽**：選目的地→地點約 3 秒（或點）→整線預覽→開始導航或 10 秒自動開始；拖圖暫停倒數，可取消（`AppModel.NavigationPreview`／`NavigationPreviewCard`）。預覽不畫相機、照畫區間。
- **搜尋與導航語言**／**地圖與搜尋的語言**：設定最上「跟隨iPhone／繁體中文／English」，按「立即重新開啟 App」回主畫面結束後再點圖示。MapKit無指定API，寫App的 `AppleLanguages`、重開生效，地址地區另設 `AppleLocale`；CI已核zh-Hant-TW路名／候選中文，zh-Hant／en lproj皆名「測速地圖」，不改整支英文iPhone。

## UI 設計原則（按鈕、提醒文字、橫幅）

參考 taste-skill（MIT 2.5.0），**不要安裝／套用該網站 skill**。
- 一眼可懂，一畫面一重要資訊大字，其餘縮小／移除。
- 同套按鈕／圓角、一個主要強調色動作；灰色只真停用，可按鍵不可像停用，顏色不分功能。文字「動詞＋受詞」，圖示有 `accessibilityLabel`、點擊 ≥44 pt。
- 白話短句、獨看可懂、同件事同說法不重複；超速加「超速！」不只靠色；放不下先短句再縮字。
- 紅＝超速、黃＝接近、橘＝區間／注意、綠＝正常／依速限；不透明底、白字 ≥4.5:1、小字不用 `.secondary`。
- 同類同外觀、邊界齊、框最多再一層；動畫僅操作回應、尊重減少動態。
- 新狀態加 CI／gallery，**實際看圖才完成**；測最窄／最長字／放大字。用系統字型，不用照片、Google Fonts、隨機色、hover、滿屏區塊、shader／捲動裝飾。

## 程式結構

| 路徑 | 用途 |
|---|---|
| `project.yml` | XcodeGen，不提交 xcodeproj |
| `SpeedCam` | AppModel（ObservableObject）／設定／Map／Navigation／Location／Alerts／LiveActivity／Data；RootView 地圖同步 LegacyMapView（15／16），舊API集中 LegacySupport |
| `SpeedCam\Resources` | cameras.json佔位、CI下載；road_lines.json／route_hints.json追蹤；zh-Hant／en名稱 |
| `Packages\SpeedCamCore` | 純Swift邏輯／SPM測試；相機、區間、語音、車種、線形 |
| `Shared`／`SpeedCamWidgets` | ActivityAttributes／共用畫面／Widget |
| `data-pipeline` | 標準函式庫工具／manual／snapshots／pytest |
| `scripts\ci`／`scripts\swift-test.py` | 遠端CI／本機Docker；詳 `docs\CI.md`，安裝見SETUP |

### 啟動參數（CI／內部用途，不代表手勢或實播驗收）

- `-demo`／`-demoIfEmpty`：展示／空才展示；`-autoStartCruise NO`：不自巡航；`-legacyUI`：強制舊流程。
- `-gallery` 看Activity，以下gallery選項均配它：`-galleryMiddle`／`-galleryBottom` 中／底部；`-galleryBanners` 手機長字；`-galleryBanners -galleryHints` 人工提示／170×78 navHint。
- `-galleryBanners -galleryBannerPair camera|section|zero|rerouting -galleryWidth 375|390`：導航＋相機／區間／歸零或重規劃同屏。
- `-galleryTypes mobile|tech|noise`：三類CarPlay三尺寸／鎖屏／動態島，加 `-galleryBanners -galleryWidth 375` 看手機詳情；`-galleryLock` 鎖屏／動態島（外框示意）；`-galleryStale` 過期三尺寸，可加Lock；`-galleryPlaces` 375 pt長名稱／地址及反查中／失敗，可加Bottom。
- `-galleryUserCameras place|fixed|fixed-current|redLight|redLight-current|both|official|added|modified|settings|empty`：375pt選點／表單／詳情／管理，15也可用；純記憶體假資料，不碰個人編輯檔。`-galleryBottom`看表單備註／詳情底部／隱藏清單，settings加`-galleryMiddle`看修改清單；完整截圖含兩種字級。
- `-galleryUserCameras quick-button|quick-confirmation|quick-navigation|quick-camera|quick-section|unset|unset-edit`：行車按鈕／確認卡（含導航、照相、區間同屏）／速限未設詳情與修改表單；375pt、一般／放大字、iOS15也拍。確認卡示例固定顯示、不啟動定位／反查或倒數，不代表手勢／實播驗收。
- `-search 文字`／`-typeSearch 文字`：搜尋／約45秒輸刪；`-settings` 設定；`-vehicleMode car|motorcycleRedYellow|motorcycleWhite` 車種覆寫不儲存。
- `-mapCenter 緯度,經度 -mapSpan 度數` 範圍；`-previewTo 緯度,經度,名稱` 預覽；`-selectPlace 緯度,經度,名稱` 正式選點反查、不預覽，與previewTo並用則預覽優先。
- `-routeLineStyle current|whiteCasing|darkCasing -mapEmphasis current|muted` 內部樣式不存。
- `-routeStyleDemo -routeComparison preview|navigation3D` 固定師大至河岸示意，非可駛路線，不搜尋／規劃／貼齊／巡航；中心25.0165,121.5310朝南，預覽5,000 m／0°、導航3,800 m／55°，預設preview、新舊各3×2、15有備案；不改一般預覽倒數。

## 建置與測試

repo根目錄執行；日常跑預設快測試，**改 `scripts\ci\` 或 workflow 另跑 slow**。不可刪測試、放寬斷言或缺資料跳過。

```powershell
python -m pytest -q data-pipeline
python -m pytest -q data-pipeline -m slow
python -m pytest -q data-pipeline -m "slow or not slow"
python -I -X utf8 scripts\swift-test.py
python -I -X utf8 scripts\swift-test.py --filter SectionSpeedTrackerTests
```

前三行依序快／僅慢／全部；`-m "not slow"` 是 **deselected非skip**，治本後實測約>5秒才標slow，CI `_tests.yml` 全跑。
Swift原始碼掛載、Resources **唯讀** `/SpeedCam/Resources`、`.build` 用named volume；參數照傳，舊 `build\swift_test.py` 轉接scripts追蹤版。

完整驗收由**驗收者**先push分支，再用main已註冊入口：

```powershell
gh workflow run build-ipa.yml --repo sigma449/speed_camera_warning --ref copilot/test2-1108 -f acceptance=true -f screenshots=full
```

完整驗收同commit／資料指紋，iOS26／15及三組replay全過才IPA、核內嵌位元組；發布閘門見CI，禁舊包補綠。
搜尋改動加search-stress，提醒／區間／導航加replay，15改動測舊版，UI下載真圖看；base64須明確啟用。
**分流／檢查器／ODbL發布／截圖下載／macOS對照統一見 `docs\CI.md`**；不混run，獨立IPA／plan／compare非完整驗收。

## 資料來源

來源現況／限制見 `data-pipeline\README.md`；**淨增非新設備數，舊快照非HEAD完整建置**。
- 7320警政署（opdadm.moi.gov.tw）＋地方固定／科技；178144 HTML未核與CSV同版，新竹移動授權未清不接。
- 7040里程轉座標／行向；13940國道同名同向校正、歧義警告，主線>150 m全列不自刪；126156北宜1～3等方向別門架／長度不可直接反轉。manual補區間／長度，北宜4等無雙端不猜終點，OSM隧道口非實測門架。
- 公告限同區精確門牌／原桿號、無歧義道路或唯一同層路口，不取中心；保留method／依據、標「位置依公告地址推定」。斗六空地區不沿上列、速限留conditions；雲林CRS、臺南路段／高雄舊移動缺證不接，PDF變版重核。
- OSM僅可核from→to，不反轉direction／猜forward或way中心、不覆官方值，保留ID／URL／方法；線形非完整禁行法規。衍生庫／fixture依ODbL署名。
- 可選源失聯／異常／縮減須警告回已核快照，快照壞僅略該源；非即時，必要源仍擋發布。查漏臺北130111／警方PDF／立院附件，PDF用 `pdftotext -enc UTF-8 -layout`。
- **三支人工測速（2026-11-16）**：`data-pipeline\manual\cameras_extra.csv` 有銀河往新店240.6°／40（不合348號）、國安局前仰德大道一段下山148.7°／40、至善路一段往仰德大道275.2°／50；皆使用者確認測速非聲音，街景估位約20 m誤差，官方／OSM無對應設備證據，備用桿僅推定。銀河24.9555732,121.5698732／40未重新現場核。導航CSV保留way／URL、缺車道資訊明標依實測；不宣稱已收齊全臺。
- **聲音／新北熱點分向車道（H7：2026-11-16；H10：2026-11-17，使用者同意）**：臺北 tp-noise、彰化 173697、新北 ntpc-mobile 門牌／燈桿共用 `Geocoder.locate(..., allow_divided=True)`；其他移動來源仍嚴格。同名、同層、同等級、反向單行、左右並排且局部軸向差 ≤15° 才成立；方向能以 OSM 地物位置＋單行方向唯一核對才給 heading，否則取兩側投影中點、axis，`conditions` 加「分向車道無法判定，沿路雙向」。不同軸向／路口轉角／第三分支仍拒絕；35 m、完整門牌、推定位置標示、150 m 去重／固定優先不變。H10 從同 MD5 既有 PBF 補回 72 個 way 的單行標記：原 49 列為 2 單向、31 雙向發布、12 去重、2 固定優先、2 因 `oneway=no` 拒絕，淨增 33 熱點；兩份完整基準原 210 點全欄位不變。臺北仍 25／28、彰化 7／9。細節見 `data-pipeline\README.md` H7／H10 節。
- **官方新公告監看（H8，使用者 2026-11-16 同意）**：`data-pipeline\watch_announcements.py` 只產生待人工核對清單，**絕不自動增修照相點**；入口與關鍵字在 `announcement_sources.json`，調查見 `docs\announcement_sources.md`，首份清單 `docs\announcements_pending.md`（12 個月只命中 3 則，都不是三支人工點的證據）。用法：`python -I -X utf8 data-pipeline\watch_announcements.py --cameras <完整 cameras.json> --output-dir build\announcements`，加 `--update-seen` 才更新已見索引。每週 Refresh camera data 在資料驗證後執行，新公告附在同一份資料 PR。
- **備用桿候選調查（H9，2026-11-16，未進 repo）**：`build\stage-h9\report.md`、`candidates.csv`。公開來源（OSM 現況／歷史、消防栓備註、測速警告牌、KartaView）只找到 6 筆低～中把握度線索，**三支已知人工點 0／3 找得到**；Mapillary 需使用者提供唯讀 token 才能試。結論：未公告桿位目前只能靠使用者現場／街景確認。

## 容易踩到的坑

- `MKRoute.Step` 指示是**這一步走完**的動作，不是開始；轉彎位置用 `MapItems.stepInfos` 每步折線實長，不用可能差2.3%的 Step.distance。
- Info.plist `CFBundleDisplayName`／`CFBundleName` 僅英數，中文放zh-Hant／en lproj、跑check-bundle-names；免費側載限制／-80045見SETUP，無App Groups／APNs。
- Python3.13憑證由sources.ssl_context關VERIFY_X509_STRICT、仍驗鏈。
- 方向欄非必車行向（過港孔名），用normalize.heading_from_address；「市民高架道下建國／光復南路」是速限80的高架匝道附近，不是平面，經緯度不能分層。
- 不以 `ForEach(array.indices)` 索引更新陣列，改自帶id資料；Int前防NaN／infinity。
- iOS15用ObservableObject非@Observable；新API包#available、不可直接存新型別（Any／AnyObject）。ViewBuilder最多10項、設定Form已10，增加用Group；onChange單參數，SF Symbol給Symbols備案。
- struct放檔案層級非ViewBuilder，available不改作用域；MKAnnotationView.image的SF Symbol先點陣化才有色。
- 背景定位會重啟程序，launch_app先terminate兩次、非巡航加-autoStartCruise NO；sheet／改鏡頭等啟動後1.2秒。
- 截圖用固定routeStyleDemo，不依Apple當天規劃；存活／PID／搜尋完成政策見CI，PNG不證明內容／手勢／存活。
- pipefail禁 `指令 | grep -q`（SIGPIPE），先存再比。aboveLabels仍在3D建物下、無公開API置頂；muted不保證平坦，16+有overlay時showsBuildings無效，不能假稱修好。

## Git

- **在 `copilot/test2-1108` 開發，尚未合併main；合併須使用者同意，不動main**。
- **Copilot只本機commit，不push／觸發workflow**；驗收者負責遠端。
- commit繁中、首行改什麼／內文原因、附Copilot Co-authored-by。
- 不提交 `docs\speed_camera_detector_test2_1108.docx`／`docs\copilot_review.md`；調查、`build\survey2\`、`build\stage-f\`／原回放唯讀，不回復他人變更／放寬測試。

## 目前進度（2026-11-16）

`68953b4`已push、驗收者告知完整驗收啟動，**結果未核實，不宣稱iOS／MapKit／IPA／實播通過**。H6本機Python701／Swift287通過、0跳過；僅測試／文件，證據／規格對照 `build\stage-h6\`。

**等週末實機**：鎖屏／停巡航／滑掉分開看2分鐘過期／定位箭頭；全版選點／反查／相機分流／預覽／VoiceOver；iPhone7背景定位／語音／流暢度、主力跟隨動畫、7與12 Pro提示差；車種／重規劃、提醒時機／方向／近距、隧道GPS／北宜進出、台64晚150 m；CarPlay位置／尺寸／更新／非Dashboard通知與音訊（App未求通知權限、Apple未明說必要性）。

**已知問題／待辦**：
- `83881-32` redLight融合超速／50、原enforcesSpeed=true，類型衝突待核，非新增加兩段。
- 純停車／混合排序／闖紅燈近距缺新版看圖與實播；科技gallery僅300 m。
- 無可靠path未貼齊只可退起點判迴轉；貼齊失敗留里程牌：台61 157.8–151.6／41.5–46.9、台64 1.6–5.4、台9 110.96–108.224。
- 長隧道舊速誤差（模擬慢15%早1.7 km，變快未驗）；髮夾彎／平行／上下層誤報、誤差<100 m的不準GPS仍有限制。機車非完整法規、15尤有限制。
- TDX運輸／氣壓分層、背景重啟自動巡航未做，B09 runtime快取暫緩；UI底部統一／預覽藏按鈕／取消中性色及Phase2／3待使用者決定。
