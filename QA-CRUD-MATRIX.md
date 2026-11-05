# 全 App CRUD 驗收矩陣

狀態：QA 盤點完成；以下來源分析不是執行通過證據。DEV 編號以連線／GPS 章節為準；其餘章節的 DEV 案例為交叉索引。所有案例必須附執行證據才可結案。

契約釐清：使用者同意按「連線／新增」時自動探索並逐台加入，沒有要求另外的裝置選擇器；因此 agent 的 select 工作流描述不構成新增需求。重啟必須清空 UDID／手動 RSD 欄位，覆蓋下列歷史持久化期待。DEV-09 中斷一台後，只要其他台仍連線即保持可用；不得以湊滿三台為就緒條件。SET-03 waypoint reorder 已納入現有多點路線操作驗收。以下 source-only／candidate 都不是通過證據，實際結果另記。

重試上限更新：使用者已將每個驗收項最多修改後重試由三次上調為五次；既有次數保留。KML GUI CRUD 與多點 GUI 截至 11:49 各已執行第四次，剩一次，不因 selector 失敗重設計數。

第五次 GUI 重試（11:53）仍失敗，已達使用者核准上限，停止修改與執行。KML：`Native Go to Folder sheet must be accessible`；多點：座標欄位未在五秒內回讀 `25,121`。命令 exit 65，2 失敗、0 跳過。證據：`/tmp/paperclip-crud-build/Logs/Test/Test-O.Paperclip-2026.10.28_11-52-46-+0800.xcresult`。這是 UI 自動化輸入／原生面板路徑未完成的證據，不能直接判定 KML parser 或 GPS 產品邏輯失敗，也不能宣稱案例通過。

使用者另行授權根因診斷與可解問題修復後，13:08 控制 UI 測試鍵盤配置為 ASCII（測後恢復原輸入法），兩項 GUI 案例全程通過、exit 0：`testKMLNamingCancelImportUpdateDeleteAndRelaunch`、`testModeSwitchWaypointReorderRemovalAndClosedLoop`。證據 `/tmp/paperclip-crud-build/Logs/Test/Test-O.Paperclip-2026.10.28_13-08-34-+0800.xcresult`。先前輸入事件檔有 ⌘V／⌘⇧G，影片欄位已聚焦但事件無效果，當時使用注音；此控制實驗支持測試輸入環境問題，不表示所有輸入法或 App GUI 皆已全面驗證。完整套件仍需重跑。

## 執行證據（持續更新，非結案）

### 非 root 遷移分支地圖修正（2026-11-05）

- `LiveMapQAUITests.testImportedOverlayToggleCategoryFocusAndRestoredAnnotationPositions` 完整通過，未刪除開關／分類／平移／縮放／重啟後兩點位置斷言；證據 `/tmp/paperclip-map-final-regression.xcresult`，exit 0。
- 自動化平移改用 macOS 滑鼠 `click(forDuration:thenDragTo:)`；原觸控 `press` 未送達原生地圖拖曳事件。圖層圓點使用實際 SwiftUI accessibility identifier，避免 MapKit 快取的點名節點。
- 獨立原生 Map 重現：尺寸 `579×418 → 1079×788` 使相機距離 `4400 → 8294.74`；尺寸 identity 後保持 `4400`。產品保存原生相機並在地圖尺寸變更時重建 Map，已由上述重啟點位斷言驗證。
- pinned Python runtime 的 worker 測試 30 項通過；Release build、deep/strict codesign 驗證與 bundled worker byte comparison exit 0。既有 AppViewModel Sendable warning 仍存在。
- 完整 `prepare.py` 驗收依 GUI 排他協調中止，不能作為全套通過證據；新 Release GUI smoke 與真機 GPS 驗收仍未完成。已讓出 GUI 給 `fix-right-panel`；本分支未合併、未安裝至 `/Applications`。

### 右側欄回歸修復（2026-11-02）

- 安裝 gate（2026-11-05）：fork 版號 `1.1.1 (123)`。模型／流程 27 項於 `/tmp/paperclip-v1.1.1-install-gate.xcresult` 全通過；該輪 UI 同 bundle ID 與 admin 工作樹並行，整體 29 通過／1 失敗。協調 GUI 排他後，原生面板 helper 採直接 `open-panel` 快捷鍵、ASCII 鍵盤與貼上值回讀，撤掉未驗證的 suggestion 點擊／DownArrow；保留系統逐次授權，未修改持久安全政策。三項 UI 最終全通過／0 失敗／0 跳過，`/tmp/paperclip-v1.1.1-authorized-ui.xcresult`，exit 0。這是相關 30 項分批通過，不是完整套件或真機 GPS 驗收。安裝前原版已備份至 `~/Library/Application Support/O.Paperclip Backups/O.Paperclip-1.2.1-122-before-right-panel.zip`，壓縮完整性驗證通過。

- 閉圈補充修正：`isClosedLoop` 原本使就緒 GPX 草稿失效並走道路重算。精確匯入／收藏草稿現在直接補上末點→起點直線、重算 polyline／累積距離／總距離；關閉還原原軌跡，已閉合軌跡不重複補點。一般道路草稿沿用原本計算流程。
- 新增 `WorkflowQATests.importedGPXLoopIncludesReturnSegmentWhenActivated`：開放 GPX→閉圈→關閉→重新閉圈→啟動，檢查回程位置、跨圈連續性與零道路請求。修正前 suite-level 實跑失敗 `/tmp/paperclip-gpx-loop-red-workflow.xcresult`；修正後相關 20 項全通過／0 跳過 `/tmp/paperclip-gpx-loop-green.xcresult`。
- 真實 GPX UI 現在另外切換閉圈開／關並確認維持準備就緒及收藏類型更新，再完成原匯入儲存重啟套用流程；1 項通過、exit 0，`/tmp/paperclip-gpx-loop-ui.xcresult`。Release 已重建。單一 Swift Testing 方法選擇器曾產生 0 tests，已改 suite-level 執行，未當作成功證據。
- 歷史釐清：原作者 4/11 還原 `main` 早於 4/12 `develop` v1.2 新增右欄，沒有作者刻意停用右欄的證據。上游 issue #3 與 v1.1 release 明確回退的是 v1.06 連線 helper 架構，而非右欄；本 fork 未同步後續 `develop` 功能。

- 已下載並開啟 fork 最新 release v1.1.0（build 2），SHA-256 與 release metadata 一致；實際確認只有左欄與地圖。原安裝版 1.2.1（build 122）有右欄；原上游 `agocia/O.Paperclip` 的 `dc10107` 可恢復對應來源。多裝置分支以還原過的 v1.04 基底合併，未帶入 v1.2.1 右欄／GPX／收藏，並非視窗寬度隱藏。
- 修正保留 `DeviceGroup`、既有三種操作模式及流程保護；恢復右欄、KML／GPX、收藏與原 v1.2.1 快照格式。GPX 原始幾何直接載入多點就緒草稿，不重新規劃道路。
- 修正前 UI 回歸確實失敗：`/tmp/paperclip-right-panel-red-ui.xcresult`，斷言「多裝置版本仍須呈現右側匯入與收藏欄」。
- 模型／流程 26 項全通過：`ImportedAndSavedLocationTests` 6、`WorkflowQATests` 11、`ConnectionCRUDTests` 7、`CrossFeatureQATests` 2；證據 `/tmp/paperclip-right-panel-accepted.xcresult`。同輪 UI 兩項因原生面板不在欄位檢視而失敗，該輪整體為 27 通過／2 失敗／0 跳過，不當作全部通過。
- 修正測試 helper 對 `ColumnView` 的假設後，三項真實 UI 全通過／0 失敗／0 跳過，exit 0：KML 命名取消匯入更新刪除重啟、GPX 匯入使用儲存重啟套用刪除、三裝置欄位與三模式下右欄位置及收合重啟。證據 `/tmp/paperclip-right-panel-ui-accepted.xcresult`。
- Release build 成功，ad-hoc 簽章驗證成功；實際開啟並以系統視窗 API 設為 1400／1050 寬度，三欄皆可見，原有三筆收藏正常載入。XCTest runner 的直接 AX resize 缺權限，邊緣拖曳亦未改變尺寸，故縮放是人工／系統 API smoke 證據，不宣稱自動化 resize 通過。
- 本輪不是完整套件或實機 GPS 驗收。三裝置保留案例使用既有 Python process endpoint，不宣稱三台實體 iPhone 驗證。仍觀察既有 QoS priority-inversion runtime warnings，未在此範圍修復。


### 最新根因與證據（16:07，尚未結案）

- KML／多點原失敗：ASCII 鍵盤控制後真實 GUI 兩案例通過；checkbox 原 String cast 亦已改為 NSNumber，未放寬產品預期。
- 速度 GUI：輸入 `999` 已送達，但 helper 在 Return 前等待正規化 `300.0`，阻止提交；分開輸入回讀與提交後斷言後通過。
- 遠端 KML：新增真實 HTTP fixture 原本 port=0／runner 無 network.server entitlement／重複 bind 設定；修正測試前提後，approval/cancel/error/recovery 真實 HTTP 案例通過。診斷路徑原誤用 runner sandbox，改 account home 後 Finder／正常與異常重啟案例通過。
- 14:02 完整套件 56 項、0 失敗、0 跳過、exit 0，證據 `/tmp/paperclip-multidevice-build/Logs/Test/Test-O.Paperclip-2026.10.28_14-02-10-+0800.xcresult`；此證據早於後續非阻塞匯入／地圖修正，不能作為目前全部程式的完整通過證據。
- 後續發現產品 main-thread 遠端 KML 阻塞，改背景 preview/finalize 與 generation guard；pending HTTP 期間 UI 可操作、取消後無舊 sheet／overlay 的測試已通過（14:36 組合測試中三項 QAIntegration 全通過）。CrossFeature 模型整合與 engine 邊界測試亦已通過。
- Live MapKit 獨立探針回傳10建議；子 View 未直接讀 dependencyVersion，加入實際 observation 依賴後 15:59 live search／選取／pan／zoom／relaunch GUI 案例通過。
- 使用者相機持久化修正：onMapCameraChange(.onEnd) 保存 context region，避免依賴可能無 region 的 camera binding。
- 未解：Overlay 類別/filter/focus 流程後的 pan，16:05 第五次測試仍未觀察 persisted center 改變，exit 65。等待 focus 完成已通過，不能再聲稱只因動畫；也不能無證據斷定是 MapKit 或自動化輸入。已達五次上限停止。結果 `/tmp/paperclip-crud-build/Logs/Test/Test-O.Paperclip-2026.10.28_16-05-24-+0800.xcresult`。
- 實機前提：最新 usbmux 為 `[]`、devicectl 實機 unavailable；單台 GPS 回讀／最後實機重啟尚缺，不以 Simulator 替代。未重建交付目前 dist 版本為已驗收產物。

- `ConnectionCRUDTests` 七項通過（03:45）：重啟空白、單台成功、一次探索逐台連線、新增不重建、過期 ID、第四台上限、延遲 tunnel 取消與重試。
- `WorkflowQATests`／`OverlayQATests` 整合 24 項通過（03:33）；僅模型／服務證據，不能替代下列 GUI／實機案例。
- 實機 iPad（USB）已觀察 `已連線 1/3 台`、DVT/RSD 成功，單台中斷後欄位清空；尚未取得實機 Core Location GPS 位置回讀證據。
- 03:50 完整驗收：54 項、50 通過、4 失敗、0 跳過，exit 65。失敗為座標 Return/button、無效座標 GUI、KML GUI CRUD、多點 GUI。不能結案。
- iOS 27.1 PosterBoard 在本輪再次崩潰，停止該 runtime；改官方 iOS 27.0 重跑，未宣稱修復 Apple runtime。
- 尚缺 GUI naming／approval／Finder／重啟、live MapKit、實機 GPS 與跨功能案例的完整證據；不以候選測試或 source-only 盤點當成通過。

## 連線與 GPS QA agent

## Summary

The app supports three device slots, but its connection controls do **not** implement the requested explicit discovery → select → connect/add flow: clicking connect discovers identifiers and automatically assigns and connects devices. It also persists each slot’s UDID in `UserDefaults`, so fresh-start and stale-UDID behavior need real-device coverage.

GPS simulation supports fixed point, A–B, and multi-point routes, with speed settings, single-pass, ping-pong, and closed-loop behavior. Automated evidence covers simulated three-device connection, individual/all disconnect, location forwarding, and one route stop/pin case. It does not establish full GUI CRUD, route-mode journeys, or physical-device behavior.

## Files

- `O.Paperclip/Services/Device/DeviceGroup.swift:13-25` — Identifier assignment; rejects duplicate requested IDs and fills empty slots from discovered IDs.
- `O.Paperclip/Services/Device/DeviceGroup.swift:30-49` — Exactly three slots; group connection state is based on all assigned slots being connected.
- `O.Paperclip/Services/Device/DeviceGroup.swift:75-108` — Discovery, automatic assignment/connection, timeout/error handling, and group disconnect.
- `O.Paperclip/Services/Device/DeviceGroup.swift:109-142` — Group location stream, sync/async connection, disconnect, send, and clear operations.
- `O.Paperclip/Services/Device/DeviceManager.swift:493-494, 554-580` — Per-slot UDID persistence and initialization from `UserDefaults`.
- `O.Paperclip/Services/Device/DeviceManager.swift:588-620, 625-710` — Device discovery and connection attempts, including preferred UDID tunnel setup and fallback behavior.
- `O.Paperclip/Services/Device/DeviceManager.swift:1586-1589` — Auto-reconnect scheduling.
- `O.Paperclip/AppViewModel.swift:36-88` — Draft and active route state, speed, loop settings, running and reconnect flags.
- `O.Paperclip/AppViewModel.swift:400-520` — Main-action transitions, reset, draft activation, fixed-point behavior, and route replacement confirmation.
- `O.Paperclip/AppViewModel.swift:585-669` — Sequential multi-point segment routing; closed loop appends the first waypoint.
- `O.Paperclip/AppViewModel.swift:672-831` — Simulation start, route loop modes, coordinate updates, pause/stop pinning, and keep-alive.
- `O.Paperclip/AppViewModel.swift:832-879` — Reconnect resume behavior and draft clearing.
- `O.Paperclip/UI/Controls/MovementSettingsSectionView.swift:6-57` — Speed, ping-pong toggle, multi-point loop settings, and waypoint removal control.
- `O.Paperclip/UI/Sidebar/DeviceStatusSectionView.swift:20-27` — Connect/disconnect button behavior.
- `O.PaperclipTests/DeviceGroupTests.swift:12-17` — Duplicate assignment rejection test.
- `O.PaperclipTests/DeviceGroupTests.swift:20-28` — Stop-stream coverage for three injected stream instances.
- `O.PaperclipTests/DeviceGroupTests.swift:36-69` — Simulated USB/Wi-Fi connection, location clear, individual disconnect, and group disconnect.
- `O.PaperclipTests/DeviceGroupTests.swift:77-120` — Simulated location forwarding and route stop/pin evidence.
- `O.PaperclipTests/O_PaperclipTests.swift:394-460` — A–B and multi-point route-failure recovery tests.
- `O.Paperclip/Core/Models/Types.swift:3-8` — The three operation modes.
- `README.en.md:89-105` — User-described route modes and A–B workflow; documentation is not evidence that the UI journey works.

## Architecture

`DeviceGroup` owns three `DeviceManager` instances and fans location/stream operations out to them. Group connect invokes discovery on slot 1, assigns returned identifiers across slots, then starts connections for assigned slots. `AppViewModel` owns draft and active route state, calculates route geometry, and sends simulation coordinates through the `DeviceControlling` interface. The UI exposes mode and movement settings, while tests use simulated devices and route calculators.

## QA matrix

Automated evidence below refers to existing tests and source, not checks run for this investigation. “Real-device required” means the deterministic result depends on physical discovery, tunnel, location, or app lifecycle behavior that simulator/test evidence does not establish.

### Device connection CRUD and lifecycle

| ID | Preconditions | Actions | Deterministic expected result | Evidence |
|---|---|---|---|---|
| DEV-01 | App freshly installed; no device configured | Open connection UI without connecting | No device is connected; UI shows disconnected/empty state | **Real-device/manual.** Slot construction and persisted defaults: `DeviceGroup.swift:30-32`, `DeviceManager.swift:578-580`. |
| DEV-02 | One supported device attached; group disconnected | Trigger connect | Discover the device, assign it, establish its tunnel, and show connected | **Partial automated** simulated connection in `DeviceGroupTests.swift:36-69`; actual discovery and tunnel need real device. |
| DEV-03 | Three supported devices available | Trigger connect once | At most three unique devices assigned; all successfully assigned devices connect | **Partial automated** three-slot test in `DeviceGroupTests.swift:36-69`; no GUI selection evidence. |
| DEV-04 | One device already connected; a second becomes available | Trigger add/connect | Existing device remains connected; only the newly selected device is added | **Gap/defect:** no explicit add or selection action is present in `DeviceGroup.swift:75-98`; connection rediscovers and automatically assigns slots. |
| DEV-05 | Three devices available; one slot manually configured, remaining slots empty | Connect | Preserve configured identifier; fill empty slots with other unique discovered identifiers | **Automated logic** duplicate/assignment behavior at `DeviceGroup.swift:13-25`; no explicit preservation/add journey test. |
| DEV-06 | Duplicate identifier requested across slots | Attempt assignment/connect | Reject duplicate; do not connect two slots to the same device | **Automated** `DeviceGroupTests.swift:12-17`; group assignment logic `DeviceGroup.swift:13-25`. |
| DEV-07 | No devices discoverable | Trigger connect | Show actionable failure; remain disconnected; no phantom connected device | **Partial source only:** assignment throws when none selected (`DeviceGroup.swift:20-25`); no no-device group test identified. |
| DEV-08 | Discovery returns more devices than available slots | Trigger connect | Connect no more than three unique devices; report excess as unassigned or otherwise clearly | **Gap:** only three slots exist and assignment maps to requested slots (`DeviceGroup.swift:30-32`, `13-25`); no overflow UI/test identified. |
| DEV-09 | Two or three devices connected | Disconnect one device | That device disconnects; other devices remain connected; group reports not fully connected | **Automated** `DeviceGroupTests.swift:63-65`. |
| DEV-10 | Multiple devices connected | Disconnect all | Every slot disconnects and all location streams stop | **Partial automated** group disconnect and individual stream-stop coverage: `DeviceGroupTests.swift:22-28, 63-68`. |
| DEV-11 | Connect is in progress | Disconnect group | In-flight discovery completion cannot reconnect devices after disconnect | **Source-backed risk:** `disconnect()` increments `connectionGeneration`, invalidating discovery callback (`DeviceGroup.swift:75-108`); connection attempts already started may continue. No explicit race test identified. |
| DEV-12 | App has previously connected using a UDID; device restarts/re-enumerates with a different identifier | Reconnect | Discover current identifier and connect the intended device, without using stale identity | **Defect risk confirmed by source:** UDID persists (`DeviceManager.swift:493-494, 578-580`) and connection uses preferred identifier (`DeviceManager.swift:658-662`). Test on physical restart; requested known stale-UDID bug. |
| DEV-13 | App terminated while connected or connecting | Relaunch | No stale “connected” state; user explicitly initiates a fresh connection | **Real-device/manual.** Persistent UDID is loaded at initialization (`DeviceManager.swift:578-580`); no lifecycle test identified. |
| DEV-14 | Device disconnects while route is moving; later reconnects | Verify pause/resume | Simulation stops on disconnect; reconnect resumes only if it had been moving, otherwise keeps the last coordinate pinned | **Partial source only:** `handleDeviceDisconnected()` and `startIfReadyAndConnected()` at `AppViewModel.swift:832-853`; no lifecycle test identified. |
| DEV-15 | Two or three physical devices connected | Send fixed coordinate | All connected devices receive the same coordinate and remain synchronized | **Automated simulated forwarding** in `DeviceGroupTests.swift:77-120`; **real-device timing/synchronization unverified**. |
| DEV-16 | Group has one failed assigned device and another connected | Inspect status / retry | Failure is visible; retry should recover without losing working connection | **Gap:** `isConnected` is all-assigned-or-false (`DeviceGroup.swift:45-49`); UI-level partial failure/retry coverage not identified. |
| DEV-17 | Connection attempt fails or exceeds deadline | Inspect connection UI | Stop showing “connecting”; surface failure and allow user retry | **Source:** failure and timeout handling in `DeviceGroup.swift:91-106`; stuck-connecting scenario remains a real-device check. |
| DEV-18 | Change USB/Wi-Fi mode, with devices connected | Apply mode | Mode change has an explicit, predictable reconnect result; no unintended surprise reconnect | **Gap/risk:** sidebar setter changes mode and immediately calls connect (`ContentView+Sidebar.swift:51-52`); connection UI behavior needs manual validation. |

### GPS route construction and settings

| ID | Preconditions | Actions | Deterministic expected result | Evidence |
|---|---|---|---|---|
| GPS-01 | Fixed-point mode; connected device | Select one coordinate, confirm, start | Device receives selected coordinate and stays there | **Source-backed** fixed-point activation and start: `AppViewModel.swift:486-501, 672-685`; real-device location evidence required. |
| GPS-02 | Fixed-point mode; no selected coordinate | Attempt start | No simulation starts and no coordinate is sent | **Source-backed** guard in `AppViewModel.swift:672-682`; no dedicated test identified. |
| GPS-03 | A–B mode; two valid coordinates | Confirm A, confirm B, choose route, start | Route is previewed, then device moves from A toward B | **Partial automated:** failure case only at `O_PaperclipTests.swift:394-414`; success and UI journey require manual coverage. |
| GPS-04 | A–B mode; route calculation fails | Confirm endpoints that produce route error | Recover to endpoint selection and display route error | **Automated** `O_PaperclipTests.swift:394-414`. |
| GPS-05 | Multi-point mode; fewer than two waypoints | Attempt calculate | Remain in selection; no route starts | **Source-backed** guard `AppViewModel.swift:585-587`; no dedicated test identified. |
| GPS-06 | Multi-point mode; at least two valid waypoints | Calculate | Route each segment in order and combine geometry without duplicate segment joins | **Partial source only:** `AppViewModel.swift:600-669`; only failure path tested (`O_PaperclipTests.swift:418-437`). |
| GPS-07 | Multi-point route; one segment fails | Calculate | Return to selection and identify failed segment | **Automated** `O_PaperclipTests.swift:418-437`. |
| GPS-08 | Multi-point selection; several waypoints | Remove last waypoint | Only final waypoint is removed; remaining order preserved | **UI/source only** `MovementSettingsSectionView.swift:63-81`; no test identified. |
| GPS-09 | Multi-point closed-loop toggle enabled before calculation | Calculate and start | Route includes final return to P1 and loops circularly | **Source-backed** route closure and loop selection `AppViewModel.swift:595-599, 699-704`; no automated behavior test identified. |
| GPS-10 | Multi-point closed loop enabled | Toggle ping-pong | Ping-pong is disabled while closed loop is active | **UI/source** `MovementSettingsSectionView.swift:40-57`; no interaction test identified. |
| GPS-11 | Open multi-point route; ping-pong enabled | Start and observe at route end | Motion reverses along route toward first waypoint | **Source-backed** loop mode selection `AppViewModel.swift:699-704`; no deterministic loop test identified. |
| GPS-12 | Route ready; ping-pong and closed loop off | Start | Route makes one pass, stops at final coordinate, and pins it | **Source-backed** `AppViewModel.swift:699-704, 739-750`; existing simulator test exercises a stop/pin path, not a full single-pass assertion (`DeviceGroupTests.swift:77-120`). |
| GPS-13 | Route ready; speed within allowed range | Set speed with slider, stepper, and text field | Movement rate reflects selected speed; out-of-range text behavior is deterministic and safely bounded | **Gap:** slider/stepper bounds visible (`MovementSettingsSectionView.swift:16-40`); text-field validation/synchronization and speed timing tests not established. |
| GPS-14 | Route moving; pause via main action | Pause | Timer stops; current position remains injected and pinned | **Source-backed** `AppViewModel.swift:442-460, 767-780`; simulator test has a stop/pin scenario (`DeviceGroupTests.swift:111-120`). |
| GPS-15 | Route paused | Resume | Movement continues from preserved traveled distance/current position | **Source-backed** `startSimulation()` does not reset `traveledDistance` (`AppViewModel.swift:672-737`); no explicit resume test identified. |
| GPS-16 | Route moving; stop/reset | Stop or clear route | Timer and keep-alive stop; location is cleared when requested; active state resets | **Source-backed** `resetAll()` / `stopSimulation()` at `AppViewModel.swift:423-440, 767-780`; dedicated full reset test not identified. |
| GPS-17 | Fixed point running | Invoke fixed-point main action | Stop fixed location, clear simulated location, clear active snapshot | **Source-backed** `AppViewModel.swift:462-477`; no dedicated test identified. |
| GPS-18 | Active route running; start a different draft route | Confirm replacement | Old route stops, new draft activates and starts | **Source-backed** confirmation flow `AppViewModel.swift:400-406, 423-440`; no replacement journey test identified. |
| GPS-19 | Active route running; draft edits present | Cancel replacement | Active route continues; draft is not activated | **Source-backed** cancellation handler `AppViewModel.swift:408-410`; no test identified. |
| GPS-20 | Active route running; switch operation mode | Switch mode and inspect GPS | Active route remains separate from new draft mode and is not silently replaced | **Source-backed** draft/active split and mode switching `AppViewModel.swift:36-88, 832-853`; cross-mode UI test absent. |
| GPS-21 | Active fixed point; switch to route mode and back | Inspect location and stop/reset behavior | Existing fixed coordinate remains pinned until explicit clear; new draft does not alter active session | **Source-backed** `pinnedCoordinate` and draft preservation (`AppViewModel.swift:101-106, 832-853`); cross-mode test absent. |
| GPS-22 | No active session; reset workflow | Clear draft/location | Draft is cleared, simulated location is cleared, no active snapshot remains | **Source-backed** `resetAll()` `AppViewModel.swift:423-432`; no full reset assertion identified. |
| GPS-23 | Active route; reset invoked | Clear draft | Draft clears while active route remains intact | **Source-backed** early return in `resetAll()` when active snapshot exists (`AppViewModel.swift:423-428`); verify UI labeling/expectation manually. |
| GPS-24 | Route moving; device disconnects | Reconnect device | Resume from current route state; do not restart from origin | **Gap/defect risk:** reconnect path calls `startSimulation()` when resume flag set (`AppViewModel.swift:842-845`); route distance is retained in source, but no integration test establishes correct resume semantics. |
| GPS-25 | A–B or multi-point route is being calculated; user changes mode or starts another calculation | Complete old calculation callback | Stale callback must not overwrite the newer mode/draft | **Potential defect:** multi-point callback captures `self` and applies results without checking a calculation generation/mode after async completion (`AppViewModel.swift:602-669`); no cancellation/stale-result test identified. |
| GPS-26 | Multi-point segment returns malformed/too-short geometry | Calculate | Return to selection with error and clear invalid preview | **Potential defect:** too-short and invalid-data branches set error/state but do not call `clearDraftGeometry()` (`AppViewModel.swift:644-656`), unlike segment-failure branch at `634-640`; stale partial preview may remain. |
| GPS-27 | Moving route reaches single-pass endpoint | Observe device and state | Stop movement, send endpoint, and remain pinned | **Potential defect:** single-pass completion calls `stopSimulation(keepPinned: true)` then sends endpoint (`AppViewModel.swift:739-750`); pinned keep-alive uses `currentPosition`, with endpoint assignment occurring afterward, creating ordering sensitivity worth testing. |
| GPS-28 | GPS simulation stopped or app lifecycle interrupted | Verify location stream on each device | Stream stops on all targeted devices; restart establishes synchronized stream | **Partial automated** stream-stop across three injected stream objects (`DeviceGroupTests.swift:20-28`); physical stream/restart behavior unverified. |

## Source-backed defects and gaps

1. **No explicit per-device discovery/select/add workflow.** `DeviceGroup.connectDevice()` discovers, assigns all available identifiers into empty slots, and initiates connection in one action (`DeviceGroup.swift:75-98`). This does not provide the requested explicit discovery and user-selected add behavior, nor demonstrate preserving connected devices while adding a chosen device.
2. **Persisted UDID can be stale across device restart/re-enumeration.** The manager loads and saves `tunnelUDID` in `UserDefaults` (`DeviceManager.swift:493-494, 578-580`) and connection uses a preferred identifier (`DeviceManager.swift:658-662`). This matches the known stale-UDID bug; physical restart/reconnect is required to establish the exact failure mode.
3. **Partial group status is coarse.** `isConnected` is false unless every assigned device is connected (`DeviceGroup.swift:45-49`), while `deviceName` reports only a connected count (`:51`). A partial connection may appear as a group-level failure without a clear per-device recovery path; inspect UI on partial failure.
4. **Async connect can report a generic failure after a stuck connection.** `connectDeviceAsync()` waits while `isConnecting`, then throws based on aggregate status/error (`DeviceGroup.swift:126-133`). The known “one phone stuck connecting” report requires device-level investigation; existing tests do not reproduce it.
5. **Multi-point malformed-segment recovery may leave stale route geometry.** The short/invalid geometry paths update error and selection state without clearing geometry, unlike the route-failure branch (`AppViewModel.swift:634-656`). Verify that stale previews do not remain selectable.
6. **Cross-mode and lifecycle behavior lack automated journey coverage.** Existing tests include route failure and simulated device location/stop behavior, but no tests were identified for successful fixed/A–B/multi-point UI journeys, speed input, loop completion, route replacement, pause/resume, or app restart. No real-device evidence establishes physical GPS synchronization or reconnection recovery.

## 其他 App 功能 QA agent

## Scope and findings

The existing app surfaces include place search and coordinate entry; map selection and camera persistence; PurePoint/KML import, remote-link approval, overlay filtering/focus/removal; route and movement controls; device connection settings/status; and diagnostics. Two apparent UI reachability gaps: `UnexpectedTerminationSectionView` has no discovered call site, and persisted manual RSD host/port settings have no discovered UI fields.

Automated evidence below means a test candidate or coverage gap based on source inspection—not a claim that tests ran. **No tests, build, or real-device checks were run.** Reported issues—one phone stuck connecting and stale UDID after restart—are included as manual cases, not independently verified.

## Finite QA matrix

| ID | Preconditions and actions | Expected result | Evidence / source | Evidence type / gap |
|---|---|---|---|---|
| LOC-01 | Enter a non-empty query; then clear it. | Suggestions appear for query; clearing removes suggestions. | `O.Paperclip/UI/Search/LocationInputSectionView.swift`; `O.Paperclip/Services/Location/LocationSearchService.swift:18-47` | Automated candidate + manual live MapKit; no search tests found. |
| LOC-02 | Choose a completion; test fixed empty, success, and thrown-error responses. | Results populate; empty response shows “not found”; failure shows search error. | `O.Paperclip/AppViewModel.swift:324-374`; `O.Paperclip/Services/Location/LocationSearchService.swift:49-70` | Automated candidate with search fake; no matching tests found. |
| LOC-03 | Submit a text query in a known region with fixture results containing duplicates and different distances. | Search uses region; results are ranked/deduplicated; UI shows no more than eight. | `O.Paperclip/Services/Location/LocationSearchService.swift:49-117`; `O.Paperclip/UI/Search/LocationInputSectionView.swift` | Automated candidate; no matching tests found. Also check whether an older in-flight query can replace newer results. |
| LOC-04 | Select a result with coordinates in A-B mode, first with A unset, then set. | First result sets A and advances to B; next sets B and calculates route; camera centers at selection. | `O.Paperclip/AppViewModel.swift:296-318`; `O.Paperclip/UI/Search/LocationInputSectionView.swift` | Automated candidate with fake route calculator; no tests found. |
| LOC-05 | Enter valid coordinate with whitespace and full-width comma; submit by button and Return. | Both paths insert the same coordinate and apply current mode transition; previous input error clears. | `O.Paperclip/UI/Search/LocationInputSectionView.swift`; `O.Paperclip/AppViewModel.swift:296-346` | Automated candidate; no tests found. |
| LOC-06 | Enter malformed separator, nonnumeric, out-of-range, NaN, and infinity values. | Invalid input shows appropriate error and leaves map/route state unchanged. | `O.Paperclip/AppViewModel.swift:296-343` | Automated candidate; no tests found. Check non-finite handling explicitly. |
| LOC-07 | Insert a valid coordinate in fixed-point and multi-point modes. | Fixed-point sets A and becomes ready; multi-point appends only while selecting A. | `O.Paperclip/AppViewModel.swift:281-322` | Automated candidate; no tests found. |
| MAP-01 | Start with empty preferences; pan/zoom; relaunch. | Map starts at defaults and restores the saved camera region after relaunch. | `O.Paperclip/ContentView.swift:9-63`; `O.Paperclip/AppViewModel.swift:933-982` | Automated defaults test + manual app relaunch; no persistence tests found. |
| MAP-02 | Seed invalid center and out-of-range spans; launch. | Invalid center falls back to default; spans clamp to configured minimum/maximum. | `O.Paperclip/ContentView.swift:39-63` | Automated candidate; no tests found. |
| MAP-03 | Tap map through A/B selection and multi-point selection; tap in non-selection state. | Taps update temporary A/B coordinate or append multi-point waypoint only in the relevant state; other states do not mutate selection. | `O.Paperclip/AppViewModel.swift:281-294` | Automated candidate; no tests found. |
| PP-01 | Import valid local KML, rename in sheet, confirm. | Overlay appears with parsed points and custom title; title/path persist. | `O.Paperclip/UI/PurePoint/ContentView+PurePoint.swift:109-159,207-241`; `O.Paperclip/Services/PurePoint/PurePointOverlaySupport.swift:38-159` | Automated parser coverage exists per `AGENTS.md`; UI/store flow is a gap. |
| PP-02 | Import multiple files, including an already-imported source; confirm. | New imports are added without removing existing ones; same source path updates rather than duplicating. | `O.Paperclip/ContentView.swift:136-140`; `O.Paperclip/UI/PurePoint/ContentView+PurePoint.swift:207-241` | Automated candidate with temp files/defaults; workflow gap. |
| PP-03 | Re-import same source with changed content and title; restart. | Current content/title replace prior import and remain after reload. | `O.Paperclip/UI/PurePoint/ContentView+PurePoint.swift:207-241`; `O.Paperclip/Services/PurePoint/PurePointOverlaySupport.swift:45-60` | Automated candidate; update/reload coverage gap. |
| PP-04 | Cancel naming sheet; begin another import. | Cancel persists nothing; next import starts with clean transient state. | `O.Paperclip/UI/PurePoint/ContentView+PurePoint.swift:162-180,243-266` | Automated/UI candidate; no flow tests found. |
| PP-05 | Import a KML with unapproved NetworkLink; cancel approval. | No remote fetch before approval; cancel abandons import and preserves existing overlays. | `O.Paperclip/Services/PurePoint/PurePointOverlaySupport.swift:62-89`; `O.Paperclip/UI/PurePoint/ContentView+PurePoint.swift:109-159,177-180,268-299` | Automated with injected fetcher; parser tests noted, approval flow not covered. |
| PP-06 | Approve listed remote links, including duplicates; finish import. | Normalized/deduplicated URLs are allowed for this import session only; linked KML is included. | `O.Paperclip/UI/PurePoint/ContentView+PurePoint.swift:145-159,182-190,268-299`; `O.Paperclip/Services/PurePoint/PurePointOverlaySupport.swift` | Automated injected-fetcher candidate + manual network check; no approval-flow tests found. |
| PP-07 | Import malformed KML or make remote fetch fail. | Error is shown; no partial overlay is committed; a subsequent import can proceed. | `O.Paperclip/UI/PurePoint/ContentView+PurePoint.swift:109-159,162-180`; `O.Paperclip/Services/PurePoint/PurePointOverlaySupport.swift:62-89` | Automated candidate; atomic failure behavior untested. |
| PP-08 | Toggle built-in and imported overlays on/off. | Disabled overlays yield no visible points; imported overlays default enabled and built-ins disabled. | `O.Paperclip/UI/PurePoint/ContentView+PurePoint.swift:5-19,31-76` | Automated candidate; state/render integration gap. |
| PP-09 | Clear categories, select all, toggle individual categories. | Visible points match selected categories; category counts match source data. | `O.Paperclip/UI/PurePoint/ContentView+PurePoint.swift:22-29,78-99`; `O.Paperclip/UI/PurePoint/PurePointOverlaySection.swift:77-139` | Automated candidate; no filter tests found. |
| PP-10 | Focus an overlay/all visible points; repeat with empty visible set. | Camera fits valid visible coordinates; empty selection disables/no-ops focus. | `O.Paperclip/UI/PurePoint/ContentView+PurePoint.swift:101-108`; `O.Paperclip/UI/PurePoint/PurePointOverlaySection.swift` | Automated candidate; no focus tests found. |
| PP-11 | Remove imported overlay; relaunch. | Snapshot, path/title registration and UI state are removed; built-ins remain. | `O.Paperclip/UI/PurePoint/ContentView+PurePoint.swift:243-266`; `O.Paperclip/Services/PurePoint/PurePointOverlaySupport.swift:45-60,122-125` | Automated temp-store candidate; delete/reload coverage gap. |
| PP-12 | Load duplicate paths and missing/corrupt snapshot. | Paths deduplicate; unreadable entries are omitted and persisted paths repaired. | `O.Paperclip/Services/PurePoint/PurePointOverlaySupport.swift:45-60,127-130` | Automated candidate; no store recovery tests found. |
| PP-13 | Render many points; pan/zoom across viewports. | Invalid points excluded; viewport filtering and render cap bound annotations; counts/notices remain consistent. | `O.Paperclip/Services/PurePoint/PurePointRenderEngine.swift:4-89`; `O.Paperclip/ContentView.swift:105-109` | Automated render candidate + manual map check; no render tests established. |
| SET-01 | Adjust speed with slider, field, stepper; submit out-of-range and malformed text. | Speed remains within configured limits; field reflects speed; invalid text does not change it. | `O.Paperclip/UI/Controls/MovementSettingsSectionView.swift:7-36`; `O.Paperclip/UI/Sidebar/ContentView+Sidebar.swift:157-162,237-245`; `O.Paperclip/Core/Constants/AppConstants.swift:13-20` | Automated candidate; no settings tests found. |
| SET-02 | Toggle endless loop; enable closed loop in multi-point mode. | Closed loop turns off endless loop; selected loop behavior matches mode/active snapshot. | `O.Paperclip/UI/Controls/MovementSettingsSectionView.swift:39-58`; `O.Paperclip/UI/Sidebar/ContentView+Sidebar.swift:164-167`; `O.Paperclip/AppViewModel.swift:698-704` | Automated candidate; no loop tests found. |
| SET-03 | Add/remove/reorder multi-point waypoints; calculate and run. | Route follows waypoint order; closed loop returns to P1; reset clears draft. | `O.Paperclip/UI/Controls/MovementSettingsSectionView.swift:43-58`; `O.Paperclip/AppViewModel.swift:281-294,590-608` | Automated view-model/engine candidate; no UI workflow coverage found. |
| SET-04 | Reset draft route, then reset active route. | Draft reset clears draft only; active reset stops simulation, clears simulated location and snapshot. | `O.Paperclip/UI/Sidebar/SidebarFooterView.swift:14-24`; `O.Paperclip/AppViewModel.swift:412-421` | Automated fake-device candidate + manual device check; no reset tests found. |
| SET-05 | Switch operation mode with a pinned/current coordinate. | Mode changes preserve the pinned location as defined by mode-switch behavior. | `O.Paperclip/UI/Sidebar/ContentView+Sidebar.swift:11-21,145-148`; `O.Paperclip/AppViewModel.swift` | Automated candidate; no mode-transition tests found. |
| SET-06 | With active route, request new route; cancel, then repeat and confirm. | Cancel preserves active route; confirm replaces it without disconnecting device. | `O.Paperclip/UI/Sidebar/ContentView+Sidebar.swift:267-298`; `O.Paperclip/AppViewModel.swift:374-421` | Automated/UI candidate; no confirmation tests found. |
| DEV-01 | Fresh launch with no assigned UDIDs; explicitly start discovery/connect. | No automatic connection attempt at startup; explicit action discovers/selects/connects devices. | `O.Paperclip/UI/Sidebar/DeviceStatusSectionView.swift:20-32`; `O.Paperclip/Services/Device/DeviceGroup.swift:1-103` | Manual startup/USB/Wi-Fi check; verify explicit-only behavior. |
| DEV-02 | Connect one, then two, then three devices sequentially. | Count advances 1/3 → 2/3 → 3/3; all receive synchronized GPS. | `O.Paperclip/UI/Sidebar/DeviceStatusSectionView.swift:12-32`; `O.Paperclip/Services/Device/DeviceGroup.swift:42-108`; `O.Paperclip/UI/Sidebar/ContentView+Sidebar.swift:85-99` | Automated group candidate + real devices; known report: one phone stuck connecting. |
| DEV-03 | Connect one device, then add/connect another. | Existing connection remains; second device joins without replacing/disconnecting first. | `O.Paperclip/Services/Device/DeviceGroup.swift:58-108` | Automated candidate + manual device check; acceptance-critical coverage gap. |
| DEV-04 | Disconnect one device while others remain; then disconnect all. | Individual disconnect affects only selected device; bulk disconnect affects all and clears location. | `O.Paperclip/UI/Sidebar/DeviceStatusSectionView.swift:20-32`; `O.Paperclip/Services/Device/DeviceGroup.swift:104-128`; `O.Paperclip/Services/Device/DeviceManager.swift:1201-1218` | Automated group candidate + manual devices; verify per-slot disconnect UI. |
| DEV-05 | Change USB/Wi-Fi mode disconnected, connected, and while connecting. | Disconnected selection persists; connected mode switch disconnects/reconnects; connecting prevents switch. | `O.Paperclip/UI/Sidebar/ContentView+Sidebar.swift:28-48`; `O.Paperclip/UI/Sidebar/DeviceStatusSectionView.swift:36-53` | Automated binding candidate + real tunnel check; no tests found. |
| DEV-06 | Restart after prior connection; inspect persisted UDID and reconnect. | Current device is rediscovered/selected; stale identity is not silently reused. | `O.Paperclip/Services/Device/DeviceManager.swift:493-495,568-580` | Manual real-device check; known stale-UDID-after-restart report. |
| DEV-07 | Drop tunnel unexpectedly; then disconnect manually. | Unexpected loss may reconnect with bounded backoff; explicit disconnect cancels reconnect and prevents restart. | `O.Paperclip/Services/Device/DeviceManager.swift:1201-1208,1453-1456,1554-1589` | Automated process/tunnel candidate + real-device check; no device-manager tests found. |
| DEV-08 | With devices connected, run route and fixed-point simulation; reset/disconnect. | All connected devices receive the same current coordinate; reset/disconnect clears simulated location. | `O.Paperclip/AppViewModel.swift:698-800`; `O.Paperclip/Services/Device/DeviceGroup.swift:109-150`; `O.Paperclip/Services/Device/DeviceManager.swift:1218-1255,1283-1318` | Automated mock-stream candidate + real-device GPS evidence; synchronized-device coverage gap. |
| DEV-09 | Configure manual RSD host/port and relaunch. | Per-device endpoint persists and is used when valid. | `O.Paperclip/Services/Device/DeviceManager.swift:487-491,568-580,719-724` | Automated endpoint candidate; **UI gap:** no host/port fields found. |
| QA-01 | Simulate prior unexpected termination; launch and locate/open diagnostics. | Notice shows reason/path and opens diagnostics folder. | `O.Paperclip/Services/Diagnostics/AppDiagnostics.swift:91-160`; `O.Paperclip/UI/Sidebar/UnexpectedTerminationSectionView.swift:1-27` | **Reachability gap:** no view callsite or use of `lastUnexpectedTermination` found; manual macOS opening not exercised. |
| QA-02 | Launch, change scene phase, shut down normally; inspect logs/incident record. | Lifecycle events persist; normal shutdown clears active marker; unexpected termination is recorded on next launch. | `O.Paperclip/Services/Diagnostics/AppDiagnostics.swift:91-220` | Automated temp-path candidate + manual relaunch/crash check; no diagnostics tests found. |
| QA-03 | Import/filter/focus overlays, move map, run/reset route, disconnect devices. | Each feature preserves unrelated state: route reset does not delete overlays; disconnect does not erase overlays/camera; overlay edits do not disconnect devices. | `O.Paperclip/UI/PurePoint/ContentView+PurePoint.swift`; `O.Paperclip/AppViewModel.swift:412-421,933-982`; `O.Paperclip/Services/Device/DeviceGroup.swift:104-150` | Automated integration candidate + manual device evidence; no cross-feature tests found. |

`AGENTS.md` describes two KML tests, while `O.PaperclipTests/DeviceGroupTests.swift` also exists; treat that note as potentially stale until test contents are reviewed.