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
- iPhone，**iOS 26 以上**（CarPlay 上的 Live Activity 需要 iOS 26）
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
4. 安裝完成後，主畫面會出現「**測速地圖**」。

> 備用方式：iloader 也能直接從電腦匯入 IPA 安裝。但這樣裝的 App 之後續簽需要再接電腦，所以建議用 SideStore 安裝。

## 步驟 8：第一次使用

1. 打開「測速地圖」→ 按下方綠色 ▶︎（開始巡航）。
2. 定位權限選「**使用 App 期間允許**」，並保持「精確位置」開啟。
3. 開始巡航後，鎖定畫面會出現 Live Activity。
4. **CarPlay**：接上車機（汽車或重機的 CarPlay 螢幕），在 CarPlay 的**儀表板（Dashboard）**畫面就會看到大字的測速提醒。
   - 想讓字更大：iPhone「**設定 → 一般 → CarPlay → 選擇你的車 → 顯示**」開啟 **Smart Display Zoom**。
5. 右下角齒輪可以調整：車種、提醒距離、超速容許值、嗶聲間隔、區間安全餘裕、語音開關。

> Live Activity 最長只能維持 8 小時，而且只能在 App 開著時重新開始。長途開車超過 8 小時，打開一下 App 就會自動重新開始。

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

**Q：iloader 找不到 iPhone？**
- 確認 iTunes 是用 winget 裝的電腦版，不是 Microsoft Store 版（裝完可以先打開 iTunes 一次，看它能不能認得 iPhone）。
- iPhone 要解鎖，並且已經選「信任這部電腦」。
- 換一條傳輸線或 USB 孔試試。

**Q：SideStore 續簽失敗？**
- 確認 LocalDevVPN 有連線（狀態列會出現 VPN 圖示）。
- 配對檔可能失效了（例如 iPhone 重設過、或更新了 iOS）：把 iPhone 接回電腦，用 iloader 的配對檔管理功能重新放一次。

**Q：安裝時出現「無法驗證 App」或打不開？**
到「設定 → 一般 → VPN 與裝置管理」信任該 Apple ID，並確認已開啟開發者模式。

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
