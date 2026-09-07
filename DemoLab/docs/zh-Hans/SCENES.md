<!-- LANGUAGE-LINKS:START -->
[English](../SCENES.md) · [한국어](../ko/SCENES.md) · [日本語](../ja/SCENES.md) · [简体中文](SCENES.md) · [繁體中文](../zh-Hant/SCENES.md)
<!-- LANGUAGE-LINKS:END -->

<a id="scenes-and-acceptance"></a>
# 场景与验收

场景为 JSON，包含 `name`、`title` 和可选的 `requires`、`setup`、`openingApps`、`steps`。`setup` 在录制前执行，`steps` 是可见过程，操作实际 Tatami 和原生演示应用。

```sh
./bin/democtl scene tour --dry-run
./bin/democtl take tour --output recordings/iteration/tour.mov
```

<a id="preparation"></a>
## 准备

在 `openingApps` 声明首帧必须可见的应用，多重集合必须匹配实际普通窗口，包括刻意的重复资料窗口。`autoopen` 以打开工作区为首操作，因此使用空数组。几何稳定 400 ms 后检查。

录制前通过 Tatami 准备工作区。不要把尚未完成的自动打开与手动重启混用，否则同一包 ID 可能出现两个进程、两个窗口。开场检查失败应修正准备过程，不在后期裁掉意外窗口。

<a id="real-actions"></a>
## 实际操作

|类型|字段|效果|
| --- | --- | --- |
|`click`|`app`, `identifier`|定位原生 AX 控件，移动指针并点击。|
|`typeText`|`app`, `text`, `ms?`|在预期聚焦应用中逐字输入。|
|`hover`|`app`, `identifier`|滚动让原生控件进入可见区域，再移入指针。|
|`scroll`|`app`, `identifier`, `pixels`|移动到原生控件并滚动。|
|`key`|`chord`, `repeats?`, `holdMs?`|按实际快捷键并生成相应按键显示。|
|`hold`|`modifiers`, `keys`, `gapMs?`, `releaseAfterMs?`|在切换交互期间持续按住实际修饰键。|
|`activateApp`|`app`|点击可见标题栏，再通过 AX 确认焦点。被遮住的窗口需要实际切换操作。|
|`activateWorkspace`|`workspace`, `profile?`|执行等待完成的 Tatami 激活命令。|
|`activateProfile`|`profile`|执行等待完成的配置方案命令。|
|`cli`|`args`, `expect?`|执行其他 Tatami 命令；`accepted` 只表示入队。|
|`borrow`|`workspace`, `expectApps?`, `timeoutMs?`|高级排练用 CLI 借用，发布视频使用实际按键。|
|`dismissBorrow`|`settleMs?`|高级排练用 CLI 归还。|
|`pointer`|`display`, `x`, `y`|用归一化显示器坐标放置指针。|
|`launch`|`apps`, `windows?`|明确启动演示应用，主要用于录制前。|
|`quitApps`|`apps?`|退出指定演示应用或整个集合。|
|`dragWindow`|`app`, `target`, `x`, `y`|把实际标题栏拖到目标窗口的归一化位置。|
|`restoreWindow`|`app`|通过实际指针拖移恢复窗口大小和位置，再验证原始边界。|
|`rightClick`|`app`, `identifier`|打开控件的原生上下文菜单。|
|`resizeWindow`|`app`, `x`, `y?`|拖动原生窗口边缘。|
|`virtualDisplay`|`connected`|连接或断开实际虚拟显示器工具。|
|`configure`|`key`, `value`|原子修改实验 TOML 中允许的实时设置。|
|`clipboard`|`text`|提供本地示例文本，同时保留并恢复所有剪贴板类型。|
|`closeSettings`|—|编辑后关闭原生设置窗口。|
|`appWindows`|`app`, `count`|设置原生窗口数量，主要用于准备。|

没有 `appState` 命令，视图不能跳到预制成功状态。它们使用普通控件，通过 `StoryRepository` 共享保存的文案、评审、检查、任务和消息。`seed` 重置故事，切换工作区不会。聊天是无网络传输的本地演示。

<a id="assertions-and-pacing"></a>
## 断言与节奏

|类型|字段|验收条件|
| --- | --- | --- |
|`expectPlacement`|`app`, `target`, `value`|验证源应用的所有窗口都位于目标窗口的左侧、右侧、上方或下方。|
|`expectProfileCount`|`count`|通过实际 CLI 验证配置方案数量。|
|`expectAssignment`|`app`, `workspace`, `profile`|验证复制的应用已分配给目标工作区。|
|`expectValue`|`app`, `identifier`, `value`|回读实际原生输入值。|
|`expectStory`|`field`, `value`|验证保存的标题、批准、意见、最后任务与消息、检查或完成项。|
|`expectFront`|`app`|通过辅助功能验证实际聚焦应用。|
|`expectPointer`|`app`|要求指针位于目标窗口内。|
|`expectCommand`|`text`, `code`|验证演示 Terminal 的实际进程结果。|
|`expectHook`|`field`, `value`|检查实际 Tatami 钩子写入的数据。|
|`saveWindow` / `assertWindow`|`app`|跨成员关系变化保存并比较同一窗口。|
|`saveControlFrame` / `expectControlMoved`|`app`, `identifier`, `text`|验证布局编辑操作实际改变了预览。|
|`waitWindows`|`apps`, `timeoutMs?`|等待可见窗口和稳定几何。|
|`waitWorkspace`|`workspace`, `timeoutMs?`|观察上一步产生的激活钩子。|
|`waitProfile`|`profile`, `timeoutMs?`|观察配置方案钩子。|
|`saveLayout`|`text`|按检查点名称保存可见演示窗口 ID 和边界。|
|`assertLayout`|`text`|要求相同窗口集合与边界在 4 点误差内恢复。|
|`beat`|`ms`, `note?`|明确声明的阅读停顿，没有隐藏启动等待。|
|`note`|`text`|仅记录到日志的说明。|

每步前后检查权限和设置窗口，失败时中止录制并写入失败记录，导出器拒绝失败片。

<a id="narration"></a>
## 说明与字幕

`chapter`、`caption` 携带 `text`，字幕可使用 `headline | explanation`。空文本清除当前轨道，`clearOverlay` 清除全部说明；`key`、`hold` 自动生成按键显示。独立 `keys` 标签只允许手动排练，发布场景禁用，以免暗示未发生的输入。

`take` 默认 `--overlay off`，文本保存在可编辑 ASS 和 JSON 中。输出在实际桌面上下预留区域，字幕和按键不遮挡应用。`scene` 的实时排练面板与最终设计不同。

位置和时间、容量预算见 [publication.json](../../publication.json)；录制、导出和检查命令见 [README.md](../../zh-Hans/README.md)。
