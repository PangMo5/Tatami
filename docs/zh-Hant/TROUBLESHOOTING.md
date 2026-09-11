<!-- LANGUAGE-LINKS:START -->
[English](../TROUBLESHOOTING.md) · [한국어](../ko/TROUBLESHOOTING.md) · [日本語](../ja/TROUBLESHOOTING.md) · [简体中文](../zh-Hans/TROUBLESHOOTING.md) · [繁體中文](TROUBLESHOOTING.md)
<!-- LANGUAGE-LINKS:END -->

<a id="troubleshooting"></a>
# 疑難排解

<a id="a-floating-control-disappears-or-brings-its-app-back"></a>
## 浮動控制項消失或把 App 帶回前景

部分 App 把會議錄製或子母畫面與一般視窗放在同一程序。離開該 App 的工作空間時，macOS 的一般隱藏也會隱藏浮動區域。控制項可能消失，或 App 再次啟用，帶回一般視窗或 Tatami 工作空間。

常見情況包含：

- 正在使用 AI Meeting Notes 錄製的 Notion
- Google Chrome、Dia 等瀏覽器的子母畫面

把 App 註冊為顯示例外：

1. 開啟**設定 → 工作空間**，捲動到浮動控制項 App 設定區域。
2. 點按 **+** 選擇執行中的 App，未執行時可從檔案中選擇。
3. 保留原來的工作空間指派。這項設定的範圍比加入共用 App 更小。

註冊 App 並非永遠免於隱藏。切換工作空間或借用顯示時，只有 App 在一般 WindowServer 層之外擁有螢幕上可見的最上層控制項，才保留程序。一般視窗仍存活，但不參與焦點自動化、視窗切換、排列、拖移與成員操作，可能留在並排視窗後面或出現在 Mission Control。

沒有符合條件的控制項後，下次顯示變化恢復正常隱藏。螢幕外、透明、一般層、輔助程序擁有，或未作為最上層輔助使用視窗提供的控制項不符合條件。

> [!NOTE]
> 子母畫面參與並排是另一問題。Tatami 會自動排除非零層的 PiP，不必註冊 App。僅當切換工作空間會隨瀏覽器程序一起隱藏 PiP 時，才註冊瀏覽器。

直接管理 `config.toml` 時，請使用確切的 App 套件識別碼：

```toml
[settings.visibility]
overlayAwareApps = [
  "notion.id",
  "com.google.Chrome",
  "company.thebrowser.dia",
]
```

若仍然消失，在**設定 → 一般**啟用偵錯記錄，重現一次工作空間切換，檢查 `~/.config/tatami/tatami.log` 的 `OverlayAware evaluate ... preserve=` 項目。`preserve=false` 表示目前控制項不符合上述條件。

<a id="fullscreen-zoom-changes-after-connecting-a-display"></a>
## 連接顯示器後全螢幕狀態改變

請檢查目前使用的設定組合和工作空間。連接的顯示器改變時，顯示器規則可能會自動切換設定組合。即使另一個設定組合包含相同 App，每個工作空間的配置和全螢幕狀態仍會分別儲存。請在使用的各設定組合中設定配置，或調整顯示器規則以避免意外切換。
