# 2026-11-08 北宜實測：第一階段原因調查

| 項目 | 分類 | 一句話原因 | 一句話建議修正 |
|---|---|---|---|
| 1 建國誤報國一 | A | 國一南向279K的上游座標錯放台北，能通過南向相關性條件。 | 優先採國道警方正確座標，加入地址／道路線形一致性檢查。 |
| 2 水源說上高速 | C | 未取得當次 Apple 原文；目前語音不校正道路稱呼。 | 等原文確認，再按道路身分局部改成「駛入水源快速道路」。 |
| 3 下水源及秀朗分岔 | C | 未取得該路線的完整步驟，不能判定 Apple 漏步或 App 漏播。 | 比對原文、動作點及語音事件，缺拓撲時不憑角度編造匝道提示。 |
| 4 IKEA及缺區間 | A | 52支區間相機有15支未被既有路形涵蓋；IKEA文字沒有省道里程。 | 接新北雙端門架清單；其他缺口逐筆補證據，不直接放寬300m。 |
| 5 地下道車道提示 | C | 原文與車道資料未取得，現有導航只處理文字和2D折線。 | 等 replay；先保留原文細節，有可靠車道資料才補「中間車道」。 |
| 6 區間超速太頻繁 | B | 共用3秒嗶聲、門檻抖動會重念，且歸零沒有停止瞬間超速分支。 | 區間警報獨立節流並決定歸零後政策；固定照相不連帶停用。 |
| 7 北宜第二段偏移 | A | 現用里程牌端點與警方門架相差75.2–91.3m，貼齊只改路形。 | 改採各方向官方門架，保留公告長度及既有區間群組設定。 |
| 8 迴轉仍倒數 | A | 距離只累加，沒有反向進度／退回起點的中止條件。 | 以可靠定位的沿路進度與持續反向判斷中止，避免誤殺髮夾彎。 |
| 9 銀河附近缺點 | C | 地標不是精確相機位置；現有來源尚無可確定對應的新點。 | 要行向、座標／地圖標記及設備照片後，再查核是否新設或方向誤判。 |
| 10 回程上水源 | C | 尚無當次上匝道的 Apple 原文與語音事件。 | 等回程 replay，依是否有步驟分別修進度／語音或補已核實提示。 |
| 11 近距全文播報 | B | 首次近距依既定規格念全文；超速另送一段緊急語音。 | 決定首次近距是否也縮短，並合併同筆近距＋超速語句。 |
| 12 關閉後定位／活動 | B | 背景巡航是設計；強制結束沒有可靠收尾，stale也不是移除。 | 明確「停止巡航」、補停止競態及過期畫面，不承諾滑掉就能收尾。 |
| 13 資料蒐集與新類型 | B | 現況以7320為主，地方清單與群眾查核尚未整合。 | 先官方多來源與品質稽核，再加人工審核回報及非測速警告。 |
| 14 字卡大小 | A | 外寬相同，但導航34pt／56pt圖示欄，測速46pt／64pt。 | 共用視覺比例、對齊與最小高度，保留區間三行及文字自適應。 |
| 15 3D遮擋與藍線 | B | 55°視角、無描邊藍線；實際建物遮擋尚未重現。 | 先比較2D／減弱底圖及雙層線稿，不先指定任意新色碼。 |
| 16 點地圖導航 | A | POI全排除，選取只接受照相ID，沒有一般地點／長按目的地流程。 | 分版本加入POI／長按選點，沿用目的地預覽後開始導航。 |

## 範圍、證據與限制

- 基準為 `main` 的 `6bef5f2`；本輪只改本文件、回放案例及診斷腳本，未改 App、核心、資料處理或產品資料，未 push／觸發 workflow。
- IPA快照：`build\ipa-latest\cameras.json`，version `2026-11-07`、generatedAt `2026-11-07T14:04:24Z`；1,887點、79段；SHA256 `b7fce24d26e08fba775a0612cd519bfca6395081295c7692ac02f8cfffa1791c`。空的內建佔位檔不列入計算。
- 11/12下載7320原始CSV為1,909列，與IPA去重後點數不是同一指標；公開來源是調查時的版本，不冒充11/08資料。OSM擷取基準為2026-11-12。
- 本輪沒有 Swift 執行、MapKit replay、實機錄音或 App 截圖；「讀碼／Python條件計算」不代表已跑過核心或重現實車聲音。A表示缺口有證據，不表示當日每個事件已重現。
- 本機證據留在忽略的 `build\`：`analyze_1108.py`、`compare_1108.py`、`test2-1108-audit.json`、`research1108\`。重算：`python -I -X utf8 build\analyze_1108.py audit`、`python -I -X utf8 build\compare_1108.py`。
- 必須等 replay 才能判根因：**2、3、5、10**；另補核 **1、4、6、7、8、11** 的事件與時序。9仍缺現場位置，12需實機生命週期資料，14／15需截圖，不會靠核心 replay 冒充驗證。

## 1. 建國南向誤報國一 — A／高

- **重現**：Python以真實OSM建國快速道路線段取樣，確認相關性與預告門檻成立；尚未跑 Swift 事件，是否就是當次目標等「去程01」。
- **原因／數字**：IPA `8cb3e650d46a` 原文「國道一號南向279公里」，`(25.042383,121.533010)`、heading180°、速限110、無axis／level。OSM [way 910959595](https://www.openstreetmap.org/way/910959595) 上 `(25.046656872,121.536639020)` 南向181.66°，距599.6m、前方差35.91°、取締方向差1.66°，符合45°／60°及600m門檻。
- `Packages\SpeedCamCore\Sources\SpeedCamCore\CameraAlertEngine.swift:308` 的 `isRelevant` 不讀level；`data-pipeline\speedcam_data\normalize.py:70` 的 `parse_coordinates` 只驗台灣範圍，`normalize_rows:313` 沒驗地址與道路是否相符。真正圓山國一22.7K在 `(25.073050,121.536865)`，距市民示意點約3.0km，不應直接認定是它。
- [國道警方13940](https://data.gov.tw/dataset/13940) 115-07-20 CSV同名279K為 `(23.373209,120.350715)`，和IPA差220,962.2m；11/12的7320仍是錯座標，已確認不是單純高架／平面辨識問題。
- **修正／規格／測試**：對同名國道點採專責警方座標並保留來源衝突紀錄；加道路一致性稽核、拒收需人工確認的異常點。測正確279K仍提醒、台北不提醒、圓山真正國一點不被誤刪；不全域縮角度，也不只對重機藏國道。高把握於資料錯誤，實車目標ID仍待log。

## 2. 上水源說「高速公路」 — C／低（原句未取得）

- **重現**：沒有。`SpeedCam\Navigation\RoutePlanner.swift:9` 仍用 `.automobile` 路網再依紅黃牌規則選路；不等於原文必定寫「高速公路」。
- **已知鏈路**：`SpeedCam\Data\MapItems.swift:62` 的 `stepInfos` 保留instructions；`SpeedCam\App\AppModel.swift:571` 的 `handleRouteEvent` 經 `AnnouncementFormatter.maneuver` 念原文；`Packages\SpeedCamCore\Sources\SpeedCamCore\RouteProgress.swift:251` 的 `ManeuverText.short` 只縮畫面。尚無該步的距離／原文可引用。
- **待資料**：「去程02」找 `步驟` 的原文／終點座標、`短句`、`notice`、`語音`，並確認路線真的接水源。若不符實車，要當時iOS、App車種設定、目的地及上匝道位置／錄音。
- **條件式修正／規格／測試**：若原文用詞誤導，選項為保留Apple全文，或僅對身分已核實的快速道路改「駛入＋路名」（建議後者，需核准變更既定語音全文規則）；不能全域把高速改快速。補快速道路、真正國道、英文及道路身分未知的案例；「hasHighways」是整條路線資訊，不能當該匝道的分類。

## 3. 下水源、秀朗橋分岔沒提示 — C／低

- **重現**：沒有，等「去程03」；缺Apple當次步驟與實車所走分岔，尚不能說是Apple漏給。
- **可能分界而非結論**：`Packages\SpeedCamCore\Sources\SpeedCamCore\RouteProgress.swift:137` 選尚未走完的有字步驟，`announceIfNeeded:197` 用500／200m與40m或3秒門檻；`SpeedCam\Alerts\VoiceAnnouncer.swift:29` 的緊急近距／超速會打斷既有語音，replay不執行此音訊排程。
- **待資料**：對照下匝道與秀朗分岔各自的步驟終點、折線累計、短句與語音事件；原文有、事件無才追進度，事件有而實機沒聽見才查音訊打斷。兩者皆無才評估補提示。路線若沒經過實車出口，需確切出口／地圖標記。
- **修正／規格／測試**：有步驟就針對漏失鏈路修；缺步驟時，`road_lines.json`只有國道／白牌限制道路線形，沒有匝道拓撲或車道，單憑2D折線不能區分高架、匝道及平行道路。可另查OSM link、layer與接續關係或人工熱點，不能保證補出左右車道。測相鄰短步驟、直行不上橋、上下匝道、導航與相機同秒播報；保留逐向導航時點語意。

## 4. IKEA區間與全部未涵蓋點 — A／高（IKEA）；個別未知原因另列

- **重現**：以Python照 `Packages\SpeedCamCore\Sources\SpeedCamCore\CameraAlertEngine.swift:329` 的 `isCoveredBySection`，計算各點到79段 `displayPath` 的最短線段投影距離；52支section中37支≤300m、**15支不成立**。這是IPA原始path，不是手機貼齊快取後的結果。
- **原因**：`data-pipeline\speedcam_data\section_text.py:141` 的 `parse_section_text` 只解省道＋里程；`:255` 的 `to_sections` 還可能因缺里程牌、3km檢查等略過。`sections.py:118` 的 `apply_official_lengths` 只覆寫長度，不會生出缺少的起終點。

| 相機ID／地址原文 | 緯度,經度 | 最近path距離m | 缺口／補查結果 |
|---|---|---:|---|
| `0e7161fa2172` 台15線鳳鼻隧道 | 24.879920,120.954670 | 15193.0 | 無里程範圍；新竹172950有區間來源，但本輪下載中斷，尚未核對雙端。 |
| `2fb96051dd5e` 松藝路段 | 22.669724,120.343020 | 33993.5 | 無里程；高雄176559有南北向單點與1307.7／1298.9m長度。 |
| `4d1eae33edb5` 金門大橋5K至0.5K(西向) | 24.452068,118.303474 | 217998.6 | 非省道；金門178120有各方向單點，未提供每方向雙端。 |
| `51e9d03091e7` 內門區市道182號28.9K至31.8K | 22.924803,120.421616 | 7362.4 | 非省道；高雄176559有兩行向單點及2884.7／2877.2m。 |
| `5fbb2c356430` 縣道140線16.2公里至16.9公里及23.1公里至25.1公里 | 24.345043,120.744514 | 14830.5 | 非省道；苗栗178412卻寫16.2–23.1K及23.1–25.1K，需先查版本衝突。 |
| `685b30491485` 環河路（中央路至白馬寺，雙向） | 24.971820,121.529236 | 2336.6 | 無里程；新北126156已提供雙向各自的兩端及長度，可直接補查核資料。 |
| `6e3333464fc5` 萬壽路一段(東萬壽路309巷-萬壽路一段1275巷) | 25.011770,121.375620 | 6882.3 | 無里程；桃園171463是路段／件數表，無座標欄，尚缺門架證據。 |
| `78bf714072b1` 台62線快速道路1.7K至0.7K(瑪陵隧道東往西)區間測速 | 25.128988,121.697014 | 3336.1 | **可解析台62 1.7→0.7**；79段沒有，建置原始里程牌／略過log未取得，確切略過原因未知。 |
| `7ea04ff5498d` 新莊區壽山路（北118線0K至1.2K）（往新莊方向） | 25.043957,121.398260 | 4836.7 | 非省道；新北126156已有雙端及1171.6m。 |
| `8c99988e81d4` 蘇花改中仁隧道 | 24.266958,121.724700 | 641.2 | **區間已存在**；無path改用隧道口直線，點離直線>300m，不是整段漏收。 |
| `966bcdb9a389` 市道182線27.2248公里至28.358公里處(往高雄)；市道182線28.3378公里至27.1907公里處(往關廟) | 22.950447,120.383260 | 9146.5 | 非省道；臺南53645是文字位置清單，尚未取得可驗雙端。 |
| `9e3bea6232ce` 青山路二段(青山路一段200號-青山路二段文青路) | 25.031464,121.398220 | 4474.2 | 無里程；同桃園171463限制，不能直接把門牌地理編碼當門架。 |
| `cc90365931d5` 台62甲線3號隧道出口處至東海街出口(南往北)區間測速 | 25.124674,121.779380 | 3884.6 | 無里程範圍；基隆173070為位置／長度PDF，未取得可核實雙端。 |
| `eb43bac517ef` 龍井區向上路6段與中興路口至沙鹿區向上路6段與自立路口 | 24.187630,120.573460 | 6029.5 | 無里程；臺中172725有1601.16m與單點 `(24.202772,120.568183)`，不能當完整門架對。 |
| `ee7939e0a881` 金門大橋0.4K至5.1K(東向) | 24.446750,118.262360 | 221970.3 | 非省道；同金門來源限制，且CSV經緯欄名與值顛倒。 |

- **IKEA可用證據**：[新北126156官方CSV](https://data.ntpc.gov.tw/api/datasets/27b97ad9-9dba-4ca9-b0ed-14b29000ffec/csv/file) 第7列，速限60：往碧潭 `(24.9718199,121.5292394)`→`(24.9641247,121.5367909)`、1293.1m；往臺北 `(24.9639108,121.5369783)`→`(24.9712441,121.5309406)`、1138.6m。不能用同一對座標直接反轉；原7320方向卻只寫「東西雙向(區間測速)」。
- **公告查核**：來源格式／授權見第13項；新北雙端已實際讀取，高雄／金門／苗栗／臺中已讀下載檔。單一行向座標、對向起點、路口地理編碼不等於該方向終點。桃園／臺南／基隆目前僅核到中繼資料；基隆PDF未解析，新竹連線中斷，不能說已查完各縣市公告。
- **修正／規格／測試**：資料流程新增官方區間來源適配及「section相機未涵蓋」稽核，IKEA／壽山先補可核實雙端；中仁補彎曲路形或明確相機關聯。保留300m、未對應時仍單點提醒的規格，不把它們全部靜音；測不同方向不同長度、欄位顛倒、非省道、多段衝突、中仁曲線及相鄰平行道路。瑪陵須由建置log確認略過理由，不能猜成解析失敗；「去程04／回程02」補查IKEA實際事件。

## 5. 地下道只提示左轉 — C／低（漏失環節）；道路線索中

- **重現**：沒有，等「去程04」。[OSM way 189011740](https://www.openstreetmap.org/way/189011740) 為環河路、destination北宜路、tunnel=yes、layer=-2、lanes=1，約 `(24.9621328,121.5369447)`→`(24.9615023,121.5379752)`；這不能證明入口前要走「中間車道」。
- **原因待分辨**：`ManeuverText.short`（`Packages\SpeedCamCore\Sources\SpeedCamCore\RouteProgress.swift:251`）取動作與路名，可能不保留後續子句；語音原文不經它。`SpeedCam\Data\MapItems.swift:62` 沒有保留車道／隧道結構，不能據讀碼斷定原文曾有地下道。
- **待資料／修正／規格／測試**：找地下道前步驟原文、notice、短句、終點及語音；確認選到的路線經過此通道。若原文有資訊，保留重要「走地下道」提示；若無，選擇只補經核實的地下道動作（建議），或另建人工車道資料。「走中間車道」須入口照片／路口標記與行向佐證，不能從隧道單車道推論。測隧道支線與平面分岔、中文長句、保留先前動作＋路名原則。

## 6. 區間警報頻率與歸零 — B／高（程式分支）；實際聲音未驗證

- **重現**：讀碼＋算式成立，尚未執行Swift／錄音。`Packages\SpeedCamCore\Sources\SpeedCamCore\SectionSpeedTracker.swift:396` 的 `advance` 先更新倒數，`:412` 仍直接判 `speedKmh > threshold`；歸零不關閉此分支。`AlertSettings.swift:21` 預設每3秒；一降到門檻內就ended，再超出立即started，沒有遲滯或語音冷卻。
- **數字**：北宜1往宜蘭3938.1m、40＋10、3%餘裕，最短292.049496秒；經過300秒、當下60仍會進超速分支。49／51反覆變動也會反覆發開始語音。`SpeedCam\App\AppModel.swift:84` 的 `isOverspeed` 同樣未檢查歸零；`:539` 只在相機已超速時抑制區間重複聲。
- **選項／建議**：維持3秒、改全域間隔，或區間獨立節流。建議區間嗶聲15秒、語音30秒冷卻並加持續／恢復條件，固定照相仍3秒；具體數值需使用者決定。歸零後可保留瞬間提醒，或停止「區間平均門檻」提醒（依本次需求建議後者）；固定照相與真正即時速限警告不連帶關閉。
- **規格／測試**：會改既定3秒及目前共用門檻警示政策；倒數、+10／個別容許值與3%餘裕不變。+10不是警方保證寬限，歸零也不表示可任意超速。同步核心、App超速狀態、Live Activity；測門檻抖動、歸零同秒、固定相機重疊及各方向容許值。「折返02」找歸零後剩餘0秒卻再started／beep，事件間隔用t值計算；不把每分鐘倒數誤算成超速語音。

## 7. 北宜第二段偏移 — A／高（門架差異）；實車偏移方向未確認

- **重現**：真實資料對官方門架計算有差異，非實機／replay重現。`data-pipeline\manual\sections.csv:19` 用里程牌：26.2K `(24.950865,121.647163)`、32.2K `(24.943742,121.670798)`。
- **官方比較**：[新北126156](https://data.gov.tw/dataset/126156) 第2列，往宜蘭 `(24.9504174,121.6477995)`→`(24.9429879,121.6708659)`，差81.2／84.1m；往新店 `(24.9430715,121.6708954)`→`(24.9503516,121.6478697)`，差75.2／91.3m。四者都大於60m門架半徑；直線差不是沿路提早／延後距離。第1、3段也有36.7–105.6m差異，應同源查核。
- **排除與限制**：第二段現端點離OSM台9路形僅6.6／7.1m，所以「在路上」不等於「在照相門架」。7040本輪取不到，不能聲稱已重下載里程牌驗證。IPA path56點、長5457.6m，較公告往宜蘭5835.3m短377.7m；不能因此改短警方偵測長度。
- `SpeedCam\Data\SectionPathSnapper.swift:108` 的 `snap` 只貼齊path，不改start/end；`SpeedCam\App\AppModel.swift:653` 的 `applySnappedPath` 也只改畫面資料，核心要到重新套用資料才用同份path，可能另有顯示／核心路形不同，尚不能認定就是此次回報。
- **修正／規格／測試**：採各方向官方門架、重算進入方向及路形，保留5835.3／5830.5m與groupID，讓貼齊更新一致進核心但不任意reset正在計時區間。測雙向接近、門架前後60m、快取失效及重開前後一致；不改26.2–32.2K範圍與容許值規格。「北宜2去程／回程」對照entered／completed座標；仍需使用者指出是橘線、起點或終點、行向、偏前後多少及現場門架照片，才能確認實車症狀完全相同。

## 8. 區間中迴轉後仍提醒 — A／高（狀態缺口）

- **重現**：讀碼＋距離條件計算成立，Swift事件等「折返01／02」。`Packages\SpeedCamCore\Sources\SpeedCamCore\SectionSpeedTracker.swift:195` 的 `process` 有active就繼續advance；`:403` 只加兩定位間距，不扣反向進度，`:481` 的剩距離也用這個累計值。
- **數字／原因**：北宜1進去1000m再回起點約累加2000m，未達中止4538.1m。`:450` 只有累計>L+600、離終點>L+1000或時間>最短時間×4+600；無反向越過起點／離路形中止。也沒接近終點，故仍active，且會擋住反方向區間啟動。
- **修正／規格／測試**：以沿路投影進度持續後退、可靠定位與退回起點判斷aborted，清區間聲音／狀態，允許之後真正再入門架；不要只拿當下方位對「初始方向」比較，北宜髮夾彎會誤判。測正向髮夾彎、段內迴轉、越起點、繞出路線、GPS跳點、隧道缺定位及反方向重新進入；不更改正常終點判定與3%規格。尚未驗證手機GPS抖動所需持續門檻。

## 9. 過銀河社區的相機 — C／低

- **重現**：無法確認是哪一支，也不能直接判為缺點。7320及[新店146363](https://data.gov.tw/dataset/146363) 有「北宜路2段348號對面（往新店）」`(24.953762,121.562910)`，IPA ID `876cfdf63a7e` 已收錄，速限50；不是用「銀河」當地址。
- **查核界線**：OSM [銀河洞公車站2501798389](https://www.openstreetmap.org/node/2501798389) 在 `(24.9561706,121.5698330)`，離上述點747.6m；此站不是使用者指認的相機。已查OSM框24.94–24.97／121.54–121.59內speed_camera節點，沒有可確定對應的新點。立法院2026-05清單本輪未取得原檔，不算「已查無」。
- **要的資料／建議／測試**：要相機地圖標記或經緯度、往坪林／往新店、設備與速限照片、最近路口／門牌、固定或臨時設備；若已有提醒失敗要發生時間／App版本。核實後才新增 `data-pipeline\manual\cameras_extra.csv`，或查 `Packages\SpeedCamCore\Sources\SpeedCamCore\CameraAlertEngine.swift:308` 的 `isRelevant` 方向／距離，而不是猜座標；測雙向、附近已收點去重及新設／撤除來源追溯。不變更提醒距離規格。

## 10. 回程環河上水源無匝道提示 — C／低

- **重現**：沒有，等「回程03」，不要用去程原文代替。測試終點為OSM水源快速北向 `(25.0060321,121.5341731)`，並非使用者提供的入口GPS。
- **待資料／原因分界**：查 `SpeedCam\Data\MapItems.swift:62`、`Packages\SpeedCamCore\Sources\SpeedCamCore\RouteProgress.swift:137`、`SpeedCam\App\AppModel.swift:571`：原文是否有上匝道、該步終點／累計、短句、語音事件有沒有進播放候選；沒有實車入口位置時，路線不同仍可能重現不到。
- **修正／規格／測試**：同第3項按證據修進度、音訊或加入經核實的道路接續提示；如果Apple只給「靠左／靠右」，不能當作App把「上匝道」刪掉。補同向上匝道、平面直行不上、前後緊接轉彎與測速同時事件；不得因要走快速道路而全域關閉紅黃牌避國道規則。仍需當時車種設定、iOS及入口標記以對準實車。

## 11. 近距念全文、希望「100公尺，超速」 — B／高（語句分支）

- **重現**：讀碼確認兩條語句分支，未重現實機聽到的完整聲音。`CameraAlertEngine.swift:221` 的 `advancePhase` 首次就在near時afterPre=false；`SpeedCam\App\AppModel.swift:509` 的 `handleCameraEvent` 此時送全文，已pre才只念距離，另遇overspeedStarted再送「您已超速，速限N」。句型見 `Packages\SpeedCamCore\Sources\SpeedCamCore\AnnouncementFormatter.swift:26` 的 `cameraAlert`、`:35` 的 `cameraNearAfterPre`、`:44` 的 `overspeed`。
- **例子／原因**：IPA `3de5c6fd4567`「北宜路1段246號前（往坪林）」速限50，語音01從沿OSM約80m前、車速60開始，門檻100m且播報距離會取100；會送「前方100公尺，…，速限50」與另一句超速。`SpeedCam\Alerts\VoiceAnnouncer.swift:29` 對urgent會打斷前句，不保證兩句都完整播完。「語音01」查afterPre=false及超速開始；其他路段看是否afterPre=true卻另聽到超速語句。
- **選項／建議／規格**：可只把已預告時的近距＋超速合一句，或首次近距也統一簡短。建議已預告改「距離，超速」、未超速只念距離；首次仍保留速限／設備資訊，除非使用者確認要一併刪。後者會改11/07「首次近距念全文」規格，不能暗改；速限≥80時近距仍200m，不硬編100。
- **修正／測試**：在App事件批次層合併同目標近距與超速，避免兩個urgent互切；保留其他目標及非測速設備資訊。測首次near、已pre、near與over同秒、100／200m、近到需念實距及無速限；replay只能核事件，AVSpeech／CarPlay仍需錄音。

## 12. 關閉後定位與Live Activity — B／中

- **重現**：沒有實機操作紀錄；先分「回主畫面／鎖屏」、「App內停止巡航」、「切換器滑掉」、「系統終止後重啟」，不能混稱關閉。Live Activity存在不等於App仍在定位。
- **程式**：`SpeedCam\App\AppModel.swift:186` 預設自動巡航；`:260` 的 `startCruise` 開背景定位，`:288` 的 `stopCruise` 確有停定位／活動／聲音。`SpeedCam\Location\LocationProvider.swift:54` 開CLBackgroundActivitySession，`:69` 舊版允許背景且不自動暫停，`:80` 的stop會invalidate／stopUpdatingLocation。退背景持續巡航是既定需求。
- **已知停止缺口但非強制結束根因**：`AppModel.swift:223` 的取消sleep被try?吞掉，可能再tick一次，`:233` 無isCruising guard；stop也未取消preview／重設核心。待啟動的預覽可能再進導航。應補取消guard與停止清理，但不能宣稱這已解釋滑掉後持續定位。
- **系統依據**：[Apple強制結束說明](https://developer.apple.com/forums/thread/685525) 指滑掉會終止並通常禁止背景重啟；[willTerminate](https://developer.apple.com/documentation/uikit/uiapplicationdelegate/applicationwillterminate(_:)) 不保證呼叫。[ActivityKit](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities) 活動可獨立存在，最長8小時、結束後鎖屏最長再留4小時。
- `SpeedCam\LiveActivity\ActivityController.swift:108` 初次request staleDate=nil，`:187` 更新才設+120秒；[staleDate](https://developer.apple.com/documentation/activitykit/activitycontent/staledate) 只標過期、不移除，`:164` 的end才明確immediate。不能靠willTerminate或本機背景計時保證force-quit後end，也沒有APNs補救。
- **選項／建議／規格／測試**：建議保留背景巡航、讓「停止巡航」清楚可達，初次就設過期時間、Widget以isStale顯示過期並停止呈現舊車速，重開時按明確巡航狀態清理／接回；另一方案「退背景就停」會破壞鎖屏／CarPlay，須使用者先決定。要iOS／機型、關閉方式、隔多久、定位指標及鎖屏錄影；分別測停止、預覽待開始、鎖屏、滑掉、OS終止、重開、過期，replay驗證不到。

## 13. 蒐集方式、科技執法及噪音 — B／中（官方來源高；競品未知）

- **重現／根因**：資料盤點及讀碼，非缺點數量的完整實車重現。IPA有fixed1805、section52、redLightSpeed8、redLight6、tech16，沒有mobile；不能說完全沒科技執法。`data-pipeline\speedcam_data\sources.py:13`、`build_cameras.py:113` 主要抓7320＋人工檔，沒有下表各地方來源適配；`Packages\SpeedCamCore\Sources\SpeedCamCore\Models.swift:4` 的 `CameraType` 也沒有噪音／細項有效條件。
- **競品公開查核**：神盾官方商店頁／Google Play本輪存取受限；[Mio官網](https://www.mio.com/tw/)亦受限，未取得可驗的蒐集來源、人工／群眾審核流程、更新頻率或資料再利用授權；**未知，不推定，也不抓取其私人資料庫**。另可核實的[Google官方回報說明](https://support.google.com/maps/answer/3273406?hl=zh-Hant&co=GENIE.Platform%3DiOS) 有警方／流動測速回報與到點是／否確認，這是回報機制參考，不是本App可下載的開放資料來源。
- **已核官方來源**：下表「有座標」不代表足夠建立雙向區間；1.0為政府資料開放授權條款1.0。未宣稱完成所有縣市盤點。

| 來源／類型 | 格式 | 原生座標／限制 | 授權 | 官方更新頻率 |
|---|---|---|---|---|
| [7320 全國固定／區間等](https://data.gov.tw/dataset/7320) | CSV | 有，含第1項錯值 | 1.0 | 不定期 |
| [13940 國道固定](https://data.gov.tw/dataset/13940) | ZIP內CSV | 有，含方向／取締項目 | 1.0 | 不定期 |
| [130111 臺北固定與區間](https://data.gov.tw/dataset/130111) | CSV | 有，須辨設備功能 | 1.0 | 不定期 |
| [126156 新北區間](https://data.gov.tw/dataset/126156) | CSV | 14列，複數方向／匝道的雙端藏在同欄多值 | 1.0 | 每1年 |
| [172950 新竹區間](https://data.gov.tw/dataset/172950) | CSV／XML／JSON | 有緯經欄；下載中斷，端點完整性未核 | 1.0 | 不定期 |
| [176559 高雄區間](https://data.gov.tw/dataset/176559) | JSON／CSV | 每行向1點＋長度，並非完整雙端 | 1.0 | 不定期 |
| [178120 金門區間](https://data.gov.tw/dataset/178120) | CSV | 2列單點；經緯欄名顛倒；無雙端 | 1.0 | 頁面只寫「每」，週期不明 |
| [178412 苗栗區間](https://data.gov.tw/dataset/178412) | Big5 CSV | 14列單點，亦有經度122.6769異常；140線範圍衝突 | 1.0 | 不定期 |
| [172725 臺中區間](https://data.gov.tw/dataset/172725) | CSV | 3列單點＋長度／執法項目 | 1.0 | 每6月 |
| [171463 桃園區間統計](https://data.gov.tw/dataset/171463) | CSV | 無座標欄，內容年度2024，非最新門架證據 | 1.0 | 不定期 |
| [173070 基隆區間](https://data.gov.tw/dataset/173070) | PDF | 欄位為位置／長度／件數，未解析雙端 | 1.0 | 不定期 |
| [53645 臺南違規照相](https://data.gov.tw/dataset/53645) | JSON／CSV | 位置文字，無座標欄 | 1.0 | 不定期 |
| [164507 新北路口科技](https://data.gov.tw/dataset/164507) | CSV | 有，含取締項目／方向 | 1.0 | 不定期 |
| [173697 彰化聲音照相](https://data.gov.tw/dataset/173697) | CSV | 地址，無經緯欄 | 1.0 | 不定期 |
| [156743 臺南聲音照相](https://data.gov.tw/dataset/156743) | JSON／CSV | 路段文字，無經緯欄 | 1.0 | 不定期 |
| [170672 臺中移動式](https://data.gov.tw/dataset/170672) | CSV | 本次386列經緯全空；是候選執法地點，不是即時出勤 | 1.0；頁面標付費，需釐清 | 每6月 |
| [OSM道路／相機](https://www.openstreetmap.org/copyright) | Overpass JSON／OSM | 有座標／tag，但覆蓋與正確性無保證 | ODbL，需評估衍生資料庫義務 | 社群持續編輯，無保證週期 |

- **選項／分階段建議**：可維持單一官方源、擴政府多源，或再做群眾回報；建議①先接國道／新北雙端與地方固定、做錯位／去重／來源衝突／未涵蓋報表；②以獨立警告類型接科技執法、噪音，保存取締項目、適用車種／時段／生效日，沒有速限就不發超速聲；③再做座標＋行向＋照片＋時間的人工審核回報，臨時移動點要到期／再確認，未核實不自動上線。競品回報機制查不到不妨礙先做①，維護人力與回報後端仍需使用者決定。
- **規格／測試／限制**：會擴充既有種類、設定／語音／圖示／Widget與資料授權標示，不能把所有「科技」當測速。補跨來源穩定ID、相反行向不誤合併、欄位顛倒、缺座標、撤點／到期及區間門架測試。既有兩段距離／一般超速規則不擅改；7040回HTML、警方新北官網連線失敗、立法院原檔未取得、競品商店／Mio受限，均未視為查無。

## 14. 導航與測速字卡大小 — A／中（未看同場景截圖）

- **重現**：讀碼確認度量不同，尚無視覺重現。`SpeedCam\Map\RootView.swift:27` 同一VStack、水平padding12，所以外寬原本相同；不能把問題說成兩種固定寬度。
- **原因／數字**：`SpeedCam\Map\Banners.swift:20` CameraBanner距離46pt／速限牌64pt；`:129` NavigationBanner距離34pt／圖示欄56pt，路名最多2行與目的地footnote，內容決定高度；兩者padding14、圓角20已相同。SectionBanner還有既定三行，歸零又少一行。
- **修正／規格／測試**：統一圖示欄、距離字級、基線與最小高度，不固定死高度造成截字，也不刪區間三行。若要求任何狀態都絕對等高，須另決定空白／文字取捨。下一階段以 `-gallery -galleryBanners` 加同時導航＋相機／區間的組合，375pt／390pt、最長路名／類型、歸零／重規劃及放大字體實看截圖；保留不透明BannerStyle與白字對比，不在本輪改UI。

## 15. 3D建物遮線、夜間辨識 — B／中（靜態設定高；實際遮擋低）

- **重現**：尚未實機／截圖重現。`Packages\SpeedCamCore\Sources\SpeedCamCore\MapFollow.swift:33` 3D為55°；`SpeedCam\Map\RootView.swift:279` 路線藍色7pt、預覽8pt／0.85透明，無外框，區間橘虛線畫在後面；`SpeedCam\App\SpeedCamApp.swift:22` 強制dark。`SpeedCam\Map\LegacyMapView.swift:148` 用aboveRoads，`:278` 同樣systemBlue且無描邊。
- **MapKit能力**：[MKOverlayLevel](https://developer.apple.com/documentation/mapkit/mkoverlaylevel) 說aboveLabels仍低於3D建物，不能承諾改層級就解決；[showsBuildings](https://developer.apple.com/documentation/mapkit/mkmapview/showsbuildings) 又註明iOS16+有overlay時不生效、建物／樹應透明，與回報需同場景對照。本輪未找到可「指定建物高度」的公開API；[SwiftUI elevation.flat](https://developer.apple.com/documentation/mapkit/mapstyle/elevation/flat) 定義2D渲染，不等於已驗證55°仍能按預期保留前向視角。
- **導航慣例查核**：[Google導航SDK](https://developers.google.com/maps/documentation/navigation/android-sdk/controls) 支援關閉3D建物與自動日／夜模式；[Google Maps iOS說明](https://support.google.com/maps/answer/3273406?hl=zh-Hant&co=GENIE.Platform%3DiOS) 也有「顯示立體建物」。[Apple HIG](https://developer.apple.com/design/human-interface-guidelines/maps) 建議資訊多時用muted底圖與足夠對比；HIG對overlay層的概述不能取代上述API對3D建物的明確限制。
- **配色證據／未知**：已實看[Google官方自訂樣式圖1](https://developers.google.com/static/maps/documentation/navigation/images/android-cbms-1.png)，是亮底、藍線與深色外緣；[圖2](https://developers.google.com/static/maps/documentation/navigation/images/android-cbms-2.png) 是無導航線的全洲圖，**都不能當夜間預設證據**。[日夜文件](https://developers.google.com/maps/documentation/navigation/android-sdk/lighting-modes) 區分夜間導航與系統dark；未取得可可靠判讀的Apple／Google零售App夜間導航圖及預設RGB／描邊規格，故不宣稱兩者固定用某色或白框，也不把SDK主題header色當路線色。
- **選項／建議／規格／測試**：先做同座標55°／2D、標準／muted及「藍色主線＋對比外框」小樣；建議先處理底圖干擾與描邊，再決定是否換色，保留橘色區間及交通顏色語意。2D最可靠但會改使用者選的3D模式；若自動降傾角或關建物需先決定。要遮擋位置／行向／縮放截圖，並用iOS15／16／17+同場景、日夜、水面深藍底、彎後建物、路線與區間重疊、色覺與最窄尺寸截圖比較，再定色碼；replay本身驗不到渲染。

## 16. 直接點地圖目的地 — A／高（功能缺口）

- **重現**：讀碼確認沒有流程，未以UI操作重現。`SpeedCam\Map\RootView.swift:267` 的selection是照相String ID，`:314` POI excludingAll；`SpeedCam\Map\LegacyMapView.swift:45` 同樣隱藏POI，`:233` 的didSelect只接受CameraAnnotation，`:76` 只有拖移／縮放／旋轉手勢，沒有長按放點。
- **修正／版本邊界**：[iOS17 MapFeature](https://developer.apple.com/documentation/mapkit/mapfeature) 支援原生地點選取，可與照相自訂點擊分流；[MapSelection](https://developer.apple.com/documentation/mapkit/mapselection) 是iOS18+，不能拿它當17共用解法。iOS16的MKMapView可設[selectableMapFeatures](https://developer.apple.com/documentation/mapkit/mkmapview/selectablemapfeatures)，delegate需辨識MKMapFeatureAnnotation；iOS15以長按座標放圖釘、反向查地址／手動名稱作備案，不能承諾同等原生POI點擊。
- **規格／測試**：解除必要POI過濾，長按任意位置先顯示選點卡，再沿用 `SpeedCam\App\AppModel.swift:345` 的 `beginPreview(to:)`，不要直接導航跳過地點預覽／10秒倒數。保留照相點完整詳情、預覽隱藏相機與拖圖暫停倒數；測POI／空白長按、相機不誤導航、查地址失敗可用已選座標、舊系統availability、VO與44pt按鈕，新增CI選點／預覽狀態並實看截圖。

## Replay交接與log驗收

- `scripts\ci\route-replay-1108.json` 共19案例：去程01–04、北宜四段雙向、回程01–04、折返01／02、語音01。假設App選紅黃牌；城市錨點取OSM真實道路，北宜從既有端點附近沿OSM取前後約400m，近距案例從已知相機沿路退約80m；**不是當日GPS、不是合法迴轉點或建議實車車速**。
- 「約80km、坪林前來回、4段」不足以確認騎過資料中的四個完整區間，尤其56.6–68.6K；後兩段／宜蘭端均作擴充檢查，不據此改寫實測行程。
- `scripts\ci\route-probe.swift:294` 的 `runReplay` 對新案例用App RoutePlanner／RouteRules選重機路線；舊案例未設vehicleMode仍走原汽車請求。輸出資料version／generatedAt／數量、各步原文／notice／短句、事件時間／座標／車速／相機ID方向、超速全部事件及每30秒區間狀態；規劃失敗明確記錄並回傳失敗，不當作已測。
- 新增的可選折返／停等欄位只供診斷：同一leg保留同一核心，先行1400m再反向回到起點附近；折返02先停350秒。返程不檢查去程導航，也不模擬重新規劃／車道／實際AVSpeech。其他獨立leg仍重設核心，不能拿兩個普通去回leg聲稱驗過第8項。
- **log要查**：去程01找`8cb3e650d46a`；去程02找高速原文；去程03逐一下匝道與秀朗分岔的步驟／語音；去程04與回程02找IKEA單點而無區間；去程04查地下道；北宜2雙向對門架座標；折返01查回到門架前仍active；折返02查zero之後仍超速；回程03查上水源；語音01查afterPre與同秒overspeedStarted。
- 必須先用JSONL路線座標／步驟確認真的經過目標道路與匝道；MapKit可能改路，也可能把高架錨點吸到平面。只看「轉彎相符N／M」不能證明有給匝道／車道提示；核心事件也不等於實際聽到聲音。
- 驗收者再push並跑既有replay workflow，把完整log存 `build\replay-1108.log`。workflow會重新下載政府資料：若筆數／generatedAt不同，先記錄新版本，不把快照差異誤當程式變化；下載7040失敗或macOS編譯未過，就還沒有可用的replay證據。本機未編譯macOS腳本，待該步驗證；本輪不觸發、不代為push。
