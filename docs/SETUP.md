# 安裝教學：不需要 Mac、免費把 App 裝到 iPhone

整個流程：

```
GitHub Actions 編譯出 SpeedCam.ipa
        ↓ 下載到 iPhone 的「檔案」App
Windows 電腦上的 iloader（只在第一次用）：用「專用 Apple ID」幫 iPhone 裝好 SideStore
        ↓
iPhone 上的 SideStore 安裝 SpeedCam.ipa
        ↓
之後每 7 天在 iPhone 上自己續簽（搭配 LocalDevVPN），不需要電腦
```

為什麼不用 AltStore？AltServer 需要 Apple 官網版的 iCloud 才能登入 Apple ID，但現在 Windows 上 Apple 官網都會導到 Microsoft Store，而 Store 版的 iCloud 會讓 AltServer 卡在登入。iloader 只需要 iTunes 的驅動程式，**完全不需要 iCloud**。

需要準備：
- iPhone，**建議 iOS 26 以上**（CarPlay 上的 Live Activity 需要 iOS 26）。舊手機最低 iOS 15，差別見下方常見問題
- Windows 10／11 電腦（只有第一次安裝、或配對檔失效時才需要）
- USB 傳輸線
- 一個**新的** Apple ID（只拿來簽署 App，下面會說明原因）

> iloader 與 SideStore 是開源的第三方工具，畫面可能隨版本更新而不同；下面寫「依畫面指示」的地方，請以實際畫面為準。

---

## 步驟 1：申請一個專用的 Apple ID

**為什麼要另外申請？** 側載工具需要用 Apple ID 登入 Apple 的開發者服務，建立一張免費的開發憑證來簽署 App（跟 Mac 上的 Xcode 用免費帳號做的事一樣）。為了降低風險，不要用你平常的主帳號。

1. 用電腦開 <https://account.apple.com>，選「建立你的 Apple 帳號」。
2. 用一個新的 Email（可以另外申請一個 Gmail）。
3. 雙重認證的電話號碼**可以填你現在的手機號碼**。
4. 完成後，iPhone **不用**登入這個新帳號。iPhone 繼續使用原本的 Apple ID（App Store、iCloud 都不受影響）。

> 這個新帳號只會被 iloader 和 SideStore 用來產生簽署憑證。萬一有任何問題，你可以直接停用它，主帳號完全不受影響。

## 步驟 2：在 Windows 安裝 iTunes（非 Microsoft Store 版本）

iloader 需要 iTunes 附帶的 Apple 裝置驅動程式，才能透過 USB 跟 iPhone 溝通。Microsoft Store 版的 iTunes 裝在受限的沙盒裡，第三方工具可能抓不到 iPhone，所以要改裝「電腦版」。

1. **如果已經裝了 Store 版 iTunes，先移除**：Windows「設定 → 應用程式 → 已安裝的應用程式」→ 找到 iTunes → 解除安裝。
2. 按開始鍵，搜尋並打開「**終端機**」（或「命令提示字元」），貼上這行後按 Enter：

   ```
   winget install --id Apple.iTunes -e --source winget
   ```

   `winget` 是 Windows 內建的安裝工具，`--source winget` 會從 Apple 的伺服器下載傳統安裝檔，不經過 Microsoft Store。過程中如果問你是否同意條款，輸入 `Y`。
3. 備用方式：如果 winget 不能用，可以試 Apple 的直接下載連結 <https://www.apple.com/itunes/download/win64>（下載到的是 `iTunes64Setup.exe` 才對；如果又被導到 Microsoft Store，就用上面的 winget）。
4. **不需要安裝 iCloud。**

## 步驟 3：在 Windows 安裝 iloader

在同一個終端機執行：

```
winget install --id nabdev.iloader -e
```

或到 iloader 的 GitHub 頁面（<https://github.com/nab138/iloader/releases>）下載 Windows 版安裝檔。

## 步驟 4：在 iPhone 安裝 LocalDevVPN

到 App Store 搜尋並安裝 **LocalDevVPN**。

SideStore 在手機上自己續簽時，需要假裝成「iPhone 有接著電腦」，LocalDevVPN 就是用來做這件事的本機 VPN（流量不會送到外部伺服器）。

## 步驟 5：用 iloader 把 SideStore 裝到 iPhone

1. 用 USB 把 iPhone 接上電腦，iPhone 上選「**信任這部電腦**」並輸入密碼。
2. 打開 iloader，用**步驟 1 申請的新 Apple ID** 登入。
3. 選擇安裝 **SideStore**，依畫面指示完成。iloader 會順便把 SideStore 需要的「配對檔」（pairing file）放進 iPhone。
4. iPhone 上會出現 SideStore。先到 iPhone「**設定 → 一般 → VPN 與裝置管理**」，點選那個 Apple ID →「信任」。
5. 開啟**開發者模式**：iPhone「**設定 → 隱私權與安全性 → 開發者模式**」→ 打開 → 依指示重新開機。
   （這個選項要在裝過側載 App 之後才會出現。）
6. 打開 **LocalDevVPN** 並連線，再打開 **SideStore**，依畫面指示用**同一個新 Apple ID** 登入。

## 步驟 6：從 GitHub 下載 App（IPA）

1. 打開這個專案的 GitHub 頁面 → 上方 **Actions** 分頁。
2. 左側選「**Build IPA（未簽署，側載用）**」→ 右邊「**Run workflow**」→ 綠色按鈕 Run workflow。
   （這個 IPA 是未簽署的，SideStore 和 AltStore 都能用。）
3. 大約 10～20 分鐘後完成（綠色勾勾），點進那次執行，捲到最下面 **Artifacts**，下載 **SpeedCam-ipa**。
   - 也可以直接用 iPhone 的 Safari 登入 GitHub 下載，省去從電腦傳檔。
4. 解壓縮後會得到 `SpeedCam.ipa`，把它存到 iPhone 的「**檔案**」App。
   - iPhone 上點 zip 檔會自動解壓縮。
   - 如果是在電腦上下載，可以上傳到 iCloud Drive（用瀏覽器開 icloud.com）或 Google Drive，再從 iPhone「檔案」App 存下來。

## 步驟 7：用 SideStore 安裝

1. 確認 **LocalDevVPN 已連線**。
2. 打開 SideStore → 下方「**My Apps**」→ 左上角「**＋**」→ 選 `SpeedCam.ipa`。
3. 如果出現 App ID 相關提示，同意即可（這個 App 包含主程式和 Live Activity 擴充功能，會使用 2 個 App ID）。
4. 安裝完成後，主畫面會出現「**測速地圖**」（SideStore 的 My Apps 清單裡顯示英文名稱 **SpeedCam**，是同一個 App）。

> 備用方式：iloader 也能直接從電腦匯入 IPA 安裝。但這樣裝的 App 之後續簽需要再接電腦，所以建議用 SideStore 安裝。

## 步驟 8：第一次使用

1. 打開「測速地圖」，會自動開始巡航（測速偵測）。不想自動開始的話，可以在設定頁關閉「開啟 App 時自動開始巡航」，之後改按下方綠色 ▶︎。
2. 定位權限選「**使用 App 期間允許**」，並保持「精確位置」開啟。
3. 開始巡航後，鎖定畫面會出現 Live Activity。
4. **CarPlay**：接上車機（汽車或重機的 CarPlay 螢幕），在 CarPlay 的**儀表板（Dashboard）**畫面就會看到大字的測速提醒。
   - 想讓字更大：iPhone「**設定 → 一般 → CarPlay → 選擇你的車 → 顯示**」開啟 **Smart Display Zoom**。
5. **地圖**：右下角的箭頭按鈕會回到目前位置，並依車速自動縮放。跟隨中再按一次，可以切換「行進方向朝上 → 北方朝上 → 3D」。
   - 把地圖滑到別處後，只要車速超過 15 km/h、而且 10 秒沒碰地圖，就會自動回到目前位置。
   - 照相點如果標著「高架」或「平面」，代表那附近有高架和平面道路重疊。App 分不出你在哪一層，請依標籤自己判斷。
6. **導航**：按放大鏡搜尋目的地。邊打字會邊出現候選地點；沒輸入時可以點「加油站」「停車場」等快速搜尋，或從「最近的目的地」直接出發。
   - 選好地點後，地圖會先移到那個地點（約 3 秒，或點卡片／「查看路線」），接著顯示整條路線的距離和時間。
   - 按「開始導航」或等 10 秒倒數結束就開始導航；預覽時拖動地圖，倒數會暫停，改成等你按。隨時可以按「取消」。
7. **搜尋與導航語言**（設定頁最上面）：手機是英文、但想用中文搜尋和導航時，選「中文」，再按「立即重新開啟 App」。
   App 會回到主畫面並關閉，再點一次圖示就會用新的語言（iOS 規定要重新開啟才會生效），不必改整支手機的語言。
8. 右下角齒輪還可以調整：車種、自動巡航、提醒距離、超速容許值、嗶聲間隔、區間容許值、語音開關。

> Live Activity 最長只能維持 8 小時，而且只能在 App 開著時重新開始。長途開車超過 8 小時，打開一下 App 就會自動重新開始。

### 常用地點（住家、公司）

在搜尋頁點未設定的「住家」或「公司」，搜尋並選取地點，或點一筆最近的目的地。設定後會留在搜尋頁，不會開始導航。下次點已設定的捷徑或常用地點，才會預覽路線。長按捷徑可選「改成別的地點」或「移除」。

也可以在地圖長按地點後點星號，選「設為住家」「設為公司」或「加入常用地點」。黃色實心星號表示附近已有儲存的地點，點開可移除。「最近的目的地」往右滑可「加入常用」。

設定 →「常用地點」→「管理常用地點」可更換住家／公司或「新增常用地點」（最多 20 個，不含住家與公司）。點常用地點的名稱，改好後按「儲存」；留白會恢復原地點名稱。往左滑可刪除，按「編輯」可拖曳常用地點排序。地點清單只存本機，不上傳、不匯出；「恢復預設值」不會刪除。

### 導航中遇到照相點

設定 →「導航中遇到照相點」可直接切換「大字互換（A）」或「右上小牌（B）」，不必重開 App。預設 A：導航或照相提醒擇一放大，另一個縮在底部。B 保留導航大字，照相資訊放右上角，超速時整張變紅。兩者只改手機字卡；語音、鎖定畫面、CarPlay 和導航＋區間合併卡不變。

## 固定照相超速嗶聲

設定 →「超速警示」→ **嗶聲間隔**，拖動滑桿可選 **0.5～10 秒、每 0.5 秒一格**，預設為 **5 秒**。標題旁即時顯示「每 0.5 秒」「每 5 秒」，放大文字時改為上下排列；VoiceOver 會讀間隔與秒數。舊版沒有修訂欄位的 3 秒（包含從未調過）自動改為 5 秒；其他舊值保留，新版明確選 3 秒也會保留。超出範圍夾回，NaN／無限大回到 5 秒；儲存一律寫入 `overspeedBeepIntervalRevision: 2`，不動其他偏好。

只影響照相點的超速嗶聲，區間內仍為 15 秒嗶聲／30 秒超速語音；一般超速容許值、Live Activity 跳出提醒、區間歸零與隧道推算規則不變。未設速限只提醒不嗶。降速、通過、隱藏或修改正在提醒的點、停止巡航會立即取消排程並停止播放器；沒有可靠新定位達 2.5 秒就停，不可靠定位不能延長期限，不使用隧道舊車速繼續嗶，超速畫面仍依原核心最多保留 10 秒。

**排程方式與取捨**：實際 WAV 為 44,100 Hz、7,938 個取樣，音長 **0.18 秒**，不換音、不疊播。間隔 **1.5 秒以上只在嗶聲時壓低音樂**：專用 `AVAudioPlayer` 每聲前約 0.05 秒啟用音訊工作階段，以音訊時鐘對準原節拍，聲音結束約 0.25 秒後停用，兩聲之間恢復音樂；若語音或其他提示音仍在播，就等空閒再停用。間隔 **0.5／1 秒**沿用單一「原嗶聲＋靜音」WAV 循環、超速期間持續壓低，避免 iOS 恢復音量來不及而忽大忽小。兩種模式都不另播 Core 的相機嗶聲事件；開始超速立即一聲，改值以上一聲＋新間隔重排，近距／超速語音優先，略過的節拍不補播、不重設。區間嗶聲仍用原事件播放。

保留 `.playback`／`UIBackgroundModes=audio` 宣告；逐聲 Task 與定位逾時鬧鐘分開，改值或跨模式切換會取消舊世代、停止舊播放器。系統音訊中斷時清除兩種模式與排程，中斷結束後要等下一次仍有效的可靠定位狀態才重啟，不拿過期車速自動重播。**Windows 的核心測試無法證明 iOS 背景排程、逐聲恢復音量、音訊中斷／恢復、鎖屏／CarPlay 或繁忙主執行緒下的取消延遲**；這些都要在實機以 0.5／1／1.5／5／10 秒、語音插播、跨門檻改值、降速／通過／失聯／隱藏修改／停巡航逐項聽驗，不能當成已驗收。

## 自行新增、修改與隱藏照相點

資料只存這支手機的 App 儲存空間，不會自動上傳、不用帳號，也沒有匯入功能。更新 App 會保留；刪除 App 前請先匯出。

### 行車中一鍵記點

巡航或導航中，定位可靠時，地圖右側「回到目前位置」上方會出現**相機加號**。按一下就把當下位置存成測速照相點，不開表單、不用再確認，也不停止地圖跟隨。行車中請由乘客操作，或安全停妥後再操作。

- 先不填速限，方向取最後一次至少 8 km/h 的可靠行向；沒有行向就存「不確定」。地址先存座標，背景反查有路名才補上，失敗不彈提醒。
- 「已新增測速點」卡約 8 秒後消失；可直接選 **40／50／60／70**，選後立即儲存並收卡；「其他」開啟原修改表單。「復原」立即刪除此點，不再跳確認。
- 沒選速限就保持「速限未設・只提醒不嗶」；之後點地圖照相點 →「修改」，或設定 →「我的照相點」→「管理照相點」→ 該點「修改」，補上現場確認的速限。
- 新點視為已通過，當下不提醒自己；補速限、反查地址仍保留通過冷卻。離開 1 公里或滿 10 分鐘後，再經過才依原規則提醒；未填速限仍有兩段距離提醒，但不判超速、不嗶。
- 確認卡消失且距上次按下至少 3 秒才能再記；本次開啟 App 已快速記下的點在 50 公尺內會重顯原卡，不重複新增。一般選點新增不因此被自動合併。
- 沒巡航／導航、定位不可靠或失聯超過 2.5 秒、路線預覽、選點卡／詳情卡／新增修改表單開著時不顯示此按鈕。導航／預覽仍不能長按選點，不改原本底部列。

### 地圖選點與後續管理

1. **新增**：在地圖長按位置，或點選地點（iOS 15 僅長按），在選點卡按次要的「新增照相點」。導航或預覽中不能選點，請先結束或取消。原本綠色的「開始導航」仍是預覽導航的入口。
2. 選「測速照相」或「闖紅燈照相」。測速速限預設 50，可選 30～110、每 10 一格；闖紅燈沒有速限欄、不會發超速嗶聲。
3. 選**車輛行進的方向**，不是鏡頭面向。巡航中有取自至少 8 km/h 可靠定位的最後行向，且目前可靠位置距選點不超過 150 公尺時，會預選「和我現在的行車方向相同」，儲存實際角度。也可選八方位，或「雙向」後選南北、東西、東北–西南、西北–東南軸向。
4. 「不確定」不填方向，沿用核心的正前方 30° 備案；已追蹤且小於 30 公尺時會放寬。地址自動沿用選點名稱／地址，反查失敗使用「自行新增（緯度, 經度）」，不用輸入文字；提醒短地址改顯示「所選位置」，完整原值保留於詳情與匯出，不在提醒加來源標籤。
5. 按「儲存」後立即進入地圖與提醒核心。50 公尺內已有同類型點、或位置在區間覆蓋範圍時會提示，但仍可儲存。**現行核心只消音已知區間中的 `section` 相機，一般固定點不會因在區間附近就消音**；自行新增點與官方同類型點使用相同規則。

點照相點開啟詳情，可以「修改」或「隱藏」官方／OSM 點；隱藏立刻移出地圖和提醒，並顯示「已隱藏，可到設定復原」。修改不改官方類型／位置，只改方向，以及原本有測速語意的速限（固定、測速兼闖紅燈、明列測速的科技執法）；熱點、聲音與非測速類型只改方向，不會因修改新增超速嗶聲。原始資料沒速限時可保留「未提供」，非標準原值也可保留。

自行新增點會標示「自行新增」，可改類型、速限與方向；「刪除」須確認且無法復原。官方點修改後標示「已自行修改」，可按「還原成原始資料」。`section` 區間相機與區間路線都沒有修改／隱藏入口。

設定 →「我的照相點」→「管理照相點」可分別查看自行新增、已修改、已隱藏，並刪除／還原／復原。正式資料更新後 id 消失的隱藏／修改設定仍保留，但不生效；清單會註明。巡航中編輯不重設其他照相點的預告／冷卻，也不重設正在進行的區間時間或超速節流。

個人資料保存在 Application Support 的 `userCameraEdits.v1.json`。檔案內容壞掉（無法解碼或驗證）時會警告並記錄 log，原檔改名為 `userCameraEdits.v1.corrupt-<UUID>.json` 保留，本次先用官方資料；後續新增另寫新檔。如果連改名保留都失敗，就停止寫入，避免覆蓋原檔。檔案在但暫時讀不到（例如重開機後還沒解鎖 iPhone、App 被背景定位喚醒）不算壞檔：不改名，本次停止編輯，下次開啟 App 再讀。

### 匯出給維護者

在「管理照相點」按「匯出」，於系統分享面板依畫面指示儲存或傳送**兩個檔案**：

- `cameras_extra_user.csv`：UTF-8（含 BOM，Windows 的 Excel 直接開不會亂碼），只有自行新增點，欄位順序與 `data-pipeline\manual\cameras_extra.csv` 完全相同，來源含新增日期；單向角度、南北／東西雙向及未知方向可直接解析。**未填速限寫空欄**，既有管線解析為未知，不是 0；來源另標「速限未設」，核對 JSON 的 `speedLimit` 亦保持未填，`speedLimitUnsetIDs` 列對應 id、notes 說明只提醒不嗶。
- `camera_edits.json`：自行新增的精確原值，以及隱藏／修改的原始 id、短地址、座標、原值與新值；資料更新後消失的 id 會附當初保存的原值並標記。只有照相點，不含行車軌跡、車速、定位時間或帳號資訊。

**CSV 的限制**：既有管線只支援南北／東西雙向軸向。斜向或其他精確軸向在 CSV 會寫成「雙向（軸向 N°；詳 camera_edits.json）」，解析後是不指定軸向的雙向／未知方向備案，不會捏造成單向。App 與 JSON 仍保留原始軸向，維護者須先核對，不可當成已精確表達。App 匯出來源標記及「取締項目」請保留，管線藉此避免 POI 名稱裡的「區間／闖紅燈」或過港地址特例覆蓋使用者明選的類型／方向。

維護者收到檔案後：

1. 先用 JSON 核對位置、類型、速限、行向及是否重複；隱藏／修改只是待核對建議，不直接批次套進正式資料。
2. 將 **CSV 中核可的資料列**加到 `data-pipeline\manual\cameras_extra.csv`，只保留一份原欄名，使用 UTF-8，保留逗號／引號的合法 CSV 引述及「來源」。斜向軸向先核對 JSON 和道路證據；未釐清時不發布猜測的單向。不要直接用文字串接整份檔案，以免重複欄名。
3. 在 repo 根目錄執行 `python -m pytest -q data-pipeline`。後續資料重建、IPA 與完整驗收仍走既有流程（見 [CI.md](CI.md)），個人 JSON 不會自動匯入，也不提交個人檔案。
4. 新版確定已收錄後，可在手機「我的照相點」刪除對應自增點，避免與新正式 id 並存；不會依地址或距離自動刪除個人設定。

## 每 7 天續簽一次（不需要電腦）

免費 Apple ID 簽的 App 只有 **7 天**效期，過期後 App 會打不開（資料不會遺失）。

1. 打開 **LocalDevVPN** 並連線。
2. 打開 **SideStore** → My Apps → **Refresh All**。

建議固定在每週同一天做一次（例如週末加油時）。SideStore 會顯示每個 App 還剩幾天。

免費帳號的限制：
- 同時最多 3 個側載 App（**SideStore 本身算 1 個**，所以還能再裝 2 個）。
- 每 7 天最多註冊 10 個 App ID（這個 App 用 2 個）。

## 更新 App

重新跑一次「Build IPA」，下載新的 `SpeedCam.ipa`，在 SideStore 用「＋」安裝即可覆蓋舊版（設定會保留）。

---

## 常見問題

**Q：iloader 找不到 iPhone，或出現「Failed to connect to usbmuxd: device socket io failed」？**

iloader 是透過 Apple 的「Apple Mobile Device Service」（電腦本機 27015 埠）跟 iPhone 溝通，這個服務和 iPhone 的驅動程式都來自「Apple Mobile Device Support」這個元件（iTunes 安裝檔裡附的）。依你看到的狀況選對應的段落。

> 以下凡是動到服務或系統資料夾的指令，都要在**系統管理員**的 PowerShell 執行（開始按鈕按右鍵 → **Terminal (Admin)**，視窗標題要有「Administrator」）。用一般權限執行會出現「Cannot open … service」。

**狀況 A：iTunes 跳出「This iPhone cannot be used because the required software is not installed」**

代表 Apple Mobile Device Support 沒裝起來（用 winget 裝整包 iTunes 時偶爾會這樣）。把這個元件從安裝檔裡拿出來單獨安裝：

1. 下載 iTunes 安裝檔（只下載，不執行）：

   ```
   winget download --id Apple.iTunes -e --source winget -d "$env:USERPROFILE\Downloads\iTunesSetup"
   ```

2. 安裝 7-Zip（`winget install --id 7zip.7zip -e --source winget`），到 `下載\iTunesSetup` 找到 iTunes 安裝檔，按右鍵 → **Show more options** → **7-Zip** → **Extract to "…\"**，解開後會看到 `AppleMobileDeviceSupport64.msi`。
3. 如果「Settings → Apps → Installed apps」裡已經有「Apple Mobile Device Support」，先解除安裝。
4. 在解開的資料夾空白處按住 Shift＋右鍵 → **Open in Terminal**，執行（會跳出系統管理員確認，並在桌面留下安裝紀錄 `amds-install.log`）：

   ```
   Start-Process msiexec -ArgumentList "/i `"$PWD\AppleMobileDeviceSupport64.msi`" /l*v `"$env:USERPROFILE\Desktop\amds-install.log`"" -Verb RunAs -Wait
   ```

   一定要像這樣用**完整路徑**（`$PWD\…`）；只寫檔名會出現「This installation package could not be opened」，因為提權後的工作目錄是 `C:\Windows\System32`。也可以直接在檔案總管雙擊那個 `.msi` 安裝。
5. 裝完**重新開機**。裝置管理員的「Universal Serial Bus devices」底下應該會出現 **Apple Mobile Device USB Device**。

iloader 只需要這個元件，就算 iTunes 本身還在跳錯誤，也可以直接試 iloader。

**狀況 B：裝置管理員裡 iPhone 顯示成「MTP USB Device」，或在「Other devices」有驚嘆號**

代表 Windows 用了內建的通用驅動程式，Apple 的驅動程式沒有綁上去：

1. iPhone 解鎖並接上電腦 → 裝置管理員 → 對那個裝置按右鍵 → **Update driver** → **Browse my computer for drivers** → **Let me pick from a list of available drivers on my computer** → **Have Disk…** → **Browse…**。
2. 選 `C:\Program Files\Common Files\Apple\Mobile Device Support\Drivers\usbaapl64.inf` → **OK** → **Next**。（找不到這個檔案就先做狀況 A。）

**狀況 C：iloader 顯示「No devices found」**

服務正常，但沒有跟 iPhone 完成配對。清掉電腦上的舊配對紀錄再重新信任：

1. 拔掉 iPhone，在 PowerShell 執行下面這行（會自動用系統管理員身分開新視窗，最後顯示 `Running` 就完成了）：

   ```
   Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-Command','Stop-Service "Apple Mobile Device Service"; Remove-Item "C:\ProgramData\Apple\Lockdown\*" -Force -ErrorAction SilentlyContinue; Start-Service "Apple Mobile Device Service"; Get-Service "Apple Mobile Device Service"'
   ```

2. iPhone 解鎖後重新接上，跳出「要信任這部電腦嗎？」時點「**信任**」並輸入密碼，然後在 iloader 按 **Refresh**。
3. 手機沒有跳出信任視窗的話：iPhone「設定 → 一般 → 移轉或重置 iPhone → 重置 → **重置定位與隱私權**」（會清除所有信任過的電腦，App 之後會重新詢問定位權限，不會刪資料），再重新接上。
4. 還是不行：在裝置管理員對「Apple Mobile Device USB Device」按右鍵 → **Uninstall device**（不要勾移除驅動程式），拔掉 iPhone 再接回去讓 Windows 重新綁定。

**通用檢查**

- 用原廠線，直接插電腦本體的 USB 孔，不要經過 Hub 或延長線（[#404](https://github.com/nab138/iloader/issues/404)）；有些副廠線只能充電。
- iPhone 必須設定密碼，接上時要解鎖。
- 有 Microsoft Store 版的 iTunes、Apple 裝置（Apple Devices）時先移除，避免和電腦版搶裝置（[#396](https://github.com/nab138/iloader/issues/396)）。
- 診斷用的三行指令（結果可以拿去問人）：

  ```
  winget list --name Apple
  Get-Service "Apple Mobile Device Service"
  netstat -ano | findstr 27015
  ```

  第二行應該是 `Running`；第三行應該看到 27015 埠的連線（`LISTENING` 或 `ESTABLISHED`）。

**Q：SideStore 登入時出現「This action cannot be completed at this time. (-80045)」？**

這不是帳號或操作問題：2026 年 10 月中起 Apple 改了登入檢查，SideStore、AltStore、Sideloadly 等工具都出現同樣的錯誤（[SideStore #1709](https://github.com/SideStore/SideStore/issues/1709)、[#1705](https://github.com/SideStore/SideStore/issues/1705)）。原因是這些工具登入時送出的模擬裝置資料（Anisette）被 Apple 拒絕。官方修正還沒釋出，以下是社群回報有效的做法（2026-11 初）：

1. 按 **Close** 關掉登入畫面 → 下方 **Settings** 分頁。
2. **Anisette Servers** → 選 **SideStore (New)**；有「Enable Auto Rotation」開關就關掉。
3. 按 **Reset adi.pb**（位置依版本不同）：
   - 穩定版：**Anisette Servers** 頁面捲到最下面。
   - Nightly 版：**User Customizations** 裡面。
4. Nightly 版另外做：User Customizations → 關閉 **On-Device Anisette**；Anisette Client Configuration → Remote Server Sync → **Fetch** → **Save as Overrides**。
5. 把 SideStore 從多工畫面滑掉、重新打開，再登入（可能會要求雙重認證碼）。
6. 還是 -80045，或改成出現 ADP 錯誤：回到 Anisette Servers 換其他伺服器（例如 **Lill q**、**SideStore (.app)**）再試。
7. 穩定版找不到這些選項：用 iloader 改裝 **SideStore (Nightly)**，再照上面做。

都不行的話的**備案**：新版 iloader（2.4.1 起）可以正常登入，可以直接用 iloader 把 `SpeedCam.ipa` 裝到 iPhone、跳過 SideStore。缺點是每 7 天要接電腦、用 iloader 重裝一次才能續簽。

**Q：iloader 登入時出現「GrandSlam error during initial login request」「Auth error -22410: This action could not be completed. Try again.」？**

2026-11-21 起很多人同時遇到，Windows、Mac 都有，看起來不是帳號或密碼錯（[iloader #1209](https://github.com/nab138/iloader/issues/1209)、[#1220](https://github.com/nab138/iloader/issues/1220)、[#1230](https://github.com/nab138/iloader/issues/1230)）。官方修正還沒出，社群回報有效的做法（2026-11-22）：

1. 先確認 iloader 是最新版（2.4.2 起）：`winget upgrade --id nabdev.iloader -e`。
2. iloader 的 **Settings** → **Reset Anisette State** → 確認。
3. 把 iloader 完全關掉（工作列右下角有圖示的話也要結束），重新打開再登入。
4. 還是失敗：把 Anisette 伺服器換成 `https://mac-ani.jkcoxson.com/`（選項位置依畫面指示；#1209 一位回報者有效），再做一次 2～3。

第 2～3 步在 #1220 有兩人回報有效；#1230 也有人試了別串的做法仍然無效。另有人登入走到簡訊驗證碼時回 403，原因不明（[#1213](https://github.com/nab138/iloader/issues/1213)）。

**Q：SideStore 安裝時出現「Bundle identifier unavailable: An invalid value '測速地圖' was provided for the parameter 'appIdName'」？**

這是 2026-11-04 以前的舊版 IPA 才有的問題：SideStore 會拿 App 的名稱向 Apple 註冊 App ID，而 Apple 只接受英數字。新版 IPA 的內部名稱已改成英文 **SpeedCam**（主畫面仍顯示「測速地圖」），請重新到 Actions 下載最新的 SpeedCam-ipa 再安裝一次。失敗的那次安裝不會用掉 App ID 額度。

**Q：SideStore 續簽失敗？**
- 確認 LocalDevVPN 有連線（狀態列會出現 VPN 圖示）。
- 配對檔可能失效了（例如 iPhone 重設過、或更新了 iOS）：把 iPhone 接回電腦，用 iloader 的配對檔管理功能重新放一次。

**Q：安裝時出現「無法驗證 App」或打不開？**
到「設定 → 一般 → VPN 與裝置管理」信任該 Apple ID，並確認已開啟開發者模式（iOS 16 以上才有這個設定）。

**Q：舊手機（例如 iPhone 7、iOS 15）可以裝嗎？**
可以，適合拿來測 App 內的功能：照相點提醒、語音、區間倒數、搜尋、設定。下面這些和新手機不一樣：
- 地圖和定位是另一套做法，鏡頭跟隨和手勢的結果不能代表新手機。
- 沒有 Live Activity（iOS 16.2 以上才有），也就沒有鎖定畫面的卡片和 CarPlay。
- iOS 15 不能要求 Apple 避開高速或收費，機車路線幾乎都會跳提醒，也可能走到快速道路或高架。**機車路線要用 iOS 16 以上的手機判斷。**
- iOS 18 以前，打開搜尋不會自動跳出鍵盤，要點一下搜尋框。

**Q：CarPlay 上沒看到 Live Activity？**
- iPhone 需要 iOS 26 以上。
- App 必須在「巡航中」（下方按鈕是 ■）。
- 檢查 iPhone「設定 → 測速地圖 → 即時動態（Live Activities）」是否開啟，以及 App 設定頁裡的 Live Activity 開關。
- CarPlay 的 Live Activity 顯示在**儀表板（Dashboard）**畫面，不是 App 圖示裡。

**Q：地圖上沒有照相點？**
- 地圖縮太小時不會顯示，請放大。
- 到設定頁看「照相點」數量。如果是 0，表示這次 IPA 沒有成功下載資料，請重跑「Build IPA」。

**Q：之後想改用 TestFlight（不用每週續簽）？**
加入 Apple Developer Program（US$99／年）後就可以，這也是申請 CarPlay 導航權限（Phase 2）的前提。程式碼不需要修改，只要再加一個上傳 TestFlight 的流程。

---

## 附錄：仍想用 AltStore 的話

AltStore 官方文件要求 iTunes 和 iCloud 都是 Apple 直接提供的版本，不能是 Microsoft Store 版：
- iTunes：用上面步驟 2 的 winget 指令安裝。
- iCloud：AltStore 文件提供舊版 iCloud（7.21）的直接下載連結：
  `https://updates.cdn-apple.com/2020/windows/001-39935-20200911-1A70AA56-F448-11EA-8CC0-99D41950005E/iCloudSetup.exe`
  （這是 2020 年的版本，能不能在你的 Windows 上正常安裝和登入，無法保證。）

AltStore 每 7 天續簽時，需要電腦開著 AltServer，而且 iPhone 要跟電腦在同一個 Wi-Fi。
