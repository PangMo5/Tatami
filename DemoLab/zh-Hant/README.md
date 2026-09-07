<!-- LANGUAGE-LINKS:START -->
[English](../README.md) · [한국어](../ko/README.md) · [日本語](../ja/README.md) · [简体中文](../zh-Hans/README.md) · [繁體中文](README.md)
<!-- LANGUAGE-LINKS:END -->

<a id="tatami-demo-lab"></a>
# Tatami Demo Lab

錄製實際的 Tatami，輸出一致的產品影片並放在對應功能說明旁。App 與內容為示範資料，工作空間切換、並排、借用與焦點由已安裝的 Tatami 實際執行。

<a id="publication-contract"></a>
## 發布約定

[`publication.json`](../publication.json) 定義影片清單與編輯預算，對應網站區塊並限制時間和檔案大小。

主影片依序展示設計、撰寫、審閱、借用、自動化，最後實際改變顯示器拓樸。專題涵蓋工作空間、設定組合與顯示器、並排與焦點、借用、視窗模式、CLI/Hook 和引導設定。清單由 `publication.json` 產生，不必維護重複清單。

主影片傳達**切換工作，保留工作位置**。專題展示不同活動，不重複主影片。完整範圍見[涵蓋與證據界線](../docs/zh-Hant/COVERAGE.md)。

<a id="capture--export--review--install-locally"></a>
## 錄製 → 輸出 → 檢查 → 本機安裝

使用專用 Tart VM。`reset` 與 `seed` 會結束其執行機器上的 Tatami 並變更偏好。設定與排列隔離在 `.build/lab/`，偏好網域另行備份，可透過 `democtl restore` 還原。

```sh
# Host: run from the repository root.
swift build --package-path Tools -c release
TOOL=Tools/.build/release/tatami-tools
"$TOOL" vm-sync

# Guest: a fresh seed for every scene. Existing takes are never overwritten.
tart exec tatami-demo /Users/admin/DemoLab/.build/tools/tatami-tools capture \
  --root /Users/admin/DemoLab --output /Users/admin/DemoLab/recordings/publish

# Host: fetch that exact batch, including originals, metadata and scene snapshots.
GUEST_DIR=DemoLab/recordings/publish "$TOOL" vm-fetch-recordings DemoLab/recordings/publish

# Host: new output directory; no ambiguous “latest take” selection.
"$TOOL" export --takes DemoLab/recordings/publish --output ~/Downloads/TatamiDemoLab-review

# Open index.html and inspect playback, opening frames, actions and every feature.
# Install the verified bundle into this checkout only; this does not push or deploy.
"$TOOL" install-assets ~/Downloads/TatamiDemoLab-review
```

主機需要 Swift 6.2 或更新版本、`tart`、支援 libass/libx264 的 `mpv`、`ffmpeg` 和 `ffprobe`。主機指令請在儲存庫根目錄執行。虛擬機需要 Xcode Command Line Tools。同步原始碼時會一併傳入編譯好的自動化程式，因此虛擬機不需要下載套件。錄製工具仍是獨立的 SwiftPM 套件，不加入 Tatami 的 Tuist 建置圖。

自動化使用 `swift-subprocess`、ArgumentParser、SwiftSoup、Hummingbird、`swift-markdown`、`swift-cmark` 和 Swift Crypto。JSON 與屬性列表由 Foundation 處理。錄製驗收條件、翻譯單元，以及影片長度與大小限制仍由 Tatami 的專屬規則決定。`Tools/Package.resolved` 固定相依套件版本。

匯出主機也需要 Fontconfig。編碼前會驗證指定字型及其對全部字幕字元的支援。OCR 檢查會另外比對畫面上的字幕與說明時間軸。

<a id="a-small-set-of-useful-apps"></a>
## 實用的示範 App

|工作空間|App|實際操作|
| --- | --- | --- |
|Design|Canvas + Docs|變更配色、檢查儲存的草稿並輸出 PNG。|
|Write|Editor + Docs|閱讀說明、編輯標題並儲存草稿。|
|Review|Review + Docs|檢查儲存的文案、留言並核准。|
|Chat|Chat|輸入並傳送本機示範回覆。|
|Build|Terminal|執行實際 Tatami CLI 與附帶自動化指令稿。|
|Notes（僅借用）|Notes|新增待辦並完成檢查項。|
|Focus|Canvas + Notes|在工作空間內使用置頂便箋。|
|共用 App|Monitor|觀察儲存的專案狀態或實際工作空間、HUD Hook 事件。|

八個 App 使用持久化本機資料。儲存會改變 Review、Canvas 讀取的內容，PNG 輸出實際寫入圖片，筆記和訊息在切換後保留。Terminal 只執行明確允許的指令與附帶指令稿；Hook 接收實際 Tatami 環境。不連接聊天服務，AI 示範使用明確標記的本機範例。

<a id="what-changed-in-the-capture-contract"></a>
## 錄製約定的改進

場景分為兩個階段：

- `setup` 在**錄製前**完成清理、啟動、工作空間預備、資料與排列準備。
- `steps` 是可見示範。錄製前 `openingApps` 必須有幾何穩定的可見視窗；`autoopen` 是刻意的例外，短暫空白畫面用來展示自動開啟。

錄製前及每個操作前後檢查系統權限與設定視窗，包含被其他視窗遮住的對話框。應解決要求，不能裁掉或壓制錯誤。

**錄製器權限不等於 Tatami 權限。** 以前即使通過 `doctor`，仍殘留 Tatami 螢幕錄製要求。置頂使用獨立 ScreenCaptureKit 串流，單獨預備錄製器不能驗證它。先執行 `shared` 並檢查實際狀態視窗。Monitor 不再每個場景自動開啟，而由 `shared` 在錄製前明確啟動。

`waitWindows` 等待指定 App 和穩定幾何。`saveLayout`/`assertLayout` 在切換、歸還與放大還原後比較相同視窗 ID 與邊界；缺少、增加視窗或超過 4 點的位移都會失敗。

`key`、`hold` 依實際輸入產生按鍵顯示，不能用 `keys` 標籤把 CLI 操作偽裝成按鍵。沒有首個編碼影格就拒絕啟動，並共用其單調時間戳記以對齊字幕與影片時鐘。

<a id="presentation"></a>
## 畫面呈現

原始 MOV 包含完整的桌面畫面。匯出保留 1920×1200 解析度，雙螢幕影片為 1920×600。說明字幕疊加在畫面下方，章節名稱位於左上角，實際按鍵位於右上角。半透明背景確保文字在深淺色 App 上都清楚可讀。顏色來自網站配色，調整呈現方式不必重新錄製。

只修改字幕時，必須確保錄製的操作、輸入內容、驗證條件及等待時間皆未變更，才能重用原始影片。匯出工具會驗證錄製時固定的場景雜湊並比較操作，再替換原時間軸上的說明文字。驗證資料同時保留原始及編輯後的場景與時間軸。

每次錄製包含：

- `.mov`：乾淨的原始錄影。
- `.ass`：可編輯說明與實際按鍵時間。
- `.timeline.json`：所有事件及起訖時間。
- `.take.json`：成敗、場景雜湊、Tatami 版本、語言、逐輸出影格數與遺失數、擷取時基及疊加模式。
- `.scene.json`：錄製開始時凍結的確切場景位元組。

失敗的錄製會保留供診斷使用，但不能匯出。匯出要求拍攝條件驗證通過、字幕正常、掉幀率低於 1%、開場字幕及時出現，且影片與時間軸長度一致。輸出必須符合長度及容量限制，使用 H.264/yuv420p，並通過 FFmpeg 完整解碼。`faststart` 會將 MP4 標頭放在媒體資料之前。

匯出套件包含播放圖庫、海報、抽樣驗證畫格、原始與輸出檔案的雜湊，以及所有附屬檔案。自動驗收不能取代觀看實際操作，尤其是共用視窗鏡像及焦點目標仍須目視確認。網頁播放器使用原生控制項和 `preload="none"`，由使用者主動播放，且一次只播放一部影片。每個影片集提供縮圖清單、數量及前後按鈕。每部影片也連結至相關設定鍵。方向鍵、Home/End 及個別影片連結，不必展開額外面板即可使用。

雙螢幕錄製連接實際的虛擬顯示器，分別擷取並依首影格時間對齊。見[已驗證 VM 設定](../docs/zh-Hant/MULTI-DISPLAY.md)。

<a id="work-on-one-scene"></a>
## 調整單一場景

在專用虛擬機內執行錄製指令：

```sh
.build/DemoLab/bin/democtl doctor
.build/DemoLab/bin/democtl reset
.build/DemoLab/bin/democtl seed
.build/DemoLab/bin/democtl scene tour --dry-run    # prints setup and visible steps
.build/DemoLab/bin/democtl take tour --output recordings/iteration/tour.mov
# Host: after fetching that batch; run from the repository root.
Tools/.build/release/tatami-tools export --takes DemoLab/recordings/iteration \
  --output ~/Downloads/TatamiDemoLab-iteration --scenes tour
```

`democtl scene` 使用即時疊加排練。錄製 `take` 預設 `--overlay off`，發布只接受該模式；排練面板不是輸出設計。`subtitle burn` 可產生觀看副本，預算檢查、網頁編碼與證據應使用 `tatami-tools export`。

結束後在虛擬機執行 `democtl quit` 與 `democtl restore`，主機原有偏好與 Tatami 不參與此流程。

<a id="development-and-reference"></a>
## 開發與參考

```sh
swift test --package-path Tools
swift run --package-path Tools tatami-tools bundle-apps
DEMOLAB_LOCALIZATION_DIR="$PWD/DemoLab/.build/DemoLab/Localization" \
  swift test --package-path DemoLab
```

- [場景語法](../docs/zh-Hant/SCENES.md)
- [VM 設定](../docs/zh-Hant/VM-TART.md)
- [權限](../docs/zh-Hant/PERMISSIONS.md)
- [實際多顯示器錄製](../docs/zh-Hant/MULTI-DISPLAY.md)

<a id="five-language-production"></a>
## 五語言製作

支援 `en`、`ko`、`ja`、`zh-Hans`、`zh-Hant`。`Localization/Localizable.xcstrings` 管理示範 UI 與初始內容，`Localization/Films.json` 管理影片標題、說明和輸入，`Localization/Interface.json` 管理檢查圖庫。沒有穩定識別碼時使用產品目錄的 Tatami AX 標籤。App、使用者命名的工作空間與設定組合名稱保持不變。

```sh
Tools/.build/release/tatami-tools localize-scenes
Tools/.build/release/tatami-tools vm-sync
# Inside the guest:
.build/tools/tatami-tools capture --locale ko --output recordings/ko-batch
# After fetching that explicit batch to the host:
Tools/.build/release/tatami-tools export --locale ko --takes DemoLab/recordings/ko-batch --output ~/Downloads/Tatami-ko
```

每次錄製同步設定示範 App 與 Tatami 的語言，輸入和斷言使用相同文案，實際 CLI 指令及機器輸出不變。最終影片為 30 fps，因此錄製也使用 30 fps，避免不必要的 60 fps 取樣。

`tatami-tools record-locales` 會找出各語言缺少或未通過驗證的錄製。它不會將英文影片視為已驗證翻譯 UI 的證據。失敗場景會保留供診斷使用，其他語言可以獨立繼續。

小工具視窗從右下角開始，主影片以實際動作移到左下角。調整場景時保持文件主要閱讀區域清楚。

若要在終端機指令結束後繼續執行本機網站預覽，請在儲存庫根目錄執行 `Tools/.build/release/tatami-tools preview-site --background`。
