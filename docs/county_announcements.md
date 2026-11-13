# 22 縣市執法公告對照：第二輪

查閱日：2026-11-13。基準為 `CLAUDE.md` 的 2,809 點／82 區間／153 個新北公告熱點。本檔只整理來源，不修改資料或宣稱已補點。

## 怎麼讀這份表

- **全文**：本輪讀到 HTML／JSON 的完整目標清單；**樣本**：只讀部分資料；**索引**：讀到附件題名、日期、大小，沒有讀清附件本文；**受阻**：原站回 WAF、403、TLS 問題或空殼。
- **承第一輪**：沿用 `docs\data_sources_survey.md` 已查的筆數／欄位，本輪沒有重讀該原檔，不冒充新的全量核對。
- 表內的「列」「方向」「路口」「路段」「套」不是同一單位；未核就是未知，不以附件數或網頁篇數推估設備數。
- 聲音照相多由環保機關公告；警方表沒列出，不代表該縣市沒有聲音設備。
- 「已接」指 repo 已有該來源適配／快照，不保證現行公告每一列都已進入融合後的 2,809 點；「未接」也不等於與 7320／OSM 完全不重疊。

### 授權代碼與原文摘要

| 代碼 | 已實讀的條款／宣告 | 原文要旨與限制 |
| --- | --- | --- |
| G1 | [政府資料開放授權條款第 1 版](https://data.gov.tw/license)；適用於明列此授權的資料集 | 無償、不限目的／時間／地域，可重製、散布、編輯、改作、衍生及再授權；須顯名原提供機關。不是所有政府網站或其所有第三方附件自動套用 |
| W北 | [臺北警方網站宣告](https://td.police.gov.taipei/cp.aspx?n=663DF4636E6DE905)，2025-10-27 | 明列政府 1.0，「無償、非專屬、得由使用者再授權」，不用另取書面同意，須註明出處；特別聲明作品、其他智慧財產權及個資另論 |
| W新北 | [新北交通大隊網站宣告](https://www.traffic.police.ntpc.gov.tw/cp-996-14693-27.html) | 無償、非專屬、可再授權、不限時間地域、可重製改作編輯公開傳輸，須出處，授權不撤回；有特別聲明及第三人權利例外 |
| W中 | [臺中警局網站宣告](https://www.police.taichung.gov.tw/ch/home.jsp?id=69&parentpath=0,9)，2022-12-16 | 明列政府 1.0，可再授權、須出處；特別聲明作品不在一般宣告範圍 |
| W斗六 | [斗六分局自己的宣告](https://ylhpb.yunlin.gov.tw/Douliu/cp.aspx?n=31410) | 「無償、非專屬，得再授權」，不限時間地域，可重製改作編輯公開傳輸、須出處、不撤回；第三人／特別聲明作品例外。不是拿交通隊的宣告推及分局 |
| CC0北環 | [臺北環保稽查大隊宣告](https://epib.dep.gov.taipei/News_Content.aspx?n=6CC4AC3B13A460B7&s=59C050CA5F72346C&sms=A1B9CBA5326E4DA8)，2022-12-19 | 採 CC0-1.0，不主張著作權，可利用製作產品服務，原則無須署名但建議溯源；不涵蓋其他智慧財產權、個資與特別聲明作品 |
| 未核 | 沒有取得該原站／附件適用的完整授權文字 | 僅可列調查線索，不因「政府公告」就宣稱已取得整庫再散布權；資料集另列 G1 時僅適用該資料集 |

## 一覽表

下表涵蓋 22 個縣市的查訪狀態，**不是宣稱各地五種類型都已查完**。實際網址、欄位、日期、授權及涵蓋限制見各縣市紀錄。

| 縣市 | 固定式 | 區間 | 科技執法 | 移動式 | 聲音照相 |
| --- | --- | --- | --- | --- | --- |
| 臺北市 | 130111 已接；9 月新版 PDF 索引 | 與固定 PDF 同頁，本文未解 | 135957 全文 95 列 | 1151110 PDF 索引 | 11509 PDF 索引；6 月新聞確認 28 套 |
| 新北市 | 123740 已接；公告 HTML 樣本 | 126156 方向別表已接 | 164507 已接 | 717 原始列已接部分 | 本輪未取得可用設點表 |
| 基隆市 | 題名 77 處，PDF 未解 | 173070 承第一輪 | 178159／公告索引 | 題名 45 處，PDF 未解 | 未核 |
| 桃園市 | 25935 metadata／CSV 入口 | 未取得新版完整公告 | 178168，115 年 9 月 | 原站受阻，未取得新版 | 噪音專站有成果，未見可用設點表 |
| 新竹縣 | 173211 metadata；PDF 原始碼 | 172950 承第一輪 | 功能混在固定表 | 未取得可用清單 | 未核 |
| 新竹市 | HTML 59 列 | 未取得完整雙端表 | HTML 34 列，3 個超速已接 | 全文 73 方向／72 組座標，權利待核 | 2022 新聞三條道路，非精確桿位 |
| 苗栗縣 | 172174 metadata，原站受阻 | 178412 承第一輪、欄位錯位 | 172178 metadata | 未取得可用新版 | 未核 |
| 臺中市 | 11510 PDF；83881 已接 | 本輪未核完整雙端表 | 11510 兩種科技 PDF | 11510 PDF；舊機讀 386 列 | 本輪未取得可用設點表 |
| 彰化縣 | 27969 已接，現檔樣本 | 178161 承第一輪、僅單點 | 172905 已接 | 九個附件索引，不是九個點 | 173697 固定聲音 9 列，無座標 |
| 南投縣 | HTML 第一頁 10 列；38357 已接 | 171261 承第一輪、端點不足 | 176021 兩列禁駛項目 | 埔里題名線索，正文未取得 | 未核 |
| 雲林縣 | 178358 已接 | 本輪未取得完整表 | 178357 已接 | 斗六 26 列全文；斗南／西螺路段 | 未核 |
| 嘉義市 | 52544 已接；原站 WAF | 未核 | 161852 承第一輪、文字地址 | 未取得 | 未核 |
| 嘉義縣 | 178143 metadata；原站 WAF | 未核 | 178140 metadata | 官方轉載承第一輪，未重讀 | 未核 |
| 臺南市 | 53645 承第一輪，文字型 | 未核完整雙端 | 139129 承第一輪 | 新化 115 年公告全文，非全市 | 156743，324 個公告路段列 |
| 高雄市 | 176549，第 4 次資源，標號到 266 | 本輪未核完整雙端表 | 176561，第 4 次 98 行向列 | 169075，113 年 95 有效路段 | 本輪未取得可用設點表 |
| 屏東縣 | 115 年 PDF 索引；146681 承第一輪 | 144579 承第一輪、舊版 | 原站科技入口；159972 承第一輪 | 795.20 KB PDF 索引 | 未核 |
| 宜蘭縣 | 縣府平臺 76 列樣本；三星新版 PDF | 未核完整雙端 | 固定表含功能，未獨立核全表 | 未取得新版 | 未核 |
| 花蓮縣 | 11503 PDF 索引 | 171349 附件入口 | 同 PDF／位置圖，未解本文 | 未取得 | 未核 |
| 臺東縣 | 原站 403；179007 1151102 CSV 入口 | 172801 承第一輪 | 179008 PDF 承第一輪 | 未取得 | 未核 |
| 澎湖縣 | HTML 樣本；156415 已接 | 未核 | 172940 已接；2027 才生效公告另存 | 未取得 | 未核 |
| 金門縣 | 178119 已接；原站僅頁尾 | 178120 承第一輪、僅單點 | 178121 承第一輪、非測速 | 未取得 | 未核 |
| 連江縣 | 新北官方轉載 2024 公告 PDF | 未核 | 未核 | 未取得 | 未核 |

## 各縣市來源紀錄

### 1. 臺北市

- **固定／區間公告**：[交通大隊原頁](https://td.police.gov.taipei/cp.aspx?n=933486F3A3C42C57&s=76F2F2844D29A710)。本輪讀原始 HTML，資料更新 **2026-09-09 12:46**；設點清單 PDF 91.66 KB、公告 PDF 171.91 KB。已開 PDF，但只取得原始碼，**列數、座標、方向、速限及三個漏點是否列入均未核**。這比 130111 的 3 月版本新，不能說兩者相同。
- **現行機讀固定表**：[130111 官方 JSON 樣本](https://data.taipei/api/v1/dataset/5012e8ba-5ace-4821-8482-ee07c147fd0a?scope=resourceAquire&limit=5)，`count=143`、匯入 2026-03-10；欄位有地點、功能、方向、速限及經緯度，包含純闖紅燈，**不是 143 個測速點**。來源已接；本輪與快照抽五列比對，詳主報告。
- **科技**：[135957 metadata](https://data.gov.tw/api/v2/rest/dataset/135957)／[原平臺](https://data.taipei/dataset/detail?id=986fa73e-c470-4ebf-9f35-3a1c9d2a8788)／[分頁 JSON](https://data.taipei/api/v1/dataset/4715904f-6ce1-41c2-8a68-3bc5303f3607?scope=resourceAquire&limit=15&offset=0)。**95 列全部分頁實讀**，CSV 15.86 KB、檔案更新 2026-08-21，coverage 至 08-19，metadata 10-13。有種類、取締項目、路段、經緯度、啟用日期／備註，**沒有獨立方向和速限欄**。扣除 16 列純停車、2 列已知區間後，最多 77 列一般科技提醒候選；不是 77 個淨新增測速點。此 source 未接，但全庫可能已有同址設備。G1。
- **移動**：[原頁](https://td.police.gov.taipei/cp.aspx?n=B9ECC8F49C36FDEC)，題名 **1151110**、資料更新 **2026-11-10 16:09**，PDF 207.81 KB。已開附件但未解本文，筆數及欄位未知；不沿用第一輪舊版筆數。
- **聲音**：[環保稽查大隊 11509 清單](https://epib.dep.gov.taipei/News_Content.aspx?n=CA7A7FD471F55FED&sms=9E4D334B8FECFA64&s=AF64DE325C7D41EB)，頁更新 **2026-09-02 11:09**，PDF 75.11 KB、1 頁；已開但未解本文。[2026-06-29 新聞](https://epib.dep.gov.taipei/News_Content.aspx?n=408C712E96A4EDF5&sms=1C03AF8610A7031E&s=C427A2B540592697)原文確認 **28 套固定式**，不是已逐點讀到 28 列。最新表的座標／地址／方向仍未知。CC0北環。
- 警方網站附件原則依 **W北**，不是把環保的 CC0 套過來。三個實測漏點的結論見主報告，沒有因找到新版 PDF 就宣稱已找到設備。

### 2. 新北市

- **移動公告**：[原頁](https://www.traffic.police.ntpc.gov.tw/cp-3313-97704-27.html)，題名 1141126、發布 2025-11-26，HTML「地區／地點」。既有建置讀到 **717 原始列、607 唯一行政區／地址；290 可定位列、230 唯一地址、淨新增 153 點**。其餘 427 列／377 唯一候選不是 427 支固定相機。W新北。
- **固定公告**：[1130605 HTML](https://www.traffic.police.ntpc.gov.tw/fp-3313-116235-27.html)，發布 2024-06-11。本輪讀到新店區段，欄位主要為地點／取締功能，無原生座標及獨立速限欄，混有純紅燈；未全量重算。W新北。
- **機讀資料**：[123740 現行 CSV](https://data.ntpc.gov.tw/api/datasets/99f3ff6e-0352-4399-a726-775ab765a1dc/csv/file)，UTF-8，有行政區、地址、經緯度、方向、速限，repo 快照 173 列；本輪讀現檔樣本。科技 [164507](https://data.gov.tw/dataset/164507) 快照 110 列、區間 [126156](https://data.gov.tw/dataset/126156) 原始 14 方向列，均已接；不是全數新增。資料集 G1，後兩者本輪未再逐列核。
- **新店分區表**：[平臺](https://data.ntpc.gov.tw/datasets/CFF8E05C-7466-46FA-8969-447DCA31F87A)標 12 筆，但[本輪 JSON](https://data.ntpc.gov.tw/api/datasets/cff8e05c-7466-46fa-8969-447dca31f87a/json?page=0&size=20)只有 **11 列 seqno 40～50**，全部已讀。未列銀河三段點；北宜二段 348 號是另一點，不能合併。分區表內容更新日及筆數差異原因未核。
- 聲音清單本輪未取得。門牌與路燈均另有 G1 原生座標，詳 `geocoding_options.md`；**尚未命中指定示例地址／431279 桿號**。

### 3. 基隆市

- [交通隊清單目錄](https://www.klg.gov.tw/cht/index.php?code=list&ids=937)已開。
- [固定公告](https://www.klg.gov.tw/cht/index.php?code=list&flag=detail&ids=937&article_id=3217)題名 **77 處**，列表日期 2025-02-21；PDF 本文未解析。77 是官方題名，不是本輪逐列核數，座標／方向／速限未知。
- [移動公告](https://www.klg.gov.tw/cht/index.php?code=list&flag=detail&ids=937&article_id=4496)題名 **45 處**，原發布 2023-05-30、更新 2026-07-24；[設點 PDF](https://www.klg.gov.tw/cht/index.php?act=download&ids=7468)、[公告 PDF](https://www.klg.gov.tw/cht/index.php?act=download&ids=7467)未解本文。
- 科技 [178159](https://data.gov.tw/dataset/178159)、區間 [173070](https://data.gov.tw/dataset/173070)承第一輪，前者 BIG5、後者 PDF；沒有在本輪確認新版列數／完整雙端。
- G1 只沿用明列授權的資料集；警方原站附件授權未核。聲音未核。

### 4. 桃園市

- [交通大隊原入口](https://traffic.tycg.gov.tw/present/profession/View.aspx?p0=22&openExternalBrowser=1)本輪 TLS 失敗，沒有繞過。
- [25935 metadata](https://data.gov.tw/api/v2/rest/dataset/25935)已讀；固定表版本 2026-07-13、metadata 10-30，G1、BIG5 CSV，欄位設備、地點、功能、經緯度、方向、速限、管轄。[CSV](https://opendata.tycg.gov.tw/api/dataset/ecd45ee5-4489-436b-bd08-7d4e4111c4a4/resource/6aa72aaf-d703-4a9e-acd7-24c17e934dc3/download)，全量筆數未核，尚未接此來源。
- [178168 metadata](https://data.gov.tw/api/v2/rest/dataset/178168)已讀，**115 年 9 月**科技清單、metadata 11-13；[CSV](https://opendata.tycg.gov.tw/api/dataset/46bd8de0-cb90-4149-a530-5f5b1751b450/resource/636bb62e-cc5b-4ad4-ac11-5849ad5c432d/download)，G1；未讀全檔，不報設備數。
- 區間雙端及 115 年移動新版未取得。[環保噪音專站](https://www.noise.tydep.gov.tw/Traffic.aspx?gid=82)讀到稽查成果及法規，沒有可直接採用的設點表。警方原站及噪音頁的個別再利用條款未核，不能由資料集 G1 外推。

### 5. 新竹縣

- [警方公告下載](https://www.hchpb.gov.tw/Tw/Common/SinglePageDownload?filter=76E0CBB1-B674-4AA3-8B85-517D74AC4D8F&siteid=416763f8-a1f7-48fd-bfbf-9327913efad7)已開 PDF，只有原始碼；CreationDate 2023-07-06 不當現行更新日。
- [173211 metadata](https://data.gov.tw/api/v2/rest/dataset/173211)已讀，2026-08-10、G1；[JSON](https://ws.hsinchu.gov.tw/001/Upload/1/opendata/8774/2786/daf2e188-b52f-4c91-87b7-bb13ad7b5bb8.json)欄位含功能、位置、經緯度、方向、速限，總數未在本輪核。舊固定 109336、區間 172950 承第一輪，不宣稱新增。
- 移動、聲音及完整新版區間未取得；原站 PDF 授權未核。

### 6. 新竹市

- [交通隊 HTML](https://tra6.hccp.gov.tw/trafficweb/pages/camera)已讀完整三表：科技 **34 列**、固定 **59 列**、移動 **73 方向列／72 組座標**。欄位有位置、取締項目、經緯度、方向及速限；未核各表獨立更新日。
- 科技含超速三列已透過 178144 適配，**不再列新增三點**；原 CSV／JSON 與 HTML 是否同版仍未核。
- 移動例：竹光路竹光國中、北向、50，`120.954317,24.808516`。有座標不代表可立即發布：頁尾有未經同意禁止轉載文字，[市府授權頁](https://www.hccg.gov.tw/ch/home.jsp?id=10051&parentpath=0,19)本輪 403，**移動表授權仍未確認**；不能套用科技資料集的 G1。
- [環保局 2022-12-05 新聞](https://www.hccepb.gov.tw/news-detail.php?Nid=2895)原文提光復路二段、竹光路、中華路五段三套歷史聲音設備，沒有精確桿位／座標，現行性及網站再利用條款未核。區間完整雙端未取得。

### 7. 苗栗縣

- [原公告入口](https://www.mpb.gov.tw/latestevent/index?Parser=9,7,760) TLS 失敗。
- [172174 固定 metadata](https://data.gov.tw/api/v2/rest/dataset/172174)、[172178 科技 metadata](https://data.gov.tw/api/v2/rest/dataset/172178)已讀，均 G1、metadata 2026-08-24。[固定 CSV](https://webws.miaoli.gov.tw/Download.ashx?u=LzAwMS9VcGxvYWQvb3BlbmRhdGEvMTcxNC8yZDhiMzg3Ny1hNjE5LTQwMWYtYjRjYi1lMzExMmQ4ODZmNWYuY3N2)、[科技 CSV](https://webws.miaoli.gov.tw/Download.ashx?u=LzAwMS9VcGxvYWQvb3BlbmRhdGEvMTcxNS83MjlmODcxOC0xNGVkLTQ5NmQtOTMzZS1jOTRmZmZkZjNmYzYuY3N2)。
- metadata 宣稱 UTF-8，第一輪原檔卻是 BIG5 且有未登錄座標欄；須先核編碼、表頭及方向／速限，不報本輪有效列數。未接上述來源。
- 區間 178412 承第一輪為 14 列且欄位錯位，不能直接當 14 個完整區間。移動及聲音未取得；原站附件授權未核。

### 8. 臺中市

- [警方完整公告索引](https://www.police.taichung.gov.tw/traffic/home.jsp?id=55&parentpath=null&mcustomize=multimessages_view.jsp&dataserno=202207040001&t=Download&mserno=201801260055)已讀：公告 2026-10-12、頁更新 10-15，附公告、固定、科技、路口科技、移動 **五份 PDF**，不是五個設備。
- [固定 PDF](https://www.police.taichung.gov.tw/filedownload?file=downlod/202610151035060.pdf&flag=doc)、[科技 PDF](https://www.police.taichung.gov.tw/filedownload?file=downlod/202610151024092.pdf&flag=doc)、[路口科技 PDF](https://www.police.taichung.gov.tw/filedownload?file=downlod/202610151025380.pdf&flag=doc)、[移動 PDF](https://www.police.taichung.gov.tw/filedownload?file=downlod/202610151025381.pdf&flag=doc)。本文未解析，列數及原生座標／方向／速限未知。W中。
- 固定 83881 快照 **224 原始列**已接；科技 170673 承第一輪有錯值、未接；舊移動 170672 承第一輪 **386 文字列、無座標**，不能當新版 PDF 的筆數。
- 區間雙端及環保聲音設點表本輪未核清，不把環境噪音監測資料當聲音執法相機。

### 9. 彰化縣

- [警方移動附件索引](https://www.chpb.gov.tw/traffic/FileList/C104100?SubCategoryID=2ff00c5c-5bd6-4cec-89db-940abe34379e)已讀，**九個附件：八 PDF、一張和美 JPG**。北斗 2026-09-16、田中 09-08，其餘 08-28；未解附件本文，地點列數、座標、方向、速限未知。警方網站附件授權未核。
- 固定 [27969 現行 CSV](https://www.chpb.gov.tw/opendata/2XvPDK8t9UC1v65F7FQ4Kw/csv)，UTF-8、地址／功能／方向／速限／座標；快照 **58 列**，本輪前五列與快照相同。科技 [172905](https://data.gov.tw/dataset/172905) 快照 **57 列**；兩來源已接、資料集 G1。區間 178161 承第一輪只提供單點，不造另一端。
- 聲音 [173697 metadata](https://data.gov.tw/api/v2/rest/dataset/173697)已讀，coverage 2025-06-05、metadata 2026-04-15，**9 列固定式聲音照相**、G1、BIG5。[原 CSV](https://www.chepb.gov.tw/opendata/彰化縣固定式聲音照相設置點.csv)本輪也已開，中文亂碼；欄位為序號、測站名、行政區碼、測點編號、測點地址，**無座標、方向、速限**。9 列不能以門牌庫存在就宣稱已定位成功。

### 10. 南投縣

- [警方固定 HTML](https://www.ncpd.gov.tw/Sub/table/index.aspx?Parser=5,30,1147,737)第一頁 **10 列、共四頁**，有地點、分局、備註；備註帶功能／方向／速限，無經緯度。例南崗三路／成功三路 60 南北、華陽路 850 號 60 雙向、139 線 35.95K 50 雙向。沒有讀完四頁，不推算總數為 40；頁尾 2026-11-13 不是列更新日。
- 38357 承第一輪 **36 列、其中 28 測速**，已接、G1。171261 區間兩方向共一位置，端點不足；176021 科技兩列為砂石車禁駛，不當超速；後兩者承第一輪。
- [埔里移動頁](https://www.ncpd.gov.tw/sub/latestevent/Details.aspx?Parser=9,23,959,305,332,,4404)只讀到頁尾；搜尋題名的 28 處沒有由正文確認，不報為已核資料。聲音及原站再利用條款未核。

### 11. 雲林縣

- [交通隊入口](https://ylhpb.yunlin.gov.tw/Traffic/)簡化內容只到頁尾；固定 178358 快照 **97 列**、科技 178357 **23 列**已接，資料集 G1。
- [斗六 115 年移動清單](https://ylhpb.yunlin.gov.tw/Douliu/News_Content.aspx?n=31362&s=577863) **26 列全文已讀**。有門牌、路口、里程、部分方向與速限，無座標；例如石榴路 104 號前往林內 50、雲科路三段 55 號西往東快車道 60／慢車道 40。石榴路 104、保長路 155、臺 1 的 234.5K 重複出現，另有整路／長路段，**26 不是淨新增設備數**。年度為 115，未核獨立發布日；頁尾更新日不代替公告日。已另讀分局自己的 W斗六。
- [斗南](https://ylhpb.yunlin.gov.tw/Dounan/News_Content.aspx?n=31416&sms=22514&s=560827)：1151001，頁上版 2026-10-01、下版 12-31，15 個道路名稱，無確定點，不取路段中心。**下版時間不自動等於各熱點停止執法**。
- [西螺](https://ylhpb.yunlin.gov.tw/Xiluo/News_Content.aspx?n=31525&s=585056)：1150320、七個路段，無座標。上述兩分局的個別授權未另核；[交通隊宣告](https://ylhpb.yunlin.gov.tw/Traffic/cp.aspx?n=31253)雖允再授權與署名，不能未查就延伸至所有分局子站。
- 全縣區間及聲音未查完。

### 12. 嘉義市

- [警方原入口](https://www.ccpb.gov.tw/content/?parent_id=10081)本輪 WAF，未繞過。
- 固定 [52544](https://data.gov.tw/dataset/52544) 快照 **11 列**已接，資料集 G1。
- 科技 [161852](https://data.gov.tw/dataset/161852)承第一輪為 **19 個文字地址列**、未接，無可直接使用的座標；沒有本輪逐列核日期／方向／速限。
- 移動、區間、聲音及原站附件授權未核。

### 13. 嘉義縣

- [警方原頁](https://www.cypd.gov.tw/Tpb/Article/f1083665-fdb4-9c58-1344-5cfd7502e553) WAF。
- [178143 固定 metadata](https://data.gov.tw/api/v2/rest/dataset/178143)、[178140 科技 metadata](https://data.gov.tw/api/v2/rest/dataset/178140)本輪已讀，均 G1、metadata **2026-11-11**；品檢未過，標頭拆分錯誤，必須核原檔而非直接信 resourceField。
- [固定 CSV](https://ws-tm.cyhg.gov.tw/001/Upload/1330/relfile/13620/248277/0b69bd7a-6eaf-45c0-a181-5cc0ddd04ea7.csv)、[科技 CSV](https://ws-tm.cyhg.gov.tw/001/Upload/1330/relfile/13620/256051/b66743e4-ca79-4ae3-a14f-6a2a42b1b103.csv)。第一輪固定 15 列，不保證本輪同數；現行有效列數、完整方向／速限未核，未接。
- [新北官方轉載移動公告](https://www.traffic.police.ntpc.gov.tw/cp-1084-134312-27.html)承第一輪 1141223，本輪未重讀本文。原嘉義網站附件授權、區間及聲音未核。

### 14. 臺南市

- [警方固定入口](https://www.tnpd.gov.tw/Article/71d16651-5929-91c8-8a06-039fc3dbee6c)本輪僅導覽／題名；53645 固定、139129 科技承第一輪，多為無座標文字列，未接，不能宣稱完整數量。
- [新化分局 115 年移動公告](https://www.tnpd.gov.tw/News/Details/bafad69b-e148-8f52-9ef9-3d6a071be410/4/73183)全文已讀；總表與勤務表並存，不是全市清單。有臺 19 甲 41.2K、臺 20 17.1K、中正路 61 號、178 甲 1.5／4.75K 等；勤務表另有中正路 1160 號、4.7K 等，需人工確認版本／地點差異。無經緯度及獨立速限，排班重複不可計成新設備；刊載日及分局網站授權未核。
- [156743 metadata](https://data.gov.tw/api/v2/rest/dataset/156743)／[原頁](https://data.tainan.gov.tw/DataSet/Detail/f6bbda7b-8c4e-42ec-8959-57fa294c88a1)／[JSON](https://soa.tainan.gov.tw/Api/Service/Get/aee8d509-ede0-40b2-b66f-3dc312bd05f2)：**「常有聲音照相設備設置地點」324 快照列**，metadata 2026-04-21、不定期、G1。有行政區、代碼、路段描述，無座標／方向／速限；不能當 324 套固定設備。原始欄位還有地址誤放於「行政區域代碼」的情況。
- 完整區間雙端未核。

### 15. 高雄市

- [警方固定 HTML](https://kcpd.kcg.gov.tw/cp.aspx?n=693052840FE00C08)本輪讀前 42 列；有地點、功能、方向、速限，官方提供的地圖連結帶經緯度。只讀連結文字，未擷取商業地圖點庫。含純紅燈／違左，不能全當測速；未核全表更新日及網站授權。
- [176549 metadata](https://data.gov.tw/api/v2/rest/dataset/176549) G1、2026-10-29。題名仍寫第 1 次，但資源尾端有 **115 年第 4 次**：[JSON](https://openapi.kcg.gov.tw/Api/Service/Get/c5e78ac2-b06d-472f-9eb1-0f1df2b891cf)、[CSV](https://data.kcg.gov.tw/File/DirectDownload/c5e78ac2-b06d-472f-9eb1-0f1df2b891cf)。
- 本輪已讀 JSON 首尾：內容標 **115/10/21 更新**；`Seq=1` 是日期、`Seq=2` 是表頭，末筆設備編號 **266** 對應 `Seq=268`，後面還有 `Seq=269～283` 空列。故 **API 物件數、metadata 的 266、有效設備列不能不經清理就混用**。有地址、測照方向、速限／條件、功能、緯經度；測速子集尚未逐列統計。例明誠一路 280 號前，東向西 50，`22.6596,120.325981`。
- [176561 metadata](https://data.gov.tw/api/v2/rest/dataset/176561) G1、2026-10-29；最新第 4 次[路口科技 JSON](https://openapi.kcg.gov.tw/Api/Service/Get/406808f2-42a1-49c2-90f1-bca21920a863)標號 **1～98 行向列**，不是第一個舊附件的 91。已讀首尾樣本；欄位行向編號、位置、項目、行向、緯經度、備註，無獨立速限。中山四路／平和東路第 18 列明列有超速功能，`22.570253,120.33743`，但不能替它補速限。另有「南向西」轉向／人行道等行向，不能全部壓成一般道路方位。
- 其他科技子類 176555／176558／176560／176551／177827／176559 承第一輪，未把不同批次或同址子表相加。尚未接上述來源；與 7320／OSM 的淨差異未知。
- [169075 metadata](https://data.gov.tw/api/v2/rest/dataset/169075)仍為 **113 年移動式**，metadata 2025-09-15；[JSON](https://openapi.kcg.gov.tw/Api/Service/Get/6926114c-42b4-486a-944d-cabb974c1de5)快照 182 列、第一輪清理 95 有效路段，無座標，G1。metadata 的 resourceAmount=10 不是已核全檔筆數；現行性未確認。區間雙端、環保聲音設點表未查完。

### 16. 屏東縣

- [移動公告索引](https://www.pthg.gov.tw/policetraffic/cp.aspx?n=AF7270DA750D43DC&s=C27BE411363C14C1)已讀，[附件 PDF 795.20 KB](https://www-ws.pthg.gov.tw/Upload/2015pthg/230/relfile/20949/50773/d9043267-6e4f-4931-9b80-39e605020f17.pdf)本文未解，列數及欄位未知。
- 同目錄可見[固定 115 年](https://www.pthg.gov.tw/policetraffic/cp.aspx?n=AF7270DA750D43DC&s=7D42B28059F45291)、[固定地圖](https://www.pthg.gov.tw/policetraffic/cp.aspx?n=AF7270DA750D43DC&s=C4FB9E3EF752165C)、[科技](https://www.pthg.gov.tw/policetraffic/cp.aspx?n=AF7270DA750D43DC&s=369D8B977AC98C50)；只確認索引，不冒稱附件全文。公告獨立更新日與網站授權未核。
- 146681 固定 36 列、159972 科技缺功能欄、144579 區間六方向且 2021 舊版，均承第一輪，沒有本輪完整比較。聲音未核。

### 17. 宜蘭縣

- 舊警局網址失效；[三星分局原公告](https://ilcpbss.e-land.gov.tw/cp.aspx?n=7117)已讀，更新 **2026-07-06**，有固定公告／清單 PDF，未解本文，不把分局頁當全縣已逐點核完。
- [縣府原資料頁](https://opendata.e-land.gov.tw/dataset/119017-2026-07-22-1784701530)已讀，G1、免費、UTF-8、平臺列 **76 筆**、頁日期 2026-10-13。[JSON](https://opendata.e-land.gov.tw/dataset/f96c8f5c-b518-40b7-9569-a32684667f74/resource/0764f7b0-c639-4663-8607-8333b5ba493f/download/119017-2026-07-22-1784701530.json)可達，回應較大，只讀預覽。
- 已知有設備／功能／位置／經緯度，獨立方向與速限未完整核；未接。警方 PDF 授權、移動、區間雙端及聲音未核。

### 18. 花蓮縣

- [警方原公告](https://www.hlpb.gov.tw/contents/80?node=49&trans=1)已讀，列出比 177297 的 114 年版本新的 **11503 清單**：[PDF](https://www.hlpb.gov.tw/storage/6323/69ce0f32cb7b6_花蓮縣警察局-115年度測速照相、闖紅燈照相固定桿及科技執法設置地點一覽表11503.pdf)，另有[科技位置 JPG](https://www.hlpb.gov.tw/storage/6894/6af3369d73428_花蓮縣科技執法設備建置路段位置圖.jpg)。
- 本文／圖像未解析，數量、原生座標、方向及速限未知；11503 是附件版次，不自填獨立更新日。網站再利用條款未核。
- [171349 區間資料原頁](https://csa.hl.gov.tw/opendata/News_Content.aspx?n=26003&s=167476)有 ODS／XLSX／PDF，承第一輪，未讀清最新雙端；移動、聲音未取得。

### 19. 臺東縣

- [警方原頁](https://www.ttcpb.gov.tw/chinese/home.jsp?serno=201105170134) 403。
- [179007 metadata](https://data.gov.tw/api/v2/rest/dataset/179007)本輪已讀，G1、題名 **1151102 啟用**；published 2026-11-02 但 modified 10-31，保留差異，不強解為先後錯誤。
- 三個 CSV 入口：[一](https://ttone.taitung.gov.tw/download?id=1njns06QXNg7c4Dq%2F%2F9aYA%3D%3D)、[二](https://ttone.taitung.gov.tw/download?id=Rm4wfP%2FjkMwGPGfjlOnP9A%3D%3D)、[三](https://ttone.taitung.gov.tw/download?id=78tcyqhlgPCBkZ4mn6c5Zw%3D%3D)。本輪未讀原檔，不報數量／座標／方向／速限。
- 科技 179008 PDF、區間 172801 承第一輪；尚未核最新內容。移動、聲音及原站附件授權未核。

### 20. 澎湖縣

- [交通隊原 HTML](https://www.phpb.gov.tw/Traffic/home.jsp?id=101)本輪讀前 15 列，並非全表只有 15；有地址、測照方向、速限、器材與備註，無原生座標。內容更新日、網站附件授權未核。
- 固定 156415 快照 **33 列**、科技 172940 **4 列**已接，資料集 G1；不能再報新增 37 點。
- [新北警方轉載修正公告](https://www.sanchong.police.ntpc.gov.tw/dl-43899-6d549a76-39e4-4d84-b5d7-d8ecdfd06148.html)承第一輪：2026-10-01 修正、**2027-01-01 才執法**；原文未在本輪重讀，不提前當現役缺點。
- 區間、移動及聲音未取得完整表。

### 21. 金門縣

- [警方原頁](https://kpb.kinmen.gov.tw/cp.aspx?n=253754F275EEBE90)本輪只取得頁尾，沒有把全站更新日當設備更新日。
- 固定 178119 快照 **35 列**已接，G1；區間 178120 兩列僅單點、科技 178121 十二列非測速，均承第一輪，未當新的完整區間或測速庫。
- 移動、聲音、新版完整公告及原站附件授權未核。

### 22. 連江縣

- 本輪實開的是[新北交通大隊官方轉載](https://www.traffic.police.ntpc.gov.tw/cp-1084-119584-27.html)，不是連江原站；新北發布 2024-09-09，原連江公告 2024-08-21。
- [PDF 附件](https://www.traffic.police.ntpc.gov.tw/dl-33934-d2578c24-0d05-4b7d-b7f2-9bb9fd832e3e.html)本文未解，筆數、座標、方向／速限未知；轉載站有 W新北，原附件的權利範圍仍應核原文，不自動認定第三方附件均可再授權。
- [馬祖日報 2026-02-06](https://www.matsu-news.gov.tw/news/article/238688)是汰舊／會勘線索，不拿會勘當啟用；未取得現行完整固定清單。區間、科技、移動、聲音未核。

## 本檔未完成的範圍

- 多地只取得 PDF／ODS／XLSX／圖片索引或原始碼；沒有在本輪解析、OCR、重算設備數，也沒有執行任何指令。
- 為補讀PDF而嘗試瀏覽器閱讀，未獲桌面操作授權，沒有開啟內容，也沒有重試或改用其他App繞過。
- 桃園、苗栗、新竹市部分資源 TLS／403；嘉義市縣 WAF；臺東 403；部分舊網址失效或只回介面殼，均沒有繞過。
- 除上列明示授權外，其他原站附件、分局子站及各環保局宣告尚未逐一核清；沒有用一個網站宣告套全臺。
- 聲音照相只核實臺北、彰化、臺南、新竹市與桃園的上述層次，**不是已查遍 22 縣市環保機關**。
- 這份對照未確認並核對完整現行2,809融合檔，不能據「source 未接」就計算全縣 App 漏收率；本機舊版／待核版本及三縣市小樣本的限制另見主報告。
