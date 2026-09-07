<!-- LANGUAGE-LINKS:START -->
[English](../PERMISSIONS.md) · [한국어](../ko/PERMISSIONS.md) · [日本語](../ja/PERMISSIONS.md) · [简体中文](../zh-Hans/PERMISSIONS.md) · [繁體中文](PERMISSIONS.md)
<!-- LANGUAGE-LINKS:END -->

<a id="capture-permissions"></a>
# 錄製權限

透過實際錄製啟動路徑檢查權限。錄製器預檢通過，不代表 Tatami 可以並排或鏡像視窗。

|程序|用途|證據|
| --- | --- | --- |
|Tatami|輔助使用：移動與聚焦實際視窗|可見工作空間變化與排列斷言|
|Tatami|螢幕錄製：置頂鏡像|共用狀態視窗在放大視窗上方仍可見|
|democtl / 啟動器|輔助使用：鍵盤、游標、原生控制項|實際輸入與控制項值斷言|
|DemoRecorder / 啟動器|螢幕錄製：擷取顯示器|首個編碼影格、完成的影片與解碼驗證|

在**專用錄製 VM**的系統設定 → 隱私權與安全性中授予缺少的權限。重新啟動相關程序，再執行 `democtl doctor` 和短片檢查，不修改主機權限或個人 Tatami 設定。

`record start` 在呼叫者已有擷取權限時直接啟動，否則使用 LaunchServices。目前 `tart exec` 透過預先授權代理程式執行；這是該映像與啟動路徑的實測結果，不代表所有 VM 或重建的執行檔。

<a id="a-window-can-outlive-the-process-that-requested-it"></a>
## 要求程序結束後，對話框仍可能保留

舊主影片殘留要求 **Tatami** 權限的 `Screen Recording` 對話框。它被視窗遮住，關閉後才出現，舊預檢只檢查錄製器而漏檢；這不是定期錄製提醒的證據。

即使被其他 App 遮擋，權限或設定視窗也會被拒絕。先在 VM 中解決再重試。關閉舊要求不等於授予權限；確實缺少授權時，應在系統設定中授予並驗證相關行為。

`democtl record warmup` 只測試錄製器，Tatami 獨立的擷取路徑還需排練 `shared`。不能裁掉權限介面或把未驗證錄製標為成功。

<a id="repeatable-recording-image"></a>
## 可重複使用的錄製映像

建置確切的工具與 App，解決權限並驗證工作後保存映像。重建或變更啟動器可能改變權限歸屬，應重新驗證，不能拷貝資料庫列或假定舊授權有效。直接修改 TCC 資料庫的舊指令稿已移除。
