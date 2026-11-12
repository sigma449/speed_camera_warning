# 多來源回退快照與授權

這些是 2026-11-12 實際取得、逐欄檢查的公開原始資料，不代表目前仍有設備或正在執法。
`manifest.json` 記錄下載網址、授權及 SHA-256。原檔欄位反置、第二表頭和條件速限保留，
由各來源適配函式處理；不在快照裡偷偷改座標。縮減或失聯一律印出使用舊快照的警告。
原始檔與壓縮檔以 Git binary 屬性保存，避免 Windows／macOS 換行轉換破壞原始位元組及 SHA-256。

- 各編號 `.raw`：`data.gov.tw` 相應資料集，政府資料開放授權條款－第 1 版，
  <https://data.gov.tw/license>；原機關、下載網址和筆數見 manifest。
- `178144.raw`：新竹警方科技執法 HTML 的 **科技表**轉成同欄位 JSON，34 列中只採 3 列含超速功能。
  178144 中繼資料明列相同主題、欄位及開放授權；CSV／JSON 主站本輪 TLS 逾時，**未確認兩版本同步**。
  不含固定／移動表；不能把科技資料集的授權擴及其他表。
- `ntpc-mobile.raw`：新北市警察局「移動式科學儀器執法設備設置地點」公告地點表 HTML（1141126；不含網站介面），
  717 資料列、607 筆不重複地區／地點；官網
  [開放宣告](https://www.traffic.police.ntpc.gov.tw/cp-996-14693-27.html)
  明許重製、改作、編輯與公開傳輸，須標示來源。不是即時取締資訊。
- 新竹移動表授權未核，**沒有收入快照或 App**。
- 聲音照相 173697／156743 分別 9／324 列皆無座標，只保留稽核用原檔，
  建置報告逐筆列為未發布，不能冒充已接入 333 個位置。

## OpenStreetMap（ODbL）

`osm` 原始元素與相應 metadata 出自 © OpenStreetMap 貢獻者，
經 Overpass 分區擷取；南部、金門兩區兩個端點皆失聯，明列使用 Geofabrik 公開臺灣 PBF 擷取的原始
OSM 元素回退（PBF 基準 2026-11-11T21:22:47Z、MD5 已核對），不是 Overpass 成功回應。
出處、時間與查詢條件見 `osm\manifest.json`。
OSM `direction` 記設備面向，不能在缺前／後方拍攝資訊時一律反轉成車行向；
只使用唯一可驗證的 from→to，其他保留原標記並按未知方向提醒，不冒稱已核對同行向。
原始 OSM 資料採 [Open Data Commons Open Database License 1.0](https://opendatacommons.org/licenses/odbl/1-0/)；
署名及授權說明：<https://www.openstreetmap.org/copyright>。

本專案將 OSM 與官方資料去重後的 `cameras.json` **資料庫**視為衍生資料庫，依 ODbL 1.0 提供，
原政府及公告資料仍保留各自的來源／授權。這不改變 App 程式碼或原始官方資料的授權。
建置程式、快照及 manifest 提供重建融合資料庫所需的變更方式；Build IPA 同時提供
`SpeedCam-data` artifact，內含完整機讀 `cameras.json` 與上述來源／程式。
散布 IPA 或另行提供資料下載時，須一併提供這些資料及 ODbL 告知，不能只有圖片或署名。
本輪只在本機提交，尚未發布 IPA 或新增的公開下載檔。
