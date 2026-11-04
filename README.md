# 測速地圖（Taiwan SpeedCam）

以地圖為主的台灣測速照相提醒 App（iPhone），汽車與重機都能用。
CarPlay 先用 iOS 26 的 Live Activity 顯示大字提醒；之後申請 CarPlay 導航權限後，再做 CarPlay 上的地圖。

> ⚠️ 照相點資料僅供參考，請依現場標誌與速限行駛。

## 功能（Phase 1）

| 功能 | 說明 |
|---|---|
| 地圖主畫面 | Apple 地圖（MapKit），跟著位置與行進方向移動，標出測速照相點與取締方向 |
| 巡航模式 | 不設目的地，只做測速提醒 |
| 導航模式 | 搜尋目的地 → 規劃路線 → 逐向語音導航（500 m、200 m、轉彎點），偏離路線自動重新規劃 |
| 車種模式 | 汽車／重機；重機路線避開國道與收費道路 |
| 兩段提醒 | 一般道路：預告 300 m、近距 100 m；速限 ≥ 80 的道路：預告 600 m、近距 200 m（皆可調整） |
| 超速警示 | 接近照相點時超速，每 3 秒嗶一聲，直到降速或通過 |
| 方向判斷 | 只提醒取締你這個行車方向的照相點 |
| 區間測速 | 倒數「還要幾秒才能到終點」，顯示均速、建議車速上限；每分鐘報一次，最後 30 秒、10 秒再各報一次，歸零時提醒 |
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

本機測試：

```bash
# 核心邏輯（需要 Swift 5.9 以上，或用 Docker）
docker run --rm -v "$PWD/Packages/SpeedCamCore":/pkg -w /pkg swift:6.2-noble swift test

# 資料處理
pip install -r data-pipeline/requirements-dev.txt && python3 -m pytest -q data-pipeline
```

## 資料

- 照相點：內政部警政署「測速執法設置點」（政府資料開放平臺，資料集 7320），依[政府資料開放授權條款－第1版](https://data.gov.tw/license)使用。
- 區間測速：從開放資料「設置地點」的文字自動產生（例如「台9線68k+600m至56k+600m」），用公路局「省道里程坐標」（資料集 7040）換算座標；另外有人工維護的 `data-pipeline/manual/sections.csv`（北宜公路）。詳見 [data-pipeline/README.md](data-pipeline/README.md)。
- 你也可以在 `data-pipeline/manual/cameras_extra.csv` 補充照相點。

## 路線圖

- **Phase 2**：加入 Apple Developer Program（US$99／年）→ TestFlight → 申請 CarPlay 導航權限 → CarPlay 上的地圖與全螢幕提醒。
- **Phase 3**：重機停車模式（TDX 停車資料＋重機可停／費率的人工整理與使用者回報）。
