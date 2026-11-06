# data-pipeline：測速資料處理

把政府開放資料整理成 App 內建的 `SpeedCam/Resources/cameras.json`。只用 Python 標準函式庫。

```bash
python3 build_cameras.py                 # 從政府資料開放平臺下載（資料集 7320）
python3 build_cameras.py --input raw.csv # 使用本機檔案（CSV 或 JSON，可重複指定）
python3 build_cameras.py --min-count 500 # 少於 500 筆就視為失敗
python3 -m pytest -q                     # 測試
```

## 處理內容

- **欄位對應**：同時支援全國版英文欄位（CityName、Address、Longitude、Latitude、direct、limit…）與縣市版中文欄位（設置地點、座標經度、拍攝方向、速限…）。
- **編碼**：UTF-8（含 BOM）與 Big5／cp950。
- **座標**：經緯度填反會自動對調；只保留台灣本島、澎湖、金門、馬祖範圍內的點。
- **方向**：「北向南」「南下」「往東」「西向」等文字 → 行車方位角；雙向或無法判斷 → 不設方向（App 改用「照相點在前方」判斷）。
- **速限**：有多個數字時（例如「大型車60/小型車70」）取較小值。
- **類型**：依取締項目／地址判斷固定測速、闖紅燈、測速兼闖紅燈、區間、科技執法。
- **去重複**：約 11 m 內、同方向視為同一支；ID 由位置與方向產生，資料順序改變也不會變。
- **沒有變動就不改檔**：避免每週自動更新只因日期不同就開 PR。

## 自動產生區間測速（從文字）

開放資料把區間寫在「設置地點」欄位，例如「台9線68k+600m至56k+600m」「台3線103.2公里至108公里及台3線114.3公里至123.6公里」
「臺21線53.8K至51.1K(北向)/臺21線51.1K至53.9K(南向)」「台三線31.8k至30.5k」。`speedcam_data/section_text.py` 會：

- 解析道路（含中文數字路名、支線）、公里＋公尺／公里寫法、一筆多段（及、/、；）、後段省略路名
- 依「雙向」或單一方向（北向、東往西、北上…）決定產生一個或兩個方向；單向時用寫的方向校正起訖順序
- 用里程牌資料換算座標與進入方向；離開放資料的照相點超過 3 km 就視為解析錯誤並略過
- 跳過人工資料已定義的範圍；縣道、市道、只寫隧道或路口名稱的區間會略過並列在 log

`manual/sections_text.csv` 收錄開放資料沒有、但立法院附件清單（2026-05）有的區間，只用來產生區間。

## 人工維護的檔案

- `manual/sections.csv`：區間測速。起終點可以填座標，或直接填省道里程（例如 `台9`、`19`、`23.1`）：
  程式會下載公路局「省道里程坐標(里程牌標誌)」（資料集 7040）換算座標，長度用里程差計算，
  並用起點附近 100 m 的里程牌算出進入方向（山路彎曲時比起終點直線方向準確）。
  `bidirectional=yes` 會產生兩個方向的區間。換算結果會印在 log，確認後可以把座標填回 CSV。
  只有座標、沒有官方長度時會先估算，App 再用 Apple 地圖的道路距離修正，並在畫面標示「長度為估算」。
  目前收錄：北宜公路（台9線）19K–23.1K、26.2K–32.2K、33.3K–37.2K、56.6K–68.6K，表定速限 40，雙向。
- `manual/cameras_extra.csv`：補充的照相點，欄位同縣市版原始資料。

## 國道和白牌限制道路的線形

`build_road_lines.py` 從 OpenStreetMap（Overpass API）下載道路線形，產生 `SpeedCam/Resources/road_lines.json`，App 用來判斷路線有沒有走國道。
國道很少變動，所以結果直接放進 repo，不會在建置時下載；有新路段通車時再手動重跑：

```bash
python3 build_road_lines.py
```

- **國道**：OSM 的 `highway=motorway` 而且編號（`ref`）是 1、2、2甲、3、3甲、4、5、6、8、10。只取主線，不取匝道：快速道路常和國道共用交流道，算進去會誤判。
- **白牌限制道路**：`manual/white_plate_restricted.csv` 列的道路。只放 Apple 不算 highway、但不是平面道路的高架和快速道路（Apple 算 highway 的，避開高速時就不會走）。
  要確認某條路 Apple 算不算 highway，用「路線實測」的 compare 模式沿著那條路規劃（`scripts/ci/route-probe-elevated.json`）。

## 授權

- 內政部警政署「測速執法設置點」，依[政府資料開放授權條款－第1版](https://data.gov.tw/license)使用，App 設定頁會顯示出處。
- 道路線形：© OpenStreetMap 貢獻者，依 [ODbL](https://www.openstreetmap.org/copyright) 使用。`road_lines.json` 是衍生資料，同樣適用 ODbL，App 設定頁會顯示出處。
