# 官方設備異動公告監看：入口調查與用法（H8）

調查／實跑：2026-11-16；日期窗口為 **2025-11-16～2026-11-16**。
這是公開官網的**待人工核對索引**，不是新設備資料庫，更不自動增修照相點。
首份結果見 [announcements_pending.md](announcements_pending.md)。

## 調查結果與入口

設定涵蓋 **16 組機關來源、21 個列表 URL**。最後一次實跑共60次程式請求：
15組／20個列表可讀，桃園1組／1個列表逾時。成功讀取不代表完整涵蓋一年，
也不保證官網下一週仍可用。完整網址、解析器、授權說明均在
`data-pipeline\announcement_sources.json`，不需要修改程式即可調整。

下表「可讀」表示 Python 標準函式庫實際收到並解析列表，不是只測首頁 HTTP 200。
G1指網站明列「政府資料開放授權條款第1版」；「再利用宣告」不自行等同G1。
所有宣告均保留第三人、特別聲明作品及附件的例外；只列標題、日期、連結與事實性位置片段，不重刊全文／照片。

| 入口／設定ID | 列表URL | 格式與查詢方式 | 本輪結果／再利用依據 |
|---|---|---|---|
| 警政署各警察機關新聞發布 `npa` | [新聞發布](https://www.npa.gov.tw/ch/app/news/list?module=news&id=2139) | HTML `li`；GET `keyword`、`pageSize=100`；分頁 `page` 從0開始 | 可讀。[G1宣告](https://www.npa.gov.tw/ch/app/artwebsite/view?module=artwebsite&id=895&serno=1057af14-0d7d-464c-836a-0856d014cc9a)，須署名 |
| 國道公路警察局 `highway` | [最新消息](https://www.hpb.npa.gov.tw/ch/app/news/list?module=news&id=2589) | 同警政署CMS；無資料時為空 `.list_group > .list` | 可讀；查得測速／照相文章都是2019～2020舊文。[再利用宣告](https://www.hpb.npa.gov.tw/ch/app/artwebsite/view?module=artwebsite&id=1626&serno=b6573a28-8f45-4240-a103-6ae7f0b6d2d1)：無償、非專屬、可再授權及署名 |
| 臺北市警局 `taipei` | [新聞稿](https://police.gov.taipei/News.aspx?n=0B762199E50C4AB2&sms=72544237BBE4C5F6) | ASP.NET `tr`；先GET原站 `form1`，再POST `_field_0` 與隱藏欄位 | 可讀；[總局舊宣告網址](https://police.gov.taipei/ct.asp?xItem=3580330&ctNode=45108&mp=108001)仍需留意重新導向，不能以交通大隊已核G1替總局所有內容背書 |
| 臺北交通大隊 `taipei-traffic` | [新聞稿](https://td.police.gov.taipei/News.aspx?n=B19CFD7B4346611D&sms=72544237BBE4C5F6) | 同上；共用 `s` 文章ID；列表保留原發布機關 | 可讀。[G1宣告](https://td.police.gov.taipei/cp.aspx?n=663DF4636E6DE905)，須署名 |
| 士林分局 `shilin` | [新聞稿](https://sl.police.gov.taipei/News.aspx?n=DFCA74AF8B331102&sms=72544237BBE4C5F6) | 同臺北正常POST搜尋；不是只加GET查詢字串 | 可讀。[分局再利用宣告](https://sl.police.gov.taipei/News_Content.aspx?n=BE3592E911315926&sms=B64E1E4E3A6BD0D3&s=8C1720C18F3E7BD8)：無償、非專屬、再授權、署名 |
| 士林分局 `shilin` | [最新消息](https://sl.police.gov.taipei/News.aspx?n=E4D4910E69FECF79&sms=78D644F2755ACCAA) | 同上；會混入其他局處公告 | 可讀；同分局宣告 |
| 新北交通大隊 `ntpc-traffic` | [警政新聞](https://www.traffic.police.ntpc.gov.tw/lp-909-27.html) | HTML `li`，`cp-分類-文章-27.html`；讀列表，不猜未驗證的分頁URL | 可讀。[再利用宣告](https://www.traffic.police.ntpc.gov.tw/cp-996-14693-27.html)：無償、非專屬、再授權、署名 |
| 新北交通大隊 `ntpc-traffic` | [公告事項](https://www.traffic.police.ntpc.gov.tw/lp-1084-27.html) | 同上 | 可讀；同大隊宣告，轉載另核原權利 |
| 新北交通大隊 `ntpc-traffic` | [科技執法清單與公告](https://www.traffic.police.ntpc.gov.tw/lp-3313-27.html) | 同上；整表版本更新沒有異動關鍵字不入待核 | 可讀；同大隊宣告；附件未下載 |
| 新店分局 `xindian` | [最新消息](https://www.xindian.police.ntpc.gov.tw/lp-168-16.html) | 新北CMS `li`；列表共9則，回溯至2023年 | 可讀。[分局再利用宣告](https://www.xindian.police.ntpc.gov.tw/cp-980-14693-16.html)：無償、非專屬、再授權、署名 |
| 桃園市警局 `taoyuan` | [公告入口](https://www.typd.gov.tw/index.php?catid=29) | 首頁／入口均逾時，**格式未核**；設定內解析器僅為待驗占位，不宣稱適配成功 | **不可抓：逾時**；沒有繞過阻擋，網站再利用授權未核 |
| 臺中市警局 `taichung` | [警政新聞](https://www.police.taichung.gov.tw/ch/home.jsp?id=10&parentpath=0,1) | HTML `li`；GET `keyword`、`pagesize`；`dataserno`文章ID | 可讀。[G1宣告](https://www.police.taichung.gov.tw/ch/home.jsp?id=69&parentpath=0,9)，須署名 |
| 臺南市警局 `tainan` | [最新消息](https://www.tnpd.gov.tw/News/a71f1b44-1f96-8a48-caa5-fe08e13047ee/1) | HTML `tr`、`/News/Details/`；正常下一頁連結，最多6頁 | 可讀，本輪6次讀至2021年。[再利用宣告](https://www.tnpd.gov.tw/Article/412894e9-5b63-bbd5-29ef-a93a549cb0bb)：無償、非專屬、再授權、署名 |
| 臺南交通大隊 `tainan-traffic` | [公告](https://www.tnpd.gov.tw/traffic/News/Index/cac900f8-8588-ac3f-a408-7c928310cb0c?sClass=1) | 同臺南表格；本輪5則 | 可讀；頁尾連回同一市警局再利用宣告 |
| 高雄市警局 `kaohsiung` | [新官網新聞](https://kcpd.kcg.gov.tw/News.aspx?n=301858D950E8FB8E&sms=FC374298B757EFB3&PageSize=200) | HTML `tr`、`News_Content.aspx`；200筆／頁 | 可讀；先前12秒逾時，改設定20秒後成功。[G1宣告](https://kcpd.kcg.gov.tw/cp.aspx?n=3E7457DB80D492BC) |
| 高雄交通大隊 `kaohsiung-traffic` | [新官網公告](https://kcpd-tpc.kcg.gov.tw/News.aspx?n=241A1D9AB49C3E9E&sms=254AA0F1C0476E9E&PageSize=200) | 同高雄；本輪只有1則 | 可讀；20秒逾時設定。[再利用宣告](https://kcpd-tpc.kcg.gov.tw/Content_List.aspx?n=68582E452223D639)誤植國發會名稱，適用範圍存疑 |
| 基隆市警局 `keelung` | [最新消息](https://www.klg.gov.tw/cht/index.php?code=list&ids=21) | HTML `.card`；GET `keyword`；`article_id`文章ID | 可讀；只找到[隱私政策](https://www.klg.gov.tw/cht/index.php?code=list&ids=340)，未核到明確再利用授權，只摘事實索引 |
| 基隆市警局 `keelung` | [交通訊息](https://www.klg.gov.tw/cht/index.php?code=list&ids=22) | HTML `tr`，與最新消息不同；`href="#"`的下一頁是停用，不重抓同頁 | 可讀；同上授權未核 |
| 宜蘭縣警局 `yilan` | [交通公告](https://www.ilcpb.gov.tw/News.aspx?n=19610&sms=17012) | ASP.NET `tr`；正常POST `jNewsModule_field_2` | 可讀；很多是其他縣市整表轉載。[宣告](https://www.ilcpb.gov.tw/cp.aspx?n=16413)明列G1但內文寫警政署，原創內容適用範圍存疑 |
| 宜蘭縣警局 `yilan` | [蘭陽交通](https://www.ilcpb.gov.tw/News.aspx?n=19609&sms=17011) | 同上；不是GET `_field_2`偽搜尋 | 可讀；同上宣告疑義，只摘事實索引 |
| 彰化縣警局 `changhua` | [交通資訊](https://www.chpb.gov.tw/Announcement/C002100?PageType=0) | HTML `div.row`、`a.txt-link`；GET `SearchKeyword`、`PageIndex` | 可讀。[G1宣告](https://www.chpb.gov.tw/StaticPage/opendata)，須署名 |

另調查但**未列為已適配來源**：新北總局最新消息、臺北／臺北交通大隊其他最新消息分類、
雲林警局首頁與公告。高雄舊 `www.kmph.gov.tw` 無法連線；
新站網址由高雄市府的機關網站清單找到，不以猜測的替代域名繞過拒絕。
沒有處理CAPTCHA、登入、代理、瀏覽器偽裝或私人資料庫。

## 工具用法與界線

從repo根目錄執行；`--cameras`務必指定實際完整資料，不使用repo空佔位檔證明收錄情形：

```powershell
python -I -X utf8 data-pipeline\watch_announcements.py --cameras build\ci-data\cameras.json --output-dir build\announcements
python -I -X utf8 data-pipeline\watch_announcements.py --cameras build\ci-data\cameras.json --source shilin --source xindian --source ntpc-traffic --since 2025-11-16 --until 2026-11-16 --output-dir build\announcements-local
```

預設採臺灣日期往回365天。產出 `pending.csv`（UTF-8 BOM）、`pending.md`、`report.json`、
`raw\`原始HTML與每次呼叫的URL／方法／最終URL／狀態／SHA-256。
CSV／Markdown含機關、原標題、日期及其種類、原連結、地點文字、異動類型與收錄提示。
`--markdown`可另指定Markdown檔；不會產生座標。

標題必須同時命中 `keywords.subjects` 與 `keywords.changes`；`keywords.exclude`可排除。
「重新啟用」、新增與拆除並存、測試／試辦／導入功能等保守列「調整」，不是確認新增設備。
`search_terms`另控制官網的實際搜尋字詞，預設「測速、科技執法、照相」；
改篩選詞時也應檢查這份查詢詞是否足夠，不能只加本機關鍵字就宣稱已搜到所有文章。
無伺服器搜尋適配的入口只讀近期列表；未解析PDF、圖片、附件或社群網站。

預設每組來源最多12次程式呼叫、每次12秒、起始時間至少間隔1秒、每個查詢最多2頁、
每組最多4篇**新**文章內文、單頁最多2MB，不自動重試。
高雄兩站20秒、臺南6頁、桃園只試1次；同組多個列表共用請求額度。
上限、單一URL失敗、改版或不明空白頁均列警告，仍處理其他列表／機關。
正常POST與伺服器重新導向屬原站流程；呼叫數不把每個HTTP重新導向另算一次。
Python 3.13政府憑證相容沿用專案 `ssl_context()`，只調整strict旗標，仍驗憑證鏈及主機。

只有同縣市的完整門牌、兩條路名路口、或簡單里程文字可供收錄提示；沿用既有地址正規化，
不以道路中點、地名方位或相近地址猜座標。不完整公車站名、無法唯一判縣市或空資料一律「無法判斷」。
目前比對不核行政區唯一性、方向、設備功能、座標與啟用日；同名路／缺段別、跨版本資料都可能造成誤判，
「可能已收／可能未收」都必須開原文與現有點位人工複核。多地點只要有一個可比對地點未對上，
整則會列「可能未收」並保留已對上的ID，不等於整則所有設備都缺漏。

## 已見索引與每週PR

`data-pipeline\announcements_seen.json`只存穩定文章URL及「標題＋列表日期」的SHA-256，
不是人工核准清單，不保存cookie／個人資料。跨搜尋詞及臺北同ID鏡像去重；
不同機關的轉載可能仍重複。標題或日期改變會重報；內文更新但兩者不變不會重報。
內文失敗或額度不足的項目會列待核但**不寫已見**，下次繼續嘗試。
第一次正式清單的3則已初始化進repo；後續週更不重報這3則。

只有明確加 `--update-seen`才原子更新索引；本機預覽預設不更動。
`--seen`可指定獨立既有JSON以測試；格式錯誤會拒絕，不靜默重設。
工具對 `cameras.json` 只讀，**永不寫 `manual\cameras_extra.csv`**。
人工確認經緯度、取締方向、速限、類型、啟用日與出處後，才另行維護人工CSV。

既有 `.github\workflows\data.yml` 的 `Refresh camera data` 已接在完整資料驗證／PR說明之後：
使用本輪 `build\ci-data\cameras.json`，執行監看、`--update-seen`，
並以 `--pr-body build\data-pr-body.md`附上「本週新公告（待人工核對）」。
「本週新」指本週首次發現，並非保證本週發布；每列仍保留原站日期及日期種類。
沿用資料PR，不另開issue：可同輪比對，避免額外issue與權限／雜訊。
PR只加入既有相機資料與已見索引，不把每週時間戳或原始HTML寫進repo；
只有新公告、相機資料不變時，也能由已見索引差異開PR。
沒有新公告不追加公告段落、也不改索引；其他相機資料本來有變動時仍會照常開資料PR。
尚未合併的已見索引會在同一個 `data/refresh` PR重現，不另開新issue或新PR分支。

監看步驟最多10分鐘、`continue-on-error`；單站失敗仍留明確警告，全站失敗回傳1。
必要資料建置／驗證失敗仍停止後續PR與監看，不退用舊資料；這是依附資料PR的界線，
不是獨立於資料建置的保證送達服務。`always()`保留 `ci-data` artifact內的
`build\announcements\` CSV／Markdown／報告／原頁14天，即使監看失敗也盡量留證。
沒有修改排程、App、核心或資料發布閘門；本輪未push、未實際觸發Actions。

## 本輪證據與測試

研究原頁、失敗紀錄與修正前後實跑保留於本worktree的 `build\stage-h8\`，
最終正式結果在 `verified-initial\`，CSV為 `verified-initial\pending.csv`。
它使用指定的唯讀F完整資料（3,539點／82段），SHA-256見首份清單；
不是以目前HEAD重新完整建置的資料。
第一次實跑發現基隆兩種列表版型及停用下一頁標記，修正後重跑不再誤判失敗或重抓同頁。
高雄先前逾時仍留在初次證據，不冒充首次即成功。

小型fixture節錄已保存的官方列表／內文；表單隱藏值改為明確的fixture值，
頁尾測試地址另行標示。離線測試涵蓋版型、關鍵字、日期、分頁、POST、
已見／更新判斷、收錄提示、單站及同機關單列表失敗、額度與PR無新公告不改檔，
測試不連網。

```powershell
python -m pytest -q data-pipeline\tests\test_watch_announcements.py data-pipeline\tests\test_workflow_contract.py
python -m pytest -q data-pipeline
```
