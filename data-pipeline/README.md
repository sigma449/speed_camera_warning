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

## 人工維護的檔案

- `manual/sections.csv`：區間測速（起終點座標、官方長度、速限）。長度留空時會先估算，App 再用 Apple 地圖的道路距離修正，並在畫面標示「長度為估算」。
- `manual/cameras_extra.csv`：補充的照相點，欄位同縣市版原始資料。

## 授權

內政部警政署「測速執法設置點」，依[政府資料開放授權條款－第1版](https://data.gov.tw/license)使用，App 設定頁會顯示出處。
