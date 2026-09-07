<!-- LANGUAGE-LINKS:START -->
[English](../MULTI-DISPLAY.md) · [한국어](../ko/MULTI-DISPLAY.md) · [日本語](../ja/MULTI-DISPLAY.md) · [简体中文](../zh-Hans/MULTI-DISPLAY.md) · [繁體中文](MULTI-DISPLAY.md)
<!-- LANGUAGE-LINKS:END -->

<a id="multiple-displays-inside-the-recording-vm"></a>
# 錄製 VM 內的多顯示器

macOS 26.6.2 Tart VM 可以建立**虛擬機內的 CoreGraphics 虛擬顯示器**，不同於向主機 `VZMacGraphicsDeviceConfiguration` 新增第二個圖形顯示器。

舊文件錯誤地把 VZ 硬體顯示器限制視為所有虛擬顯示器的限制。實測列舉出兩個作用中的 1920×1200 顯示器，Tatami 鏈分別放置 Review 與 Chat，ScreenCaptureKit 成功獨立錄製兩屏。

<a id="reproduce"></a>
## 重現

在專用 VM 內執行：

```sh
./scripts/build-virtual-display.sh
./bin/democtl display connect
./bin/democtl displays
./bin/democtl reset
./bin/democtl seed
./bin/democtl take desk --display all --output recordings/desk.mov
./bin/democtl quit
./bin/democtl display disconnect
```

私有 `CGVirtualDisplay` 僅用於 Demo Lab，不進入 Tatami。參考 [DeskPad 介面](https://github.com/Stengo/DeskPad/blob/main/DeskPad/CGVirtualDisplayPrivate.h)，建立 1920×1200 非 HiDPI 顯示器，持續到中斷或限時結束。傳送訊號前檢查 PID 對應執行檔；工具缺少或不支援時明確失敗。

<a id="synchronization-and-composition"></a>
## 同步與合成

`--display all` 為每部顯示器寫一個原始檔案，記錄相對共同單調時鐘的首影格偏移、顯示器原點與獨立影格數、遺失數。取回主機後：

```sh
python3 scripts/compose-displays.py recordings desk
```

依物理原點排序並用記錄的偏移對齊，保留兩個原始檔案，產生無損中間檔，再使用相同 Tatami 配色輸出寬版雙螢幕影片。不會複製或動畫化截圖來偽造第二個螢幕。

<a id="hotplug-is-a-separate-scene"></a>
## 熱插拔是獨立場景

顯示器連接場景會持續錄製主螢幕。第二個虛擬顯示器連接後，由獨立錄製器拍攝該螢幕，並在移除前停止。兩路影片依各自實際的首幀時間同步。合成器將它們並排顯示，未錄製副螢幕的時段留白。它不會複製主螢幕，也不會在中斷連接後保留凍結畫面。錄製清單保留兩個來源檔案的雜湊及副螢幕錄製區間。

實際線材、擴充座、HDR、混合 DPI 與觸控式軌跡板手勢辨識需另行硬體驗證。更換虛擬機系統版本後應重新驗證私有 API 相容性。
