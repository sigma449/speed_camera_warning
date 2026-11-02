# 安裝教學：不需要 Mac、免費把 App 裝到 iPhone

整個流程：

```
GitHub Actions 編譯出 SpeedCam.ipa
        ↓ 下載
Windows 電腦上的 AltServer（用「專用 Apple ID」簽署）
        ↓ USB 或同一個 Wi-Fi
iPhone 上的 AltStore 安裝 App（每 7 天自動續簽）
```

需要準備：
- iPhone，**iOS 26 以上**（CarPlay 上的 Live Activity 需要 iOS 26）
- Windows 電腦（裝 AltServer，之後每週續簽也需要它開著）
- USB 傳輸線（第一次安裝用）
- 一個**新的** Apple ID（只拿來簽署 App，下面會說明原因）

---

## 步驟 1：申請一個專用的 Apple ID

**為什麼要另外申請？** 側載工具需要用 Apple ID 登入 Apple 的開發者服務，建立一張免費的開發憑證來簽署 App（跟 Mac 上的 Xcode 用免費帳號做的事一樣）。為了降低風險，不要用你平常的主帳號。

1. 用電腦開 <https://account.apple.com>，選「建立你的 Apple 帳號」。
2. 用一個新的 Email（可以另外申請一個 Gmail）。
3. 雙重認證的電話號碼**可以填你現在的手機號碼**。
4. 完成後，iPhone **不用**登入這個新帳號。iPhone 繼續使用原本的 Apple ID（App Store、iCloud 都不受影響）。

> 這個新帳號只會被 AltServer 用來產生簽署憑證。萬一有任何問題，你可以直接停用它，主帳號完全不受影響。

## 步驟 2：在 Windows 安裝 AltServer

AltStore／AltServer 是開源的側載工具（<https://altstore.io>）。

1. **先安裝 iTunes 和 iCloud 的「Apple 官網版本」**，不要用 Microsoft Store 的版本（AltServer 只認得官網版本）：
   - iTunes：<https://www.apple.com/itunes/download/win64>
   - iCloud：在 Apple 支援網站搜尋「Windows 版 iCloud 下載」，選擇非 Microsoft Store 的安裝檔。
2. 到 <https://altstore.io> 下載 Windows 版 **AltServer** 並安裝。
3. 執行 AltServer，它會出現在 Windows 右下角的系統匣（菱形圖示）。

## 步驟 3：把 AltStore 裝到 iPhone

1. 用 USB 把 iPhone 接上電腦，iPhone 上選「信任這部電腦」。
2. 打開 iTunes，點左上角的 iPhone 圖示 → 勾選「**透過 Wi-Fi 與此 iPhone 同步**」→ 套用（之後才能用 Wi-Fi 自動續簽）。
3. 在系統匣點 AltServer 圖示 → **Install AltStore** → 選你的 iPhone。
4. 輸入**步驟 1 申請的新 Apple ID** 和密碼。
5. iPhone 上會出現 AltStore。先到 iPhone「**設定 → 一般 → VPN 與裝置管理**」，點選那個 Apple ID → 「信任」。
6. 開啟**開發者模式**：iPhone「**設定 → 隱私權與安全性 → 開發者模式**」→ 打開 → 依指示重新開機。
   （這個選項要在裝過側載 App 之後才會出現。）

## 步驟 4：從 GitHub 下載 App（IPA）

1. 打開這個專案的 GitHub 頁面 → 上方 **Actions** 分頁。
2. 左側選「**Build IPA（未簽署，給 AltStore 側載用）**」→ 右邊「**Run workflow**」→ 綠色按鈕 Run workflow。
3. 大約 10～20 分鐘後完成（綠色勾勾），點進那次執行，捲到最下面 **Artifacts**，下載 **SpeedCam-ipa**。
4. 解壓縮後會得到 `SpeedCam.ipa`。
5. 把 IPA 放到 iPhone 的「檔案」App 裡，例如：
   - 上傳到 iCloud Drive（用電腦開 icloud.com）或 Google Drive，再從 iPhone「檔案」App 下載；或
   - 用 Email 寄給自己，在 iPhone 上存到「檔案」。

## 步驟 5：用 AltStore 安裝

1. 確認電腦上的 AltServer 正在執行，而且 iPhone 和電腦在**同一個 Wi-Fi**（或用 USB 接著）。
2. iPhone 打開 AltStore → 下方「**My Apps**」→ 左上角「**＋**」→ 選 `SpeedCam.ipa`。
3. 如果出現 App ID 相關提示，同意即可（這個 App 包含主程式和 Live Activity 擴充功能，會使用 2 個 App ID）。
4. 安裝完成後，主畫面會出現「**測速地圖**」。

## 步驟 6：第一次使用

1. 打開「測速地圖」→ 按下方綠色 ▶︎（開始巡航）。
2. 定位權限選「**使用 App 期間允許**」，並保持「精確位置」開啟。
3. 開始巡航後，鎖定畫面會出現 Live Activity。
4. **CarPlay**：接上車機（汽車或重機的 CarPlay 螢幕），在 CarPlay 的**儀表板（Dashboard）**畫面就會看到大字的測速提醒。
   - 想讓字更大：iPhone「**設定 → 一般 → CarPlay → 選擇你的車 → 顯示**」開啟 **Smart Display Zoom**。
5. 右下角齒輪可以調整：車種、提醒距離、超速容許值、嗶聲間隔、區間安全餘裕、語音開關。

> Live Activity 最長只能維持 8 小時，而且只能在 App 開著時重新開始。長途開車超過 8 小時，打開一下 App 就會自動重新開始。

## 每 7 天續簽一次

免費 Apple ID 簽的 App 只有 **7 天**效期，過期後 App 會打不開（資料不會遺失）。

- **自動**：電腦開著 AltServer、iPhone 跟電腦在同一個 Wi-Fi，AltStore 會在背景自動續簽。
- **手動**：iPhone 打開 AltStore → My Apps → **Refresh All**。

免費帳號的限制：
- 同時最多 3 個側載 App（**AltStore 本身算 1 個**，所以還能再裝 2 個）。
- 每 7 天最多註冊 10 個 App ID（這個 App 用 2 個）。

## 更新 App

重新跑一次「Build IPA」，下載新的 `SpeedCam.ipa`，在 AltStore 用「＋」安裝即可覆蓋舊版（設定會保留）。

---

## 常見問題

**Q：安裝時出現「無法驗證 App」或打不開？**
到「設定 → 一般 → VPN 與裝置管理」信任該 Apple ID，並確認已開啟開發者模式。

**Q：AltServer 找不到 iPhone？**
確認 iTunes 和 iCloud 是 Apple 官網版本，iPhone 已「信任這部電腦」，並在 iTunes 開啟「透過 Wi-Fi 同步」。

**Q：CarPlay 上沒看到 Live Activity？**
- iPhone 需要 iOS 26 以上。
- App 必須在「巡航中」（下方按鈕是 ■）。
- 檢查 iPhone「設定 → 測速地圖 → 即時動態（Live Activities）」是否開啟，以及設定頁裡的 Live Activity 開關。
- CarPlay 的 Live Activity 顯示在**儀表板（Dashboard）**畫面，不是 App 圖示裡。

**Q：地圖上沒有照相點？**
- 地圖縮太小時不會顯示，請放大。
- 到設定頁看「照相點」數量。如果是 0，表示這次 IPA 沒有成功下載資料，請重跑「Build IPA」。

**Q：之後想改用 TestFlight（不用每週續簽）？**
加入 Apple Developer Program（US$99／年）後就可以，這也是申請 CarPlay 導航權限（Phase 2）的前提。程式碼不需要修改，只要再加一個上傳 TestFlight 的流程。
