# O.Paperclip

**專門為mac使用者開發的macOS GPS 定位偽裝工具，透過 USB 或 Wi‑Fi 對 iPhone / iPad 注入模擬座標。**  
**MacOS app that spoofs GPS location on iPhone / iPad over USB or Wi‑Fi.**
 
**使用前請注意：iPhone / iPad 需開啟「開發者模式」**  
**如果這個專案對您有幫助，您可以在這裡支持（贊助）它的開發：Ko-fi: https://ko-fi.com/agocia**  

---

## 系統需求 / Requirements

| 項目 | 需求 |
|------|------|
| macOS | 13 Ventura 以上 |
| iPhone / iPad | iOS 16 以上，需開啟「開發者模式」 |
| 連線方式 | USB 或 Wi‑Fi（同一網路） |
| 其他 | 無需安裝 Python、Homebrew 或任何套件 |

---

## 安裝 / Installation

### 方法一：下載 DMG（推薦）

1. 前往 [Releases](../../releases) 頁面，下載最新的 `O.Paperclip.dmg`
2. 開啟 DMG，將 `O.Paperclip.app` 拖入 `Applications` 資料夾
3. 第一次開啟時，右鍵點選 App → 選「開啟」→ 確認開啟（繞過 Gatekeeper）

### 方法二：從原始碼建置

```bash
git clone https://github.com/agocia/O.Paperclip.git
cd O.Paperclip
uv python install 3.13
uv venv --managed-python --python 3.13 build/python-bundle
uv pip sync --python build/python-bundle/bin/python --require-hashes scripts/requirements-bundled.txt
zsh scripts/build-bundled-pymobiledevice3.sh
bash scripts/build-dvt-stream.sh
xcodebuild -project O.Paperclip.xcodeproj -scheme O.Paperclip -configuration Release build
```

CLI 與每裝置 worker 固定使用 `pymobiledevice3 11.49.2` 及同一份含 hashes 的依賴鎖。Python 僅重建工具時需要。使用支援 OpenSSL PSK 的 managed Python，重建後須核對所有內嵌 library 的最低系統不高於 macOS 14；不能直接封裝最低系統較新的 Homebrew Python。建置成功不代表真機、Intel 或 universal2 相容性已驗證。

---

## 使用前準備 / Before You Start

### iPhone / iPad 設定

1. **開啟開發者模式**（iOS 16+）  
   設定 → 隱私權與安全性 → 開發者模式 → 開啟 → 重新啟動

2. **信任這台 Mac**（USB 首次連線）  
   插上 USB 後，iPhone 會詢問「是否信任此電腦？」→ 點「信任」→ 輸入密碼

3. **Wi‑Fi 連線額外步驟**  
   先用 USB 完成一次信任配對，之後才能切換為 Wi‑Fi 模式

---

## 使用步驟 / How to Use

### 步驟一：連線裝置

最多同時連線三台不同裝置。「開始連線／新增連線」只探索當次可用裝置並逐台連線；一台成功即可啟動 GPS，不會等待湊滿三台。新增不重建已連線裝置，各台可單獨中斷，也可全部中斷。已連線裝置同步位置／路線；重啟 App 後連線欄位清空，不恢復舊 UDID 或手動 RSD。UDID 欄位顯示本次連線身分，探索結果不會受上次殘留值限制。

開發驗收需先安裝 Xcode 與 iOS 27.0 Simulator runtime，再執行 `python3 O.PaperclipTests/SimulatorEvidence/prepare.py`（其他 runtime 可透過 `PAPERCLIP_SIMULATOR_RUNTIME` 指定）。此命令建立三個暫時 Simulator、以 Core Location 觀察程式執行完整測試，結束後刪除測試裝置。GUI 測試暫用 ASCII 鍵盤配置並恢復原輸入法。模擬通訊端點不代表已驗證實體手機 USB／Wi-Fi 配對或 tunnel。

**USB 連線（預設）：**
1. 用 USB 線連接 iPhone / iPad
2. 開啟 O.Paperclip
3. 在側邊欄的「連線模式」分段切換中確認「USB」已選取
4. 點「開始連線」
5. 準備開發者映像與定位服務時保持裝置解鎖；App 不要求 Mac 管理員授權。

遠端配對另存於 `~/Library/Application Support/fregata.O-PaperclipPackaging/Pairing`，不刪除或修改舊版 `~/.pymobiledevice3` 配對檔。每台裝置首次需以 USB 建立本 App 的遠端配對；這可能更新裝置端同一台 Mac 的金鑰，舊版遠端連線不保證繼續有效。Wi‑Fi 探索另需允許執行 App 的「本機網路」權限。

**Wi‑Fi 無線連線：**
1. 確保 iPhone 與 Mac 在同一個 Wi‑Fi 網路
2. 開啟 O.Paperclip
3. 在側邊欄的「連線模式」分段切換中切換為「Wi‑Fi」
4. 點「開始連線」

> 若目前已經透過 USB 成功連線，可直接切換為 Wi‑Fi；App 會自動中斷目前連線並重新建立 Wi‑Fi tunnel。

> 連線成功後，側邊欄會顯示「已連線」及裝置名稱。
> 若 USB 被拔除、Wi‑Fi tunnel 中斷，App 會自動切換成斷線狀態並停止持續移動，等待你重新連線。

---

### 步驟二：選擇操作模式

側邊欄頂部的分段選擇器可切換三種模式：

| 模式 | 說明 |
|------|------|
| **A-B** | 在地圖上點選起點 A 和終點 B，App 自動規劃路線並沿路移動 |
| **定點** | 固定在地圖上點選的單一座標 |
| **多點** | 依序點選多個路徑點，App 依序移動 |

---

### 步驟三：設定位置

**A-B 路線模式：**
1. 點選地圖設定起點 A → 點「確認 A 點」
2. 點選地圖設定終點 B → 點「確認 B 點」
3. 選擇路線後點「開始移動」
4. 可調整速度（km/h）和是否循環

**定點模式：**
1. 點選地圖上的目標位置
2. 點「釘選此位置」
3. GPS 即固定在該點

**多點模式：**
1. 依序點選地圖上的路徑點
2. 點「開始移動」

> 也可在搜尋欄輸入地址或地名直接跳轉。

地圖會在操作結束後保存相機中心、距離、朝向與俯角，重新啟動及啟動時還原視窗尺寸後仍保留原視角。

---

### 步驟四：停止模擬

點「停止」或「清除路線」即可停止 GPS 偽裝，裝置恢復真實位置。

---

## PurePoint 地圖圖層 / PurePoint Overlay

支援匯入 KML 格式的地理資料，在地圖上顯示自訂標記：

1. 右側「匯入與收藏」欄點「匯入 KML」
2. 選擇 `.kml` 檔案
3. 圖層會顯示在地圖上，可依分類篩選

### 匯入與收藏

- 右側欄同時提供 KML、GPX 與本機收藏，不會因三台裝置欄位而移到左側。右上角可收合；收合後以地圖右側按鈕重新展開，重啟保留顯示狀態。
- 點「匯入 GPX」或拖入 `.gpx`，命名後點「使用」；原始軌跡直接成為就緒的多點草稿，不重新規劃道路。
- 匯入路線就緒後切換「閉圈」，直接補上末點回起點的直線線段，並重算圖線與累積距離；取消閉圈還原原始軌跡，不重新呼叫道路規劃。
- 完成定點或路線後可命名儲存，並在右側套用、定位、改名、刪除及排序；相容原上游 v1.2.1 的既有收藏／GPX 資料。套用草稿不會中斷既有裝置連線。

修復來源：多裝置版本以 v1.04 基底整合，遺漏原上游 [v1.2.1](https://github.com/agocia/O.Paperclip/tree/dc10107c3b474d90c19b6a1c48e0d2c2f3e84a45) 的右側欄功能；此處選擇性恢復該功能，保留 `DeviceGroup`。回歸測試位於 `ImportedAndSavedLocationTests.swift` 與 `O_PaperclipUITests.swift`，覆蓋 GPX／收藏持久化、三裝置連線保留、實際右欄位置與收合重啟；不同視窗寬度另以實際 Release App 縮放驗證。

---

## 常見問題 / Troubleshooting

**Q: 點「開始連線」後一直轉圈？**  
A: 確認 iPhone 已解鎖、USB 已信任此 Mac。若使用 Wi‑Fi，確認同一網路。

**Q: 連線需要管理員密碼或 Touch ID 嗎？**
A: 不需要。每台裝置由一般使用者 worker 持有 userspace tunnel 與定位服務。只有明確缺少 CoreDeviceProxy 的 USB 裝置才改用系統原生通道，該路徑可能與 Xcode／remoted 競爭；不退回 sudo 或 root helper。iPhone 的信任、密碼、開發者模式及配對仍必要。真機 GPS 穩定性、Wi‑Fi 配對與 macOS 14 運作需另做實機驗收，不能由自動化 fixture 推定。

**Q: Wi‑Fi 連線失敗，自動切換為 USB？**  
A: 僅 Wi‑Fi 不可用／不支援時，才可切換至同一 UDID 的 USB；配對、鎖定或協定錯誤不切換。缺少 RemotePairing／altIRK 資料時須先接上已信任的 USB；程式不自動刪除或強制更新舊配對記錄。

**Q: 已經用 USB 連上了，能不能直接切換成 Wi‑Fi？**  
A: 可以。直接在側邊欄把連線模式切到「Wi‑Fi」，App 會自動中斷目前 USB 連線並重新建立 Wi‑Fi tunnel。

**Q: 拔掉手機後 App 為什麼會停止移動？**  
A: 這是正常行為。現在偵測到 tunnel / 裝置中斷時，App 會立即顯示斷線並停止模擬，避免地圖流程繼續假跑。

**Q: 停止後 GPS 沒有恢復？**  
A: 點「清除定位點」或重新啟動 iPhone 的定位服務。

**Q: iOS 17 以上連線失敗？**  
A: 確認已開啟「開發者模式」，並在 Xcode 或 Finder 中信任過此裝置。

---

## 注意事項 / Disclaimer

本工具僅供開發測試、隱私保護等合法用途。請勿用於欺詐、遊戲作弊或任何違反服務條款的行為。使用者須自行承擔相關法律責任。

This tool is intended for legitimate use cases such as development testing and privacy protection. Do not use it for fraud, game cheating, or any activity that violates terms of service. Users are solely responsible for their actions.

---

## 授權 / License

MIT License — 詳見 [LICENSE](LICENSE)
