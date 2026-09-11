<!-- LANGUAGE-LINKS:START -->
[English](../CONFIGURATION.md) · [한국어](../ko/CONFIGURATION.md) · [日本語](../ja/CONFIGURATION.md) · [简体中文](CONFIGURATION.md) · [繁體中文](../zh-Hant/CONFIGURATION.md)
<!-- LANGUAGE-LINKS:END -->

<a id="configuration"></a>
# 配置指南

Tatami 从以下路径读取配置：

```
~/.config/tatami/config.toml
```

路径支持 XDG。设置 `$XDG_CONFIG_HOME` 后使用 `$XDG_CONFIG_HOME/tatami/config.toml`。首次启动创建文件，应用内更改时写回；手动编辑也实时生效，可纳入 dotfiles 管理。

外部写入者必须参与 `NSFileCoordinator`，或先写临时文件，再原子替换 `config.toml`。Tatami 会检测并拒绝与自身配置事务竞争的替换。不支持跨重命名持有活动文件描述符继续写入，例如先打开 `config.toml`，其他进程替换路径后仍截断或写入该描述符；POSIX rename 无法重定向已打开的描述符。采用临时文件与原子替换的编辑器符合约定。

首次启动会打开**引导设置**，根据应用信息和显示器创建草稿，在安全的虚拟桌面学习功能。选择**应用设置**时才写入文件，可从**设置 → 通用 → 运行引导设置**再次打开。

文件分为四个顶层部分：

- **`[settings.*]`：** 下文说明的全局偏好
- **`[[sharedApps]]`：** 在每个工作区平铺或置顶的应用
- **`[[profiles]]`：** 工作区及其应用分配
- **`[[hooks]]`：** 由生命周期和操作反馈事件触发的程序

<a id="shortcut-syntax"></a>
## 快捷键语法

快捷键使用 skhd 风格字符串：零个或多个修饰键以 `+` 连接，后接 ` - ` 和按键。

```
ctrl + alt - h
alt + shift - tab
ctrl + alt + shift + cmd - z
```

修饰键：`ctrl`、`alt`（option）、`shift`、`cmd`。按键可为字母、数字、`tab`、`return`、方向键（`left`/`right`/`up`/`down`）、标点等。

<a id="settingsgeneral"></a>
## `[settings.general]`

|键|类型|默认值|说明|
| --- | --- | --- | --- |
|`launchAtLogin`|bool|`false`|将 Tatami 注册为登录项，登录时启动。|
|`checkForUpdatesAutomatically`|bool|`true`|定期检查新版本。|
|`checkInterval`|string|`"daily"`|后台更新检查频率：`hourly`、`daily` 或 `weekly`。|
|`debugLogging`|bool|`false`|向 `~/.config/tatami/tatami.log` 追加诊断事件，首次启用时清空原内容。|

<a id="settingsconfirmations"></a>
## `[settings.confirmations]`

可独立设置每项操作的确认，默认全部开启。选择“不再询问”并确认后，只关闭对应操作的确认。取消不会更改偏好。旧的全局确认设置会迁移到这些选项，明确设置的单项值优先。

|键|默认值|操作|
| --- | --- | --- |
|`addWorkspaceApp`|`true`|将应用分配到工作区|
|`moveWorkspaceApp`|`true`|在工作区之间移动应用|
|`removeWorkspaceApp`|`true`|从工作区移除应用|
|`floatWorkspaceApp`|`true`|将工作区应用置顶|
|`tileWorkspaceApp`|`true`|平铺工作区应用|
|`unmanageWorkspaceApp`|`true`|保持工作区应用原样|
|`addSharedApp`|`true`|添加共享应用|
|`removeSharedApp`|`true`|移除共享应用|
|`floatSharedApp`|`true`|将共享应用置顶|
|`tileSharedApp`|`true`|平铺共享应用|
|`unmanageSharedApp`|`true`|保持共享应用原样|
|`deleteWorkspace`|`true`|删除工作区|
|`deleteProfile`|`true`|删除配置方案|
|`deleteWorkspaceChain`|`true`|删除工作区链|
|`deleteHook`|`true`|删除钩子|
|`removeOverlayException`|`true`|移除窗口显示例外|
|`copyWorkspace`|`true`|复制工作区设置|
|`copyProfile`|`true`|复制配置方案设置|
|`resetSetup`|`true`|重新开始引导设置|
|`reloadSetup`|`true`|重新载入引导设置草稿|
|`applySetup`|`true`|应用引导设置草稿|
|`applySetupRecommendation`|`true`|应用设置建议|
|`deleteSetupWorkspace`|`true`|从设置草稿删除工作区|
|`deleteSetupProfile`|`true`|从设置草稿删除配置方案|
|`uninstallCLI`|`true`|卸载命令行工具|

<a id="settingsvisibility"></a>
## `[settings.visibility]`

|键|类型|默认值|说明|
| --- | --- | --- | --- |
|`overlayAwareApps`|string[]|`[]`|拥有持久高层控件的应用包 ID。注册进程在非零 WindowServer 层有可见顶级 AX 窗口时，Tatami 保持进程可见，但把普通窗口排除在焦点、循环切换、布局、拖移和成员操作之外；它们仍可能出现在 Mission Control。|

这是明确的逐应用例外，不是所有浮动窗口的通用规则。没有匹配的高层顶级窗口时，应用恢复普通隐藏；每次工作区或借用可见性事务都会重新评估。

```toml
[settings.visibility]
overlayAwareApps = ["notion.id"]
```

症状、应用示例和设置操作流程见[故障排查](https://github.com/PangMo5/Tatami/blob/main/docs/TROUBLESHOOTING.md#a-floating-control-disappears-or-brings-its-app-back)。

<a id="settingsmenubar"></a>
## `[settings.menuBar]`

|键|类型|默认值|说明|
| --- | --- | --- | --- |
|`showWorkspaceIcon`|bool|`true`|在菜单栏显示活动工作区图标。|
|`showWorkspaceName`|bool|`true`|在菜单栏显示活动工作区名称。|
|`showProfileIcon`|bool|`true`|有多个配置方案时显示活动方案图标。|
|`showProfileName`|bool|`false`|有多个配置方案时显示活动方案名称。|

<a id="settingshud"></a>
## `[settings.hud]`

用于确认操作的简短反馈。为兼容保留历史表名 `hud`，应用中称为**操作反馈**。`enabled` 是总开关，其余键选择哪些操作显示反馈。

|键|类型|默认值|说明|
| --- | --- | --- | --- |
|`enabled`|bool|`true`|所有操作反馈的总开关。|
|`workspaceSwitch`|bool|`true`|切换时显示工作区名称。|
|`windowCycle`|bool|`true`|按住窗口切换修饰键显示紧凑列表。用快捷键或方向键继续，Return、释放修饰键或点击提交，Escape 取消。轻按不显示列表。|
|`profileSwitch`|bool|`true`|手动或自动切换方案时显示名称。|
|`floating`|bool|`true`|显示工作区和共享应用的置顶状态变化，键名为兼容而保留。|
|`appMembership`|bool|`true`|应用加入或移出工作区、共享应用时显示反馈。|
|`tilingPaused`|bool|`true`|已暂停/继续平铺。|
|`fullscreen`|bool|`true`|进入或退出工作区全屏放大。|
|`borrow`|bool|`true`|显示借用、归还及方向选择提示。|
|`layout`|bool|`true`|为均衡布局等没有独立视觉提示的命令显示反馈。|
|`position`|string|`"top"`|简短操作反馈的位置：`topLeading`、`top`、`topTrailing`、`leading`、`center`、`trailing`、`bottomLeading`、`bottom` 或 `bottomTrailing`。交互式应用窗口列表独立保持居中。|
|`size`|string|`"default"`|简短操作反馈的整体大小：`small`、`default` 或 `large`。交互式应用窗口列表保持固定大小。|
|`durationMs`|int|`900`|进入和退出动画之间完全可见的时长，单位毫秒。带后续提示时显示两倍时长。|

<a id="settingslayout"></a>
## `[settings.layout]`

|键|类型|默认值|说明|
| --- | --- | --- | --- |
|`gapInner`|int|`8`|相邻平铺窗口之间的像素间距。|
|`gapOuter`|int|`8`|平铺区域与屏幕边缘之间的像素间距。|
|`autoBalance`|string|`"none"`|每次插入或移除后重新均衡分割，可选 `none`、`horizontal`、`vertical`、`both`。旧 bool 仍可解析：`true` → `both`、`false` → `none`。|
|`splitType`|string|`"auto"`|新窗口分割区域时的默认轴：`auto`（按宽高比）、`horizontal`、`vertical`。|
|`windowPlacement`|string|`"second"`|新分割中放置新窗口的一侧：`first`（上、左）或 `second`（下、右）。|

<a id="window-and-layout-restoration"></a>
### 窗口与布局恢复

Tatami 分别记住每个工作区的分割方向、比例和全屏状态。窗口关闭或陆续打开时，现有窗口会填满可用空间，同时保留缺失窗口的位置。重新打开的窗口可以回到这些位置。手动调整大小、重新排列或切换全屏等布局操作，会按当前窗口重新保存布局。

由 macOS 和各应用决定重新打开哪些窗口。Tatami 将记住的布局应用到这些窗口，不会自行重新打开文稿。以下 macOS 设置分别控制不同情况：

- **系统设置 → 桌面与程序坞**中的**退出应用程序时关闭窗口**：关闭此选项后，支持此功能的应用可以在下次启动时重新打开窗口。开启时，应用可能改为打开新窗口。
- 注销、重新启动或关机对话框中的**再次登录时重新打开窗口**：选中后，macOS 会在下次登录时重新打开应用和窗口。启用 Tatami 的**登录时启动**，或在登录后打开 Tatami，即可应用其布局。

Tatami 按应用和窗口顺序匹配布局位置，而不是按文稿名称。如果应用改变重新创建窗口的顺序，其他文稿可能占据原来保存的位置。新窗口也可以使用旧位置。工作区的**自动打开**设置用于启动应用，与 macOS 的文稿恢复相互独立。

<a id="settingsfocus"></a>
## `[settings.focus]`

|键|类型|默认值|说明|
| --- | --- | --- | --- |
|`mouseFollowsFocus`|bool|`false`|把指针移到 Tatami 聚焦的窗口。方向焦点、应用窗口切换、工作区变化、关闭后恢复焦点、交换、分割方向和全屏放大的进入退出都会移动指针。置顶和保持原样使用实际窗口边框。通过 Dock、Spotlight 等外部激活应用时，跟随系统实际置前的窗口，而非工作区最近窗口。点击、结束拖移、拖移交换或分割、拖移回弹等由指针引起的变化不移动指针。放大缩小和均衡也排除在外，避免按住键时每次都重新居中。|
|`mouseHidesOnFocus`|bool|`false`|切换工作区时隐藏指针，直到鼠标移动。|
|`focusFollowsMouse`|bool|`false`|指针移动时聚焦其下方窗口。|
|`refocusOnClose`|bool|`true`|聚焦窗口关闭且应用已无窗口时，按最近使用顺序，把焦点移到工作区中剩下的窗口。|
|`focusFollowsMouseIgnoreFullscreen`|bool|`true`|启用焦点跟随鼠标时，不切换到占满整个显示器的全屏或最大化窗口。|
|`focusFollowsMouseDisableHotkey`|string|`"Alt"`|临时暂停焦点跟随鼠标的修饰键：`None`、`Alt`、`Cmd`、`Ctrl`、`Shift`。|

<a id="settingsswitching"></a>
## `[settings.switching]`

|键|类型|默认值|说明|
| --- | --- | --- | --- |
|`loop`|bool|`true`|从最后一个工作区继续切换到第一个，反之亦然。|
|`skipEmpty`|bool|`false`|前后切换时跳过没有运行应用的工作区。|
|`followAppFocus`|bool|`true`|激活应用时切换到其所属工作区。|
|`cycleAcrossDisplays`|bool|`false`|在所有显示器间切换前后工作区，而非仅指针所在屏幕。键名为兼容而保留。|
|`recentAcrossDisplays`|bool|`true`|所有显示器共用最近工作区历史。目标已在其他显示器可见时，直接在那里聚焦，不移动它。设为 `false` 使用严格的逐显示器历史。|
|`switchToRecentWhenEmpty`|bool|`false`|活动工作区最后一个窗口关闭，且没有平铺窗口或该工作区专属置顶窗口时，切换到最近工作区。共享应用不计入，因为它们加入所有工作区。|
|`cycleSameAppWindows`|bool|`false`|前后窗口切换粒度。默认 `false` 按应用切换并恢复该应用最近窗口；`true` 遍历每个窗口，包括同一应用的多个窗口。活动工作区的平铺、置顶和保持原样窗口参与；借用时两侧平铺区域组成同一顺序。键名为兼容保留。|
|`includeSharedAppsInWindowSwitcher`|bool|`true`|在应用窗口切换器中包含共享应用。借用时，非平铺共享窗口与两侧平铺区域一起参与；`false` 在所有场景中排除共享应用。|
|`toggleBorrowOnRepeat`|bool|`true`|再次借用已在旁边的工作区会归还并恢复主工作区；`false` 则移动借来的工作区。|
|`borrowDefaultEdge`|string?|_（未设置）_|默认借用停靠位置：`top`、`bottom`、`left`、`right`。未设置时等待 h/j/k/l 或方向键；工作区的 `borrowEdge` 会覆盖此值。|
|`borrowFraction`|double|`0.4`|借用区域沿分割轴占屏幕的比例（0.1…0.9），工作区的 `borrowFraction` 会覆盖此值。|

Tatami 运行期间，键盘窗口切换会为每个工作区分别记住最近的焦点顺序。短按并松开“下一个窗口”快捷键，即可返回上次使用的应用或窗口。按住修饰键可浏览列表，列表顺序保持不变，直到松开或取消。切换工作区或重新排列窗口不会清除该工作区的记录。窗口切换手势仍按布局顺序移动。

<a id="settingsgestures"></a>
## `[settings.gestures]`

|键|类型|默认值|说明|
| --- | --- | --- | --- |
|`enabled`|bool|`false`|识别配置的三指和四指触控板滑动。|
|`threshold`|double|`0.3`|触发操作所需的滑动距离，值越低越灵敏，保留两位小数。|
|`threeFinger`|table|左 → `nextWorkspace`，右 → `previousWorkspace`|三指向 `left`、`right`、`up`、`down` 滑动的操作，缺少的方向为 `none`。|
|`fourFinger`|table|所有方向 → `none`|四指向 `left`、`right`、`up`、`down` 滑动的操作。|

每个方向保存一个动作字符串。应用的嵌套菜单会自动写入稳定 UUID，是配置方案和工作区操作最方便的方式。

```toml
[settings.gestures]
enabled = true
threshold = 0.3

[settings.gestures.threeFinger]
left = "nextWorkspace"
right = "previousWorkspace"
up = "toggleFullscreen"
down = "none"

[settings.gestures.fourFinger]
left = "focusPreviousDisplay"
right = "focusNextDisplay"
up = "activateProfile:00000000-0000-0000-0000-000000000001"
down = "activateWorkspace:00000000-0000-0000-0000-000000000010"
```

可用的固定动作字符串：

- **工作区：** `nextWorkspace`、`previousWorkspace`、`recentWorkspace`、`moveAppToNextWorkspace`、`moveAppToPreviousWorkspace`、`assignAppToRecentWorkspace`、`assignAppToNextWorkspace`、`assignAppToPreviousWorkspace`
- **焦点与显示器：** `focusNextDisplay`、`focusPreviousDisplay`、`focusLeft`、`focusRight`、`focusUp`、`focusDown`
- **窗口切换：** `cycleNextWindow`、`cyclePreviousWindow`
- **布局：** `growWindow`、`shrinkWindow`、`swapLeft`、`swapRight`、`swapUp`、`swapDown`、`toggleOrientation`、`toggleFullscreen`、`balanceLayout`
- **应用与平铺：** `toggleFloating`、`toggleSharedFloating`、`toggleTiling`、`toggleAppInWorkspace`、`toggleAppInSharedApps`。`floating` 保留为**置顶**的稳定配置标识符。
- **借用：** `borrowRecentWorkspace`、`borrowNextWorkspace`、`borrowPreviousWorkspace`、`dismissBorrow`
- **未绑定：** `none`

目标专用操作追加稳定标识符：`activateWorkspace:<workspace UUID>`、`assignAppToWorkspace:<workspace UUID>`、`borrowWorkspace:<workspace UUID>` 或 `activateProfile:<profile UUID>`。借用指定工作区要求其方案处于活动状态；激活或分配工作区则可以先切换到所属方案。

旧配置 `fingerCount = 3` 或 `4` 会自动迁移：该指数量的左右保留原有前后工作区行为，其他方向及指数量保持未绑定。

<a id="settingsmarker"></a>
## `[settings.marker]`

角落的小圆点用于识别放大、置顶和借来的窗口。

|键|类型|默认值|说明|
| --- | --- | --- | --- |
|`fullscreenEnabled`|bool|`true`|聚焦工作区全屏放大的窗口时显示圆点。|
|`fullscreenColorHex`|string|`"#007AFF"`|全屏圆点颜色（`#RRGGBB`）。|
|`floatingEnabled`|bool|`true`|置顶窗口始终显示圆点，便于一眼识别状态。|
|`floatingColorHex`|string|`"#FF9500"`|置顶圆点颜色（`#RRGGBB`）。|
|`borrowEnabled`|bool|`true`|借用可见时，为每个借来的窗口显示工作区图标。|
|`borrowColorHex`|string|`"#AF52DE"`|借用标记颜色（`#RRGGBB`）。|
|`size`|double|`14`|圆点直径，单位点。借用标记绘制得更大，确保符号清晰。|
|`corner`|string|`"bottomTrailing"`|圆点所在窗口角落：`topLeading`、`topTrailing`、`bottomLeading`、`bottomTrailing`。|
|`hideOnHover`|bool|`true`|指针停在圆点上方时淡化。|

<a id="settingsshortcuts"></a>
## `[settings.shortcuts]`

多数值为 skhd 风格字符串，省略键则不绑定。没有 `config.toml` 的新配置会加入[推荐默认值](#recommended-defaults)，所有快捷键都可重新录制或清除。例外是下方三个 `*Modifiers` 数组，用于每工作区的**按键**模型。

<a id="workspace-keys-switch--assign--borrow"></a>
### 工作区按键：切换、分配、借用

不用为每个工作区绑定三个独立快捷键，只需指定一个字符的**按键**（`keyEquivalent`），与三种全局修饰键组合之一搭配选择操作。

|键|类型|默认值|操作|
| --- | --- | --- | --- |
|`keyEquivalentModifiers`|string[]|`["ctrl", "alt"]`|+ 工作区按键 → **切换**到该工作区|
|`assignModifiers`|string[]|`["ctrl", "alt", "shift"]`|+ 工作区按键 → **分配**聚焦应用并切换过去|
|`borrowModifiers`|string[]|`["ctrl", "alt", "cmd"]`|+ 工作区按键 → **借用**到当前屏幕|

修饰键令牌为 `ctrl`、`alt`、`shift`、`cmd`。空数组禁用该动作的按键组合，避免单独按键截获输入。

上表的**默认值**用于*已有*配置缺少键时。全新安装会使用推荐组合 `keyEquivalentModifiers = ["ctrl", "alt", "shift"]` 和 `assignModifiers = ["alt", "shift", "cmd"]`，详见[推荐默认值](#recommended-defaults)。

同样三种修饰键也用于**最近、下一个、上一个**目标，各目标有自己的按键。

|键|类型|说明|
| --- | --- | --- |
|`recentWorkspaceKey`|string?|最近工作区按键，与切换、分配或借用修饰键组合。|
|`nextWorkspaceKey`|string?|下一个工作区按键。|
|`previousWorkspaceKey`|string?|上一个工作区按键。|

上述操作都可设置**显式覆盖**快捷键，优先于修饰键加工作区按键组合。

- 每个工作区可指定 `activateShortcut`、`assignAppShortcut`、`borrowShortcut`，见下方工作区部分。
- **每个导航目标：** `switchTo{Recent,Next,Previous}Workspace`、`assign{Recent,Next,Previous}Workspace`、`borrow{Recent,Next,Previous}Workspace`，均使用 skhd 字符串。

工作区按键和显式快捷键只在所属方案内生效，不同方案可复用。全局快捷键仍与所有方案检查冲突，复制操作也会在保存到目标方案前验证所选更改。

未设置默认边缘（`settings.switching.borrowDefaultEdge` 或工作区的 `borrowEdge`）时，借用会等待 h/j/k/l 或方向键。`dismissBorrow` 归还借用并恢复主工作区占满屏幕。

<a id="action-shortcuts"></a>
### 操作快捷键

|键|操作|
| --- | --- |
|`focusLeft` / `focusRight` / `focusUp` / `focusDown`|聚焦指定方向的平铺区域，在边缘可跨入借用区域。|
|`swapLeft` / `swapRight` / `swapUp` / `swapDown`|沿指定方向交换聚焦区域。|
|`resizeGrow` / `resizeShrink`|根据父级分割的左右或上下方向，扩大或缩小当前选中窗口的区域|
|`toggleOrientation`|切换聚焦分割的方向。|
|`toggleFullscreen`|把聚焦窗口放大到整个工作区。|
|`balance`|应用配置的 `autoBalance` 轴。关闭自动均衡时，根据当前窗口顺序重建标准 BSP 拓扑和比例。|
|`cycleNextWindow` / `cyclePreviousWindow`|在可见的 Tatami 工作区内切换应用或窗口。排除 Command-Tab 中无关的运行应用，也能跨越 Command-backtick 的单应用范围。|
|`moveToNextWorkspace` / `moveToPreviousWorkspace`|把聚焦应用移到前后工作区并跟随过去。|
|`dismissBorrow`|归还借用工作区，恢复主工作区占满屏幕。|
|`focusNextDisplay` / `focusPreviousDisplay`|聚焦前后显示器的活动工作区，到边缘后循环。|
|`toggleFloating`|让聚焦应用在当前工作区置顶，需要时加入该工作区。再次执行恢复平铺。|
|`toggleSharedFloating`|让聚焦应用在所有地方置顶，需要时加入共享应用。关闭后变为共享*平铺*，用 `toggleAppInSharedApps` 移除成员关系。|
|`toggleFocusedAppInActiveWorkspace`|把聚焦窗口的应用加入活动工作区，已属于时则移除。|
|`toggleAppInSharedApps`|把聚焦应用加入共享应用，在每个工作区平铺；已共享则移除。|
|`toggleSpaceActivated`|暂停或恢复平铺|

<a id="recommended-defaults"></a>
### 推荐默认值

没有 `config.toml` 的全新配置会提供可立即使用的组合。`⌃⌥` 控制窗口和平铺，工作区**切换**使用 `⌃⌥⇧`，**分配**使用 `⌥⇧⌘`，避免单字符工作区键与 `⌃⌥` 焦点键冲突。所有设置都可重新录制或清除。

|操作|快捷键|
| --- | --- |
|向左、下、上、右聚焦|`⌃⌥H` · `⌃⌥J` · `⌃⌥K` · `⌃⌥L`|
|向左、下、上、右交换|`⌃⌥←` · `⌃⌥↓` · `⌃⌥↑` · `⌃⌥→`|
|放大、缩小|`⌃⌥=` · `⌃⌥-`|
|切换方向|`⌃⌥S`|
|切换全屏|`⌃⌥⏎`|
|均衡|`⌃⌥E`|
|切换到前后窗口|`⌥⇥` · `⌥⇧⇥`|
|切换置顶状态|`⌥⌘⏎`|
|切换共享置顶状态|`⌥⇧⌘⏎`|
|切换平铺暂停|`⌃⌥⇧⌘Z`|
|切换应用的工作区归属|`⌃⌥/`|
|切换应用的共享状态|`⌃⌥⇧/`|
|把应用移到前后工作区|`⌃⌥⇧[` · `⌃⌥⇧]`|
|聚焦前后显示器|`⌃⌥⇧←` · `⌃⌥⇧→`|
|归还借用工作区|`⌃⌥⌘/`|
|最近、下一个、上一个工作区按键|`\` · `.` · `,`|

工作区的**切换、分配、借用**将上面的修饰键与每个工作区按键，以及最近、前后按键组合使用。

<a id="sharedapps"></a>
## `[[sharedApps]]`

这里的应用加入**每个**工作区。`layout` 可为 `tiled`（默认，参与平铺）、`floating`（**置顶**，通过镜像在所有区域上方显示）或 `unmanaged`（**保持原样**，保留成员关系但不移动、平铺或镜像）。可选 `autoOpen`（bool，默认 `false`）在激活工作区且没有屏幕内窗口时启动或重开应用；`iconPath` 是自动写入的管理用字符串，不应手动设置。

```toml
[[sharedApps]]
bundleIdentifier = "com.apple.iphonesimulator"
name = "Simulator"
layout = "floating"      # untiled, always on top, available in every workspace

[[sharedApps]]
bundleIdentifier = "com.apple.Music"
name = "Music"
layout = "tiled"         # tiled into every workspace's layout (default)

[[sharedApps]]
bundleIdentifier = "com.colliderli.iina"
name = "IINA"
layout = "unmanaged"     # left alone as a member, but never tiled or mirrored
```

置顶不需要关闭 SIP。Tatami 用 ScreenCaptureKit 把窗口镜像到置顶面板，需要**屏幕录制**权限（设置 → 通用 → 权限）。应用本身获得焦点时隐藏镜像并停止捕获。`unmanaged` 不操作实际窗口，无需该权限。

可在**工作区 → 共享应用**中编辑平铺、置顶或保持原样。

旧 `[[floatingApps]]` 配置在首次读取时自动迁移，每项变为 `layout = "floating"` 的共享应用。1.4 之前的 `floating` bool 也会迁移：`true` → `floating`，否则为 `tiled`。

<a id="hooks"></a>
## `[[hooks]]`

Tatami 发布以下事件时，钩子运行程序：

- `tatamiLaunched`：启动确定活动方案后，每个进程发送一次，传入该方案，不包含 `previousProfile`、`workspace`、`display`。同一进程中后来添加的钩子不会重放此事件。
- `profileChanged`：活动配置方案发生变化。启动时不包含 `previousProfile`。
- `workspaceActivated`：工作区激活已在显示器上发布可见状态，失败或超时不会发送。
- `hud`：已发布简短操作反馈，包含发送给 Tatami 的准确本地化标题、SF Symbol、可选副标题、持续时间、位置、大小和可选目标显示器，供 SketchyBar 等外部界面显示相同反馈。

启动时的 `tatamiLaunched` 和 `profileChanged` 相互独立，根据需要选择进程启动或方案生命周期变化，也可同时订阅。

在**设置 → 钩子**中管理钩子。可执行文件、各参数、工作目录、超时和环境变量分别输入，写入下文相同的 `[[hooks]]` 项，因此直接编辑 `config.toml` 仍完整受支持并实时生效。

**运行测试**验证当前编辑草稿，并用示例事件执行一次，不新增或更新钩子，也不写入 `config.toml`。要保留草稿，请另外选择**保存**。

```toml
[[hooks]]
id = "notify-context"
event = "workspaceActivated"
enabled = true
command = ["/Users/me/.config/tatami/hooks/notify-context", "--compact"]
timeoutMs = 5000
workingDirectory = "/Users/me"
environment = { MODE = "desktop" }
```

|键|类型|默认值|说明|
| --- | --- | --- | --- |
|`id`|string|_（必填）_|唯一诊断标识符，使用 ASCII 字母、数字、`.`、`_` 或 `-`，最长 64 个字符。|
|`event`|string|_（必填）_|`tatamiLaunched`、`profileChanged`、`workspaceActivated` 或 `hud`。|
|`enabled`|bool|`true`|是否运行该钩子。禁用的钩子仍会显示在 `tatami hook list` 中。|
|`command`|string[]|_（必填）_|可执行文件后接参数，每个元素是一个 argv 值。|
|`timeoutMs`|int|`5000`|运行时间上限为 100 至 300000 毫秒。|
|`workingDirectory`|string?|Tatami 配置目录|绝对路径，或以 `~/` 开头的路径。|
|`environment`|table|`{}`|添加到应用继承环境中的值，下方 Tatami 上下文值优先。|

Tatami 直接执行 `command`，不启动 shell、不拆词、不解释引号或展开变量。编辑器中 `command[0]` 是执行文件，每个参数行对应一个 argv。需要 shell 时明确使用 `command = ["/bin/zsh", "-lc", "your pipeline"]`；fish 使用 `which fish` 返回的路径，按 `command = ["/opt/homebrew/bin/fish", "-c", "command ls"]` 分开参数。事件 JSON 通过 stdin 发送。包含 `/` 的执行文件按路径处理并展开开头的 `~/`；裸名称从应用继承的 `PATH` 查找。Finder 启动时，绝对执行路径最可预测。

每个钩子通过 stdin 接收一个带版本的 JSON，包含 `schemaVersion`、`event`、`occurredAt`、`profile`，以及适用时的 `previousProfile`、`workspace`、`display`、`hud`。`hud` 对象包含 `title`、`symbolIconName`、`subtitle`、可选的 `subtitleSymbolIconName`、`durationMs`、`position`、`size`。能识别屏幕时，HUD 事件携带解析后的 `display`；工作区链按受影响显示器分别发送该屏幕的工作区反馈。`durationMs` 是完全可见的停留时间，外部界面另加进入退出动画。还会设置以下便利变量：

- `TATAMI_HOOK_ID`, `TATAMI_HOOK_EVENT`
- `TATAMI_PROFILE_ID`, `TATAMI_PROFILE_NAME`
- 工作区事件包含 `TATAMI_WORKSPACE_ID`、`TATAMI_WORKSPACE_NAME`、`TATAMI_WORKSPACE_KIND`。
- 已知显示器时包含 `TATAMI_DISPLAY_UUID`、`TATAMI_DISPLAY_NAME`。
- `hud` 事件包含 `TATAMI_HUD_TITLE`、`TATAMI_HUD_SYMBOL_ICON_NAME`、`TATAMI_HUD_SUBTITLE`、`TATAMI_HUD_SUBTITLE_SYMBOL_ICON_NAME`、`TATAMI_HUD_DURATION_MS`、`TATAMI_HUD_POSITION`、`TATAMI_HUD_SIZE`。可选值不存在时省略，不设为空字符串。

例如 SketchyBar 桥接可订阅 `event = "hud"`，将 `command` 指向把 `TATAMI_HUD_*` 变量转发给自定义事件的小脚本。stdin 也提供 JSON，需要结构化可选字段时无需解析环境变量约定。钩子自身的失败或恢复反馈不会再次发布为 `hud`，以防失败钩子递归启动自己。

stdout 和 stderr 各限 64 KiB。非零退出、信号、启动错误、输出过量或超时会显示在问题列表，并在启用时写入调试日志，不回滚或阻塞方案、工作区变化。命令运行于独立进程会话；超时或退出时先请求正常终止，再强制结束剩余后代，包括 shell 后台任务组。钩子不能自行脱离为新会话。同一 `id` 仍运行时，新事件独立执行，只有最新调用更新当前问题；修改、禁用或删除会取消旧定义的执行并清除问题。

<a id="profiles-and-workspaces"></a>
## `[[profiles]]` 与工作区

配置方案是一组命名工作区。可定义多个并切换，为每个显示器重新平铺，也可按连接状态**自动激活**。当前方案、逐显示器历史和全局最近顺序是会话状态，存于 `config.toml` 旁的 `profile-session.json`，不写入 `config.toml`。启动时无条件恢复最后的手动方案；带显示器条件的方案仅在条件仍匹配时恢复，否则由自动解析器选择最佳匹配。

各方案的工作区独立，应用和设置可能逐渐不同。详情中的**从其他配置复制**可展示差异，只复制勾选保留的更改，无需手动编辑。

```toml
[[profiles]]
id = "00000000-0000-0000-0000-000000000001"
name = "Default"
symbolIconName = "rectangle.stack"     # optional: SF Symbol (sidebar / menu bar / switch feedback)
shortcut = "ctrl + alt + cmd - 1"      # optional: hotkey to switch to this profile

# Optional: auto-activate this profile when the connected displays match. All
# set conditions apply together (AND). Omit the table for manual switching only.
[profiles.autoActivation]
displayCount = ">=2"                        # "==N" | ">=N" | "<=N"
whenConnectedMatch = "contains"             # "contains" (present) | "exactly" (set ==)
whenConnected = ["37D8832A-…::IP1640"]      # these must be connected
whenDisconnected = ["0E769C72-…::Projector"] # these must be unplugged

[[profiles.workspaces]]
id = "00000000-0000-0000-0000-000000000010"
name = "Browser"
symbolIconName = "safari.fill"        # any SF Symbol name
kind = "normal"                        # "normal" | "scratchpad" (borrow-only)
keyEquivalent = "b"                    # switch/assign/borrow modifier + this key
borrowEdge = "right"                   # optional: dock to this edge when borrowed
displayHint = "Built-in Retina Display"           # optional: pin to a display ("<uuid>::<name>" or "<name>")
appToFocusBundleId = "app.zen-browser.zen"        # optional: focus this app on activation

[[profiles.workspaces.apps]]
bundleIdentifier = "app.zen-browser.zen"
name = "Zen Browser"
autoOpen = false                       # launch on activation if not running
layout = "tiled"                       # "tiled" | "floating" | "unmanaged"

[[profiles.workspaces]]
id = "00000000-0000-0000-0000-000000000011"
name = "Code"
kind = "normal"
displayHint = "37D8832A-…::Studio Display"

# Optional symmetric workspace chain. It stores workspace identity only;
# destinations come from each workspace's pin and the pointer at switch time.
[[profiles.workspaceChains]]
id = "00000000-0000-0000-0000-000000000100"
name = "Coding"                        # optional, for the Settings UI
workspaceIds = [
  "00000000-0000-0000-0000-000000000010",
  "00000000-0000-0000-0000-000000000011",
]
# Optional: ignore this pinned workspace's pin when it is placed as a
# companion by this chain. The workspace's ordinary activation is unchanged.
dynamicWorkspaceIds = ["00000000-0000-0000-0000-000000000011"]
```

配置方案字段：

|键|类型|说明|
| --- | --- | --- |
|`id`|UUID|稳定标识符。|
|`name`|string|显示名称。|
|`symbolIconName`|string?|侧边栏、菜单栏和切换反馈中的方案 SF Symbol，省略时使用 `rectangle.stack`。|
|`shortcut`|string?|切换到此方案的 skhd 风格快捷键。|
|`autoActivation`|table?|显示器符合下方条件时自动激活，省略则仅手动。表存在但无条件时匹配任何配置。|
|`workspaceChains`|table[]|跨显示器一起切换的对称工作区组。目标在激活时解析，不存入链；不用时省略。|

**`[profiles.autoActivation]`：** 所有键均可选，以 AND 组合。多个匹配时选最具体的：`exactly` 高于 `contains`，条件越多越优先，相同时选择排列更前的方案。

|键|类型|说明|
| --- | --- | --- |
|`displayCount`|string?|已连接显示器数量：`"==1"`、`">=2"`、`"<=1"`。|
|`whenConnected`|string[]?|必须连接的显示器（`"<uuid>::<name>"` 或 `"<name>"`）。|
|`whenConnectedMatch`|string|默认 `"contains"` 要求列表中的显示器存在，允许额外显示器；`"exactly"` 要求连接集合与列表完全相同。|
|`whenDisconnected`|string[]?|必须断开的显示器。|

**`[[profiles.workspaceChains]]`：** 链是没有锚点或父级的对称组，保存有序的稳定工作区 UUID，不保存显示器槽位。每个工作区在方案内最多属于一条链；每条链至少有两个不同条目，且都指向同方案的普通工作区。重命名安全。

只有用户实际切换到的工作区启动链，链恢复的工作区不会递归触发链。用户明确选择的工作区必须放置，采用与单独激活相同的固定、指针和全局最近规则。先恢复伙伴，再恢复触发工作区，保留用户选择的焦点。

显示器放置不是静态配置验证规则，而按当时连接状态解析。先保留触发工作区，再按 `workspaceIds` 从上到下处理其他成员。固定成员使用已连接且空闲的目标，断开的固定目标直接跳过。动态成员从指针所在显示器开始使用下一个空位；`dynamicWorkspaceIds` 可让固定工作区仅作为链伙伴时采用此行为，不改变普通固定设置。被高优先级占用或无剩余显示器时跳过并继续，因此 `workspaceIds` 决定确定性优先级，无需要求每个成员都有显示器。

链动态伙伴优先占用空闲显示器。链之外的显示器按常规顺序恢复：有效最近历史、固定到该屏幕的工作区、未使用的动态工作区。无效引用和跨链冲突保持可见以便修复，对应链不执行。

工作区链字段：

|键|类型|说明|
| --- | --- | --- |
|`id`|UUID|稳定链标识符，在配置方案内必须唯一。|
|`name`|string?|设置中显示的可选名称，不影响激活。|
|`workspaceIds`|UUID[]|两个或更多不同的普通工作区 ID，按确定的冲突解决顺序排列。|
|`dynamicWorkspaceIds`|UUID[]?|`workspaceIds` 的子集，其中固定工作区作为链伙伴放置时使用下一个空闲显示器。不使用时省略。|

工作区字段：

|键|类型|说明|
| --- | --- | --- |
|`id`|UUID|稳定标识符。|
|`name`|string|显示名称。|
|`symbolIconName`|string?|菜单栏和侧边栏使用的 SF Symbol。|
|`kind`|string|`normal`（默认）或 `scratchpad`。暂存区**仅供借用**，排除普通切换，不单独激活，借到其他工作区旁边时自动打开应用。|
|`keyEquivalent`|string?|此工作区的单字符按键，与切换、分配、借用修饰键组合，见 `[settings.shortcuts]`。省略则禁用其按键操作。|
|`activateShortcut`|string?|切换组合的显式覆盖。|
|`assignAppShortcut`|string?|分配组合的显式覆盖：添加聚焦应用，保留其他成员关系并切换到此处。|
|`borrowShortcut`|string?|借用组合的显式覆盖。|
|`borrowEdge`|string?|覆盖此工作区的默认借用边缘：`top`、`bottom`、`left`、`right`。省略则使用 `settings.switching.borrowDefaultEdge`，其也未设置时选择方向。|
|`borrowFraction`|double?|覆盖此工作区借用区域的大小（0.1…0.9），省略使用 `settings.switching.borrowFraction`。|
|`appToFocusBundleId`|string?|激活时聚焦的已分配应用包 ID，省略则使用最近应用。|
|`displayHint`|string?|用 `"<uuid>::<name>"` 或 `"<name>"` 固定到显示器。省略则在鼠标所在屏幕打开，固定显示器缺失时回到主屏。动态工作区离开后，原显示器按自身历史补位，只能使用固定到该屏幕的工作区，或未被其他屏幕使用的动态工作区。不会拉入固定到已断开显示器的工作区；无候选时保持空白。|

应用分配字段：

|键|类型|说明|
| --- | --- | --- |
|`bundleIdentifier`|string|应用包 ID。|
|`name`|string|显示名称。|
|`autoOpen`|bool|激活工作区时启动应用，关闭窗口后重新进入时再次打开。|
|`layout`|string|`tiled`（**平铺**）、`floating`（**置顶**，不平铺，以镜像置于上方）或 `unmanaged`（**保持原样**，保留位置和成员关系，无平铺、镜像或屏幕录制）。从 1.4 前的 `floating` bool 迁移。|
|`iconPath`|string?|自动写入的应用图标缓存路径，不应手动设置。|
