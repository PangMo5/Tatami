<!-- LANGUAGE-LINKS:START -->
[English](../TROUBLESHOOTING.md) · [한국어](../ko/TROUBLESHOOTING.md) · [日本語](../ja/TROUBLESHOOTING.md) · [简体中文](TROUBLESHOOTING.md) · [繁體中文](../zh-Hant/TROUBLESHOOTING.md)
<!-- LANGUAGE-LINKS:END -->

<a id="troubleshooting"></a>
# 故障排查

<a id="a-floating-control-disappears-or-brings-its-app-back"></a>
## 浮动控件消失或把应用带回前台

部分应用把会议录制或画中画与普通窗口放在同一进程。离开该应用的工作区时，macOS 的常规隐藏也会隐藏浮动区域。控件可能消失，或应用再次激活，带回普通窗口或 Tatami 工作区。

常见情况包括：

- 正在使用 AI Meeting Notes 录制的 Notion
- Google Chrome、Dia 等浏览器的画中画

把应用注册为可见性例外：

1. 打开**设置 → 工作区**，滚动到浮动控件应用设置区域。
2. 点击 **+** 选择运行中的应用，未运行时可从文件中选择。
3. 保留原来的工作区分配。这项设置的范围比加入共享应用更窄。

注册应用并非始终免于隐藏。切换工作区或借用可见性时，只有应用在普通 WindowServer 层之外拥有屏幕上可见的顶级控件，才保留进程。普通窗口仍存活，但不参与焦点自动化、窗口切换、布局、拖移和成员操作，可能留在平铺窗口后面或出现在 Mission Control。

没有符合条件的控件后，下次可见性变化恢复正常隐藏。屏幕外、透明、普通层、辅助进程拥有，或未作为顶级辅助功能窗口暴露的控件不符合条件。

> [!NOTE]
> 画中画参与平铺是另一问题。Tatami 会自动排除非零层的 PiP，无需注册应用。仅当切换工作区会随浏览器进程一起隐藏 PiP 时，才注册浏览器。

直接管理 `config.toml` 时，请使用准确的应用包标识符：

```toml
[settings.visibility]
overlayAwareApps = [
  "notion.id",
  "com.google.Chrome",
  "company.thebrowser.dia",
]
```

若仍然消失，在**设置 → 通用**启用调试日志，复现一次工作区切换，检查 `~/.config/tatami/tatami.log` 的 `OverlayAware evaluate ... preserve=` 条目。`preserve=false` 表示当前控件不符合上述条件。
