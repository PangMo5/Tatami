<!-- LANGUAGE-LINKS:START -->
[English](../COVERAGE.md) · [한국어](../ko/COVERAGE.md) · [日本語](../ja/COVERAGE.md) · [简体中文](COVERAGE.md) · [繁體中文](../zh-Hant/COVERAGE.md)
<!-- LANGUAGE-LINKS:END -->

<a id="demo-coverage-and-verification"></a>
# 演示覆盖与验证

发布清单包含 27 个场景：1 个完整工作流程和 26 个功能演示。每种语言都有对应的应用语言、演示内容、输入、字幕和拍摄断言。通过验证的录制按语言、拍摄操作和质量筛选，再分别导出。

<a id="captured-coverage"></a>
## 录制覆盖

|视频集|视频数|展示行为|
| --- | --- | --- |
|工作区|3|直接、最近、顺序切换，自动打开与重开，应用成员移动。|
|配置方案与显示器|5|配置方案切换、GUI 复制配置方案、选择性复制工作区、双屏工作区链、跨屏焦点、连接和断开时自动切换配置方案。|
|平铺与焦点|7|新增和关闭窗口、交换位置、分割方向、调整大小和均衡、拖动、工作区放大、方向焦点、MFF/FFM、长按和轻按窗口切换器、原生可视布局编辑器。|
|借用|3|并排对话、持久暂存区、边缘选择、跨区焦点、完整激活与归还。|
|窗口模式|3|逐工作区和共享置顶、可交互镜像、保持原样及参与切换器。|
|自动化|3|实际 CLI 输出、多命令专注脚本、生命周期与 HUD 钩子、原子编辑 TOML 和实时重载。|
|引导设置|2|内置手势预览和实际键盘练习，验证示例 AI 建议并应用到草稿。|

主视频把设计配色、实际 PNG 导出、写作保存、评审批准、借用、共享状态、CLI 自动化和显示器相关方案切换串成一个任务。八个命名应用是可操作的本地演示；窗口由 Tatami 管理，钩子和 CLI 输出来自实际进程。

<a id="evidence-and-acceptance"></a>
## 证据与验收

验收的录制必须通过实际操作、状态和布局断言，与当前语言的拍摄操作及时间一致，且丢帧率低于 1%。仅修改文字时会保留原场景哈希并新增编辑后的场景哈希。导出会检查完整 MP4、H.264/yuv420p、时长和大小限制、首条字幕时间，以及视频与时间线的共同时间基准。

`evidence/` 保存冻结场景、录制元数据、字幕、时间、抽样帧、OCR 和浏览器结果。具体批次的数量和检查状态应以对应报告为准，不能把旧报告用于新语言或新录制。

颜色来自网站深色调色板，字体按语言选择。媒体 URL 包含输出哈希，防止新旧视频和海报混用。

<a id="boundaries-and-an-unresolved-reproduction"></a>
## 边界与未解决问题

- **原生 macOS 全屏恢复：** 退出后 Canvas 和 Docs 都保持整个工作区边界，原因未定位。`scenes/native-fullscreen.json` 与失败的 `recordings/v4-edge1/fullscreen*` 保留复现，已从发布中排除。`fullscreen` 展示通过验证的 Tatami 工作区放大与恢复。
- **物理手势：** 使用向导预览按钮和实际键盘，不宣称 VM 验证了物理三指、四指识别。
- **AI：** 使用标记的本地示例，不请求外部 AI。录制后确认实际 TOML 仍保留原有工作区名称，示例只应用到草稿。
- **多显示器：** 实际枚举、管理并独立录制两个 CoreGraphics 屏幕，再按时间戳对齐。不代表验证实体扩展坞、混合 DPI、HDR 或线缆。私有工具仅在 Demo Lab，新系统需重新验证。
- **覆盖：** 包含上述主要交互，不是所有偏好、语言、更新流程或硬件组合的穷尽 QA。

<a id="capture-defects-corrected"></a>
## 已修复的录制缺陷

驱动保留方向键的数字键盘与功能键标识，同一快捷键 A/B 检查确认缺失元数据，[Apple 文档](https://developer.apple.com/documentation/appkit/nsevent/modifierflags-swift.struct/numericpad)说明其身份。点击前滚动到可见控件，被遮窗口用实际切换器选择；同步和取回使用唯一归档并验证两端哈希。

旧文档声称 macOS VM 无法拥有第二显示器，这是错误的。实际 API 见 [DeskPad 接口](https://github.com/Stengo/DeskPad/blob/main/DeskPad/CGVirtualDisplayPrivate.h)，配置和复现见 [MULTI-DISPLAY.md](MULTI-DISPLAY.md)。
