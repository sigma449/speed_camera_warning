# 測速地圖（Taiwan SpeedCam）

以地圖為主的台灣測速照相提醒 App（iPhone），汽車與機車都能用。
CarPlay 先用 iOS 26 的 Live Activity 顯示大字提醒；之後申請 CarPlay 導航權限後，再做 CarPlay 上的地圖。

> ⚠️ 照相點資料僅供參考，請依現場標誌與速限行駛。

## 系統需求

| iOS | 差別 |
|---|---|
| 26 以上 | 全部功能，包括 CarPlay 儀表板上的 Live Activity |
| 17～25 | 沒有 CarPlay 儀表板的 Live Activity |
| 15、16 | 只適合用舊手機測 App 內的功能：地圖和定位是另一套做法；iOS 16.2 以前沒有 Live Activity；iOS 15 不能要求 Apple 避開高速或收費，機車路線和新手機不一樣 |

## 功能（Phase 1）

| 功能 | 說明 |
|---|---|
| 地圖主畫面 | Apple 地圖（MapKit），跟著位置與行進方向移動，標出測速照相點與取締方向 |
| 巡航模式 | 不設目的地，只做測速提醒 |
| 導航模式 | 搜尋目的地 → 規劃路線 → 逐向語音導航（500 m、200 m、轉彎點，車速快時多一次 1 km），偏離路線自動重新規劃；能唯一辨識接續的具名非國道主線時，畫面／語音把「上高速公路」改成「上水源快速道路」等實際路名，國道及未知不改 |
| 車種模式 | 汽車／紅黃牌機車（避開國道和收費道路，可走快速道路和市區高架）／白牌機車（只走平面道路）。機車路線仍是用汽車的路網規劃，不知道哪些路段禁行機車 |
| 兩段提醒 | 一般道路：預告 300 m、近距 100 m；速限 ≥ 80 的道路：預告 600 m、近距 200 m（皆可調整）；已預告且仍超速時近距念「100公尺，超速」，沒超速只念距離，首次近距仍完整播報 |
| 超速警示 | 接近照相點時超速，每 3 秒嗶一聲，直到降速或通過 |
| 方向判斷 | 只提醒取締你這個行車方向的照相點 |
| 區間測速 | 接近起點時預告；顯示倒數、均速、建議車速上限；每分鐘報一次，最後 30 秒、10 秒再各報一次，歸零時提醒；區間超速嗶聲每 15 秒、語音 30 秒內不重複，歸零後停止區間超速提醒（固定照相仍 3 秒）；可靠沿路反向／退回起點會中止，之後可重新進入；隧道裡沒有定位時依時間繼續倒數，固定照相也依時間提醒 |
| Live Activity | 鎖定畫面、動態島，以及 **CarPlay 儀表板**（自訂大字版面） |
| 背景執行 | 螢幕關閉或切到其他 App 仍會提醒；播報時其他音樂自動調小聲 |

## 安裝到 iPhone（不需要 Mac、免費）

請看 **[docs/SETUP.md](docs/SETUP.md)**：申請專用 Apple ID → 在 Windows 用 winget 安裝 iTunes（非 Microsoft Store 版，不需要 iCloud）與 iloader → 用 iloader 把 SideStore 裝到 iPhone → 從 GitHub Actions 下載 IPA → 用 SideStore 安裝。之後每 7 天在 iPhone 上自己續簽，不需要電腦。

## 專案結構

```
project.yml                 XcodeGen 設定（CI 會用它產生 Xcode 專案）
SpeedCam/                   iPhone App
  App/                      App 進入點、中心狀態（AppModel）、設定頁
  Map/                      地圖主畫面、提醒橫幅、操作列
  Navigation/               目的地搜尋、路線規劃、導航
  Location/                 定位（CLLocationUpdate + 背景執行）
  Alerts/                   語音與提示音
  LiveActivity/             Live Activity 控制、預覽頁
  Data/                     內建資料讀取、展示資料
  Resources/                cameras.json（測速資料）、圖示
SpeedCamWidgets/            Widget Extension（Live Activity 畫面）
Shared/                     App 與 Widget 共用的 Live Activity 資料模型與畫面
Packages/SpeedCamCore/      核心邏輯（純 Swift，可在 Linux 測試）
  GeoMath / SpatialIndex    地理計算、空間索引
  CameraAlertEngine         兩段提醒、超速、方向判斷、冷卻
  SectionSpeedTracker       區間測速倒數與語音時點
  RouteProgress             逐向導航進度、偏離路線偵測
  AnnouncementFormatter     中文語音文字
data-pipeline/              Python：下載政府開放資料 → cameras.json
.github/workflows/          CI、建置 IPA、每週更新資料
```

## 開發流程

沒有 Mac 也能開發：程式推到 GitHub 後，GitHub Actions 的雲端 Mac 會自動編譯。

| Workflow | 何時執行 | 做什麼 |
|---|---|---|
| **CI** | 每次 push | 核心邏輯測試（Swift）、資料處理測試（Python）、iOS 模擬器建置與截圖（Artifacts → `screenshots`） |
| **Build IPA** | 手動 | 下載最新測速資料 → 編譯未簽署的 IPA，給 SideStore／AltStore 側載（Artifacts → `SpeedCam-ipa`） |
| **Refresh camera data** | 每週一 | 下載政府開放資料，有變動就開 PR |
| **iOS 15 實際執行** | 手動 | 在 iPhone 7、iOS 15.5 模擬器上開啟 App，確認裝得上、開得起來、沒有閃退 |

本機測試：

```bash
# 核心邏輯（需要 Swift 5.9 以上，或用 Docker）
swift test --package-path Packages/SpeedCamCore

# 資料處理
pip install -r data-pipeline/requirements-dev.txt && python3 -m pytest -q data-pipeline
```

目前 Swift **187** 項、Python **229** 項。本機 Windows 既有 Docker 入口為 `python -I -X utf8 build\swift_test.py`；
須同時唯讀掛載 `SpeedCam\Resources` 到 `/SpeedCam/Resources`，才能執行全部真實道路測試，不能把跳過當成通過。
11/08 的 macOS replay log 另以 `python -I -X utf8 scripts\ci\check-replay-1108.py build\replay-1108-fixed.log` 驗收；
使用 `scripts/ci/route-replay-1108.json`，舊 log／缺案例會失敗。檢查器的人工測試資料不代表真 MapKit 或實機已通過。

## 資料

- 照相點：內政部警政署「測速執法設置點」（政府資料開放平臺，資料集 7320），依[政府資料開放授權條款－第1版](https://data.gov.tw/license)使用。
- 國道同名照相點的座標優先採國道警方資料集 **13940**；按國道編號與道路線形稽核，來源衝突／錯位印在建置報告，不直接刪點。
- 區間測速：從開放資料「設置地點」的文字自動產生（例如「台9線68k+600m至56k+600m」），用公路局「省道里程坐標」（資料集 7040）換算座標；另外有人工維護的 `data-pipeline/manual/sections.csv`（北宜公路）。詳見 [data-pipeline/README.md](data-pipeline/README.md)。
- 新北方向別門架與長度採 **126156**，補新店環河路 IKEA／白馬寺及新莊壽山路，校正北宜前三段；第 4 段不在此來源，仍用原里程牌端點。兩方向各自貼齊並快取；中仁相機明確關聯既有區間。沒有可驗證雙端的其他相機維持單點提醒，報告列出全部清單。
- 新增來源失聯、格式異常或筆數縮減時，明確警告並改用隨 repo 保存的官方快照；連快照也失效就明列未套用該來源，保留原主來源／人工資料，不讓新增來源拖垮整體建置，也不靜默少資料。
- 你也可以在 `data-pipeline/manual/cameras_extra.csv` 補充照相點。

## 路線圖

- **Phase 2**：加入 Apple Developer Program（US$99／年）→ TestFlight → 申請 CarPlay 導航權限 → CarPlay 上的地圖與全螢幕提醒。
- **Phase 3**：重機停車模式（TDX 停車資料＋重機可停／費率的人工整理與使用者回報）。
