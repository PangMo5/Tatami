<!-- LANGUAGE-LINKS:START -->
[English](../VM-TART.md) · [한국어](../ko/VM-TART.md) · [日本語](../ja/VM-TART.md) · [简体中文](../zh-Hans/VM-TART.md) · [繁體中文](VM-TART.md)
<!-- LANGUAGE-LINKS:END -->

<a id="recording-in-a-tart-vm"></a>
# 在 Tart VM 中錄製

專用 `tatami-demo` 隔離個人視窗、偏好與權限。目前使用 macOS 26.6.2、固定 1920×1200 主螢幕、實際 Tatami 和八個示範 App；第二屏來自 VM 內虛擬顯示器，見 [MULTI-DISPLAY.md](MULTI-DISPLAY.md)。

<a id="prepare-the-guest"></a>
## 準備虛擬機

主機需要 Apple 晶片、Swift 6.2 或更新版本，以及支援 `exec` 的 Tart。虛擬機需要 Tart 代理程式、Command Line Tools 和 Tatami。主機指令請在儲存庫根目錄執行，虛擬機指令則在 `~/DemoLab` 中執行。

```sh
swift build --package-path Tools -c release
Tools/.build/release/tatami-tools vm-bootstrap
```

透過 `1920x1200px` 與 `--no-display-refit` 固定解析度，調整主機 VM 視窗不改變錄製畫布，共用掛載於 `/Volumes/My Shared Files/demolab`。

設定虛擬機之前，先將要使用的 Tatami 版本複製到 Demo Lab 共用資料夾。

```sh
ditto /Applications/Tatami.app DemoLab/.build/Tatami.app
TATAMI_APP="/Volumes/My Shared Files/demolab/.build/Tatami.app" \
  Tools/.build/release/tatami-tools vm-provision
```

也接受 `TATAMI_DMG` 取代 `TATAMI_APP`。SwiftPM 在虛擬機本機磁碟建置，打包時把全部示範 App 註冊到 LaunchServices，以便依套件 ID 解析。

透過 VM 視窗或螢幕共享開啟，依 [PERMISSIONS.md](PERMISSIONS.md) 在系統設定中授權，同時測試錄製器與置頂。目前代理路徑有擷取與輸入權限，但新映像或啟動器需另查。不要修改 TCC 列，也不能僅憑錄製器預備判斷鏡像權限。

<a id="record-an-explicit-batch"></a>
## 錄製明確的批次

```sh
# Host: sync current sources and rebuild in the guest.
Tools/.build/release/tatami-tools vm-sync

# Guest: each scene gets fresh lab data and preferences suppression.
tart exec tatami-demo /Users/admin/DemoLab/.build/tools/tatami-tools capture \
  --root /Users/admin/DemoLab --continue-on-error \
  --output /Users/admin/DemoLab/recordings/review-batch

# Host: a new destination, retaining originals and all provenance sidecars.
GUEST_DIR=DemoLab/recordings/review-batch \
  Tools/.build/release/tatami-tools vm-fetch-recordings DemoLab/recordings/review-batch

Tools/.build/release/tatami-tools export --takes DemoLab/recordings/review-batch \
  --output ~/Downloads/TatamiDemoLab-review
```

用 `--scenes tour cli desk` 排練子集，不覆蓋既有錄製。`--continue-on-error` 保留失敗、在場景間清理，任一失敗即回傳非零代碼。`capture-report.json` 記錄各項結果，只輸出符合目前場景的通過片段。

錄製時避免主機進行繁重編碼或編譯。VM 與主機共用 CPU，遺失影格逐顯示器計量，應在錄製結束後編碼。

<a id="shared-filesystem-correctness"></a>
## 共用檔案系統正確性

雙向傳輸都使用唯一封存檔名稱。實測主機移動舊檔後，virtiofs 重寫同名檔案可能顯示舊位元組或舊 inode；新名稱消除了該重複使用路徑。

只同步受管原始碼目錄，刪除的 Swift 檔案不會留在 VM，保留 `.build` 與錄影。透過唯一標記確認共用位置，比較兩端 SHA256，再解壓到新目錄。包含影片、字幕、時間軸、中繼資料、凍結場景與批次報告。

<a id="finish-or-preserve-the-image"></a>
## 結束或保存映像

```sh
tart exec tatami-demo /Users/admin/DemoLab/.build/DemoLab/bin/democtl quit
tart exec tatami-demo /Users/admin/DemoLab/.build/DemoLab/bin/democtl display disconnect
tart exec tatami-demo /Users/admin/DemoLab/.build/DemoLab/bin/democtl restore
```

`restore` 還原錄製前備份的偏好，不涉及個人主機設定。關閉並驗證的 VM 可用 `tart clone` 保存，淘汰映像前請先把原始檔案與證據存到外部。

<a id="verified-boundary"></a>
## 已驗證界線

v4 驗證了實際 ScreenCaptureKit、輸入與 AX 讀回、並排和借用、獨立雙螢幕擷取、工作空間鏈及連接中斷自動組合。實體擴充座、手勢、混合 DPI/HDR 和新系統需另查；原生全螢幕還原失敗見 [COVERAGE.md](COVERAGE.md)。
