<!-- LANGUAGE-LINKS:START -->
[English](../CLI.md) · [한국어](../ko/CLI.md) · [日本語](../ja/CLI.md) · [简体中文](CLI.md) · [繁體中文](../zh-Hant/CLI.md)
<!-- LANGUAGE-LINKS:END -->

<a id="tatami-command-line-reference"></a>
# Tatami 命令行参考

应用包内包含 `tatami` 可执行文件。CLI 与运行中的应用通信，请先启动 Tatami 再发送命令。

<a id="install"></a>
## 安装

打开**设置 → 通用 → 命令行 → 安装**。Tatami 在 `/usr/local/bin/tatami` 创建符号链接，安装或删除时 macOS 会请求管理员密码。链接指向应用包，在相同路径替换应用会同时更新 CLI；移动或重命名应用后请重新安装链接。

同时检查可执行文件和运行中的应用：

```sh
tatami --version     # bundled CLI version, no app connection required
tatami version       # version reported by the running Tatami app
```

<a id="command-overview"></a>
## 命令概览

```text
tatami version [--json]

tatami profile list [--json]
tatami profile activate <profile> [--json]
tatami profile rename <profile> <new-name> [--json]
tatami profile duplicate <profile> [--name <new-name>] [--json]

tatami workspace list [--profile <profile>] [--json]
tatami workspace apps <workspace> [--profile <profile>] [--json]
tatami workspace activate <workspace> [--profile <profile>] [--json]
tatami workspace rename <workspace> <new-name> [--profile <profile>] [--json]
tatami workspace duplicate <workspace> [--profile <profile>] [--name <new-name>] [--json]
tatami workspace next|previous|recent [--json]
tatami workspace move-app next|previous [--json]
tatami workspace assign-app to <workspace> [--profile <profile>] [--json]
tatami workspace assign-app next|previous|recent [--json]
tatami workspace borrow from <workspace> [--json]
tatami workspace borrow next|previous|recent [--json]
tatami workspace dismiss-borrow [--json]

tatami window focus left|right|up|down [--json]
tatami window cycle next|previous [--json]
tatami window resize grow|shrink [--json]
tatami window swap left|right|up|down [--json]
tatami window toggle-fullscreen|toggle-floating|toggle-shared-floating [--json]
tatami display focus next|previous [--json]

tatami layout toggle-orientation|balance|toggle-tiling [--json]

tatami app toggle-workspace|toggle-shared [--json]

tatami hook list [--json]
```

执行 `tatami help`、`tatami help <command>`，或在命令后添加 `--help`，查看 ArgumentParser 当前的用法。

<a id="select-profiles-and-workspaces"></a>
## 选择配置方案和工作区

`<profile>` 和 `<workspace>` 可使用当前名称或 UUID。未提供 `--profile` 时，工作区名称在活动配置方案内解析；UUID 全局唯一，因此无需 `--profile` 也可选中非活动方案。`workspace borrow from` 例外：借用只接受活动方案内的工作区，需要时先切换方案。

查找范围内名称重复时，不进行更改，返回失败并列出所有候选 UUID。请用其中一个 UUID 重试。

原有平铺式命令保留为兼容别名，供现有脚本使用。它们不出现在根帮助中，让新用法按领域组织：

- `tatami list-workspaces` 等同于对活动配置方案执行 `tatami workspace list`。
- `tatami list-apps <workspace>` 等同于对活动配置方案执行 `tatami workspace apps <workspace>`。
- `tatami activate <workspace>` 等同于对活动配置方案执行 `tatami workspace activate <workspace>`。

重命名和复制以事务方式更新 `config.toml`。复制会先复制保存的布局，再发布新配置；布局复制失败时配置保持不变。

CLI 复制整个项目，不打开选择面板。`workspace duplicate` 的副本处于同一方案，因此清空新工作区按键和显式激活、分配、借用快捷键。`profile duplicate` 清空新方案的切换快捷键和自动激活规则，但保留工作区快捷键，因为它们按方案隔离。要选择单独的工作区、应用、设置或布局，请在应用中复制。

<a id="run-dispatcher-commands-by-domain"></a>
## 按领域执行操作命令

`profile`、`workspace`、`window`、`display`、`layout` 和 `app` 覆盖三指、四指手势可绑定的全部执行能力。非激活操作通过 `GestureAction` 映射，使用与手势和全局快捷键相同的 `HotKeyAction` 分发器；没有通用 `action` 入口。

大多数操作返回 `accepted`，表示运行中的应用已验证命令并交给共享 reducer，不代表后续辅助功能或窗口操作已改变窗口。例如 `window focus left` 可能没有相邻窗口，应用命令也可能在无聚焦应用时到达。

`profile activate` 和 `workspace activate` 会等待完整激活流程，返回 `completed` 或最终失败。暂存区仅供借用，请使用 `workspace borrow from <workspace>`。

切换命令不具幂等性。客户端结果中断或未知时，先检查状态，不要盲目重试，否则可能撤销首次操作。

<a id="profiles-and-workspaces"></a>
### 配置方案与工作区

|命令|行为|
| --- | --- |
|`profile activate <profile>`|激活配置方案并等待最终完成。|
|`workspace activate <workspace> [--profile …]`|激活工作区，必要时激活所属方案，再等待完成。|
|`workspace next` / `previous` / `recent`|按工作区历史或顺序切换。|
|`workspace move-app next` / `previous`|把聚焦应用移到相邻工作区并切换。|
|`workspace assign-app to <workspace> [--profile …]`|保留现有工作区成员关系并添加聚焦应用，必要时切换方案，再激活目标。|
|`workspace assign-app next` / `previous` / `recent`|保留现有成员关系并添加聚焦应用，然后切换到相对工作区。|
|`workspace borrow from <workspace>`|为活动方案中的工作区打开交互式借用方向选择器。|
|`workspace borrow next` / `previous` / `recent`|借用相对工作区。|
|`workspace dismiss-borrow`|归还指针所在显示器的借用工作区。|

<a id="windows-and-displays"></a>
### 窗口与显示器

|命令|行为|
| --- | --- |
|`window focus left` / `right` / `up` / `down`|聚焦相邻平铺窗口。|
|`window cycle next` / `previous`|在可见的 Tatami 工作区内循环切换。|
|`window resize grow` / `shrink`|按一个步长调整聚焦的 BSP 分割。|
|`window swap left` / `right` / `up` / `down`|沿指定方向交换聚焦的平铺窗口。|
|`window toggle-fullscreen`|切换聚焦窗口的 Tatami 布局全屏状态。|
|`window toggle-floating` / `toggle-shared-floating`|切换聚焦应用在工作区或共享应用中的平铺、置顶模式。|
|`display focus next` / `previous`|聚焦相邻显示器的工作区。|

CLI 和手势窗口循环立即执行。按住修饰键的切换会话仅用于实际全局快捷键。

<a id="layout-and-tiling"></a>
### 布局与平铺

|命令|行为|
| --- | --- |
|`layout toggle-orientation`|切换聚焦分割的方向。|
|`layout balance`|重新均衡活动布局。|
|`layout toggle-tiling`|全局暂停或恢复 Tatami 平铺。|

<a id="focused-app"></a>
### 聚焦的应用

|命令|行为|
| --- | --- |
|`app toggle-workspace`|若聚焦应用已属于当前工作区，则移除；否则从活动方案内其他工作区移入，并设为平铺。|
|`app toggle-shared`|把聚焦应用以平铺模式加入共享应用，已共享则移除。|

<a id="hooks"></a>
### 钩子

`tatami hook list` 列出所有配置的钩子，包括禁用和无效项。可在**设置 → 钩子**中管理，或直接编辑 `config.toml` 中的 `[[hooks]]`。手动更改仍受支持并实时生效。

支持 `tatamiLaunched`、`profileChanged`、`workspaceActivated`、`hud`。`tatamiLaunched` 在启动确定活动方案后，每个 Tatami 进程仅发送一次，包含该方案并省略 `previousProfile`、`workspace`、`display`、`hud`。它与启动时的 `profileChanged` 独立，可订阅任一或两者。`hud` 向 SketchyBar 等集成传递简洁的操作反馈。

编辑器分别保存可执行文件和各参数，直接对应 `command[0]` 与其余 argv。Tatami 不拼接 shell 命令，不按空格拆分、不解释引号或展开变量。需要 shell 语法时，明确选择 `/bin/zsh`，分别传入 `-lc` 和脚本。fish 使用 `which fish` 返回的路径，再分别传入 `-c` 和命令文本。例如 `command ls` 绕过用户定义的 `ls` 函数。钩子事件通过标准输入发送，读取 stdin 的命令会收到该 JSON。

完整事件、标准输入、环境、工作目录和超时约定见[配置参考](https://pangmo5.dev/Tatami/zh-Hans/configuration.html#hooks)。

<a id="json-output-and-exit-status"></a>
## JSON 输出与退出状态

在叶子命令之后加上 `--json`，不能放在 `tatami --json profile list` 这样的父级位置。

示例：

```sh
tatami profile list --json
tatami workspace apps "Coding" --profile "Dual" --json
tatami window focus left --json
```

成功的 JSON 写入标准输出，分发器结果如下：

```json
{
  "command": "window.focus.left",
  "title": "Focus left",
  "status": "accepted"
}
```

`command` 和 `status` 是稳定脚本字段；`title` 跟随运行中应用的语言，用于显示。配置方案、工作区、应用、钩子和修改命令返回包含标识符与元数据的结构化对象，不包装普通文本。

参数解析后，失败会向标准错误写入 `{"error":"…"}` 并以非零码退出。ArgumentParser 的用法和帮助仍为普通文本。请求 `--json` 时，新 CLI 会拒绝旧应用返回的普通输出，不会静默当成机器可读数据。

<a id="socket-and-development-isolation"></a>
## 套接字与开发隔离

默认两个进程使用当前用户 Darwin 临时目录中的 `tatami.socket`。将 `TATAMI_SOCKET_PATH` 设为绝对路径可隔离开发应用与 CLI，二者必须收到完全相同的值。

```sh
socket="${TMPDIR%/}/tatami-example.socket"
TATAMI_SOCKET_PATH="$socket" /path/to/Tatami.app/Contents/MacOS/Tatami &
TATAMI_SOCKET_PATH="$socket" /path/to/tatami workspace list
```

套接字由应用持有。应用未运行时，CLI 以非零码退出并提示确认 Tatami 是否正在运行。

<a id="scripting-examples"></a>
## 脚本示例

使用 UUID 选择，并用 `jq` 验证 JSON 约定：

```sh
profile_id="$(tatami profile list --json | jq -r '.[] | select(.isActive).id')"
tatami workspace list --profile "$profile_id" --json \
  | jq -r '.[] | [.id, .name, .kind] | @tsv'
```

无法提交操作命令时立即失败：

```sh
if ! result="$(tatami layout balance --json)"; then
  printf 'Tatami layout command failed\n' >&2
  exit 1
fi
printf '%s\n' "$result" | jq -e '.status == "accepted"' >/dev/null
```
