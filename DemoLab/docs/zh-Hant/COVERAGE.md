<!-- LANGUAGE-LINKS:START -->
[English](../COVERAGE.md) · [한국어](../ko/COVERAGE.md) · [日本語](../ja/COVERAGE.md) · [简体中文](../zh-Hans/COVERAGE.md) · [繁體中文](COVERAGE.md)
<!-- LANGUAGE-LINKS:END -->

<a id="demo-coverage-and-verification"></a>
# 示範涵蓋與驗證

發布清單包含 27 個場景：1 個完整工作流程及 26 個功能示範。每種語言都有對應的 App 語言、示範內容、輸入、字幕及拍攝驗證條件。通過驗證的錄製依語言、拍攝操作及品質篩選，再分別匯出。

<a id="captured-coverage"></a>
## 錄製涵蓋

|影片集|影片數|展示行為|
| --- | --- | --- |
|工作空間|3|直接、最近、順序切換，自動開啟與重開，App 成員移動。|
|設定組合與顯示器|5|設定組合切換、GUI 複製設定組合、選擇性複製工作空間、雙螢幕工作空間鏈、跨螢幕焦點、連接與中斷時自動切換設定組合。|
|並排與焦點|7|新增與關閉視窗、交換位置、分割方向、調整大小與平衡、拖曳、工作空間放大、方向焦點、MFF/FFM、長按與輕按視窗切換器、原生視覺化排列編輯器。|
|借用|3|並排對話、保留內容的暫存區、邊緣選擇、跨區焦點、完整啟用與歸還。|
|視窗模式|3|逐工作空間與共用置頂、可互動鏡像、維持原狀及參與切換器。|
|自動化|3|實際 CLI 輸出、多指令專注指令稿、生命週期與 HUD Hook、不可分割編輯 TOML 和即時重新載入。|
|引導設定|2|內建手勢預覽與實際鍵盤練習，驗證範例 AI 建議並套用到草稿。|

主影片把設計配色、實際 PNG 輸出、撰寫儲存、審閱核准、借用、共用狀態、CLI 自動化與顯示器相關組合切換串成一項工作。八個命名 App 是可操作的本機示範；視窗由 Tatami 管理，Hook 和 CLI 輸出來自實際程序。

<a id="evidence-and-acceptance"></a>
## 證據與驗收

驗收的錄製必須通過實際操作、狀態及排列驗證，與目前語言的拍攝操作及時間一致，且掉幀率低於 1%。只修改文字時會保留原場景雜湊，並新增編輯後的場景雜湊。匯出會檢查完整 MP4、H.264/yuv420p、長度及容量限制、首條字幕時間，以及影片與時間軸的共同時間基準。

`evidence/` 儲存凍結場景、錄製中繼資料、字幕、時間、抽樣影格、OCR 與瀏覽器結果。特定批次的數量與檢查狀態應以對應報告為準，不能把舊報告用於新語言或新錄製。

顏色來自網站深色調色盤，字型依語言選擇。媒體 URL 包含輸出雜湊，防止新舊影片與海報混用。

<a id="boundaries-and-an-unresolved-reproduction"></a>
## 界線與未解決問題

- **原生 macOS 全螢幕還原：** 離開後 Canvas 和 Docs 都保持整個工作空間邊界，原因未定位。`scenes/native-fullscreen.json` 與失敗的 `recordings/v4-edge1/fullscreen*` 保留重現，已從發布中排除。`fullscreen` 展示通過驗證的 Tatami 工作空間放大與還原。
- **實體手勢：** 使用導覽預覽按鈕與實際鍵盤，不宣稱 VM 驗證了實體三指、四指辨識。
- **AI：** 使用標記的本機範例，不要求外部 AI。錄製後確認實際 TOML 仍保留原有工作空間名稱，範例只套用到草稿。
- **多顯示器：** 實際列舉、管理並獨立錄製兩個 CoreGraphics 螢幕，再依時間戳記對齊。不代表驗證實體擴充座、混合 DPI、HDR 或線材。私有工具僅在 Demo Lab，新系統需重新驗證。
- **涵蓋：** 包含上述主要互動，不是所有偏好、語言、更新流程或硬體組合的完整 QA。

<a id="capture-defects-corrected"></a>
## 已修正的錄製問題

驅動保留方向鍵的數字鍵盤與功能鍵識別，同一快速鍵 A/B 檢查確認缺少中繼資料，[Apple 文件](https://developer.apple.com/documentation/appkit/nsevent/modifierflags-swift.struct/numericpad)說明其身分。點按前捲動到可見控制項，被遮視窗用實際切換器選擇；同步與取回使用唯一封存檔並驗證兩端雜湊。

舊文件聲稱 macOS VM 無法擁有第二顯示器，這是錯誤的。實際 API 見 [DeskPad 介面](https://github.com/Stengo/DeskPad/blob/main/DeskPad/CGVirtualDisplayPrivate.h)，設定與重現見 [MULTI-DISPLAY.md](MULTI-DISPLAY.md)。
