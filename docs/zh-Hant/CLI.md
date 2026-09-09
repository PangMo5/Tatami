<!-- LANGUAGE-LINKS:START -->
[English](../CLI.md) · [한국어](../ko/CLI.md) · [日本語](../ja/CLI.md) · [简体中文](../zh-Hans/CLI.md) · [繁體中文](CLI.md)
<!-- LANGUAGE-LINKS:END -->

<a id="tatami-command-line-reference"></a>
# Tatami 命令列參考

App 套件內包含 `tatami` 執行檔。CLI 與執行中的 App 通訊，請先啟動 Tatami 再傳送指令。

<a id="install"></a>
## 安裝

開啟**設定 → 一般 → 命令列 → 安裝**。Tatami 在 `/usr/local/bin/tatami` 建立符號連結，安裝或移除時 macOS 會要求管理者密碼。連結指向 App 套件，在相同路徑取代 App 會同時更新 CLI；移動或重新命名 App 後請重新安裝連結。

同時檢查執行檔與執行中的 App：

```sh
tatami --version     # bundled CLI version, no app connection required
tatami version       # version reported by the running Tatami app
```

<a id="command-overview"></a>
## 指令概覽

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

執行 `tatami help`、`tatami help <command>`，或在指令後加上 `--help`，查看 ArgumentParser 目前的用法。

<a id="select-profiles-and-workspaces"></a>
## 選擇設定組合與工作空間

`<profile>` 與 `<workspace>` 可使用目前名稱或 UUID。未提供 `--profile` 時，工作空間名稱在作用中設定組合內解析；UUID 全域唯一，因此不需 `--profile` 也可選中非作用中組合。`workspace borrow from` 例外：借用只接受作用中組合內的工作空間，需要時先切換組合。

搜尋範圍內名稱重複時，不進行變更，回報失敗並列出所有候選 UUID。請用其中一個 UUID 重試。

原有平面式指令保留為相容別名，供既有指令稿使用。它們不出現在根說明中，讓新用法依領域組織：

- `tatami list-workspaces` 等同於對作用中設定組合執行 `tatami workspace list`。
- `tatami list-apps <workspace>` 等同於對作用中設定組合執行 `tatami workspace apps <workspace>`。
- `tatami activate <workspace>` 等同於對作用中設定組合執行 `tatami workspace activate <workspace>`。

重新命名與複製以交易方式更新 `config.toml`。複製會先拷貝儲存的排列，再發布新設定；排列拷貝失敗時設定保持不變。

CLI 複製整個項目，不開啟選擇面板。`workspace duplicate` 的副本位於同一組合，因此清空新工作空間按鍵與明確的啟用、指派、借用快速鍵。`profile duplicate` 清空新組合的切換快速鍵與自動啟用規則，但保留工作空間快速鍵，因為它們依組合隔離。要選擇個別工作空間、App、設定或排列，請在 App 中複製。

<a id="run-dispatcher-commands-by-domain"></a>
## 依領域執行操作指令

`profile`、`workspace`、`window`、`display`、`layout` 與 `app` 涵蓋三指、四指手勢可綁定的全部執行能力。非啟用操作透過 `GestureAction` 對應，使用與手勢和全域快速鍵相同的 `HotKeyAction` 分派器；沒有通用 `action` 入口。

大多數操作回傳 `accepted`，表示執行中的 App 已驗證指令並交給共用 reducer，不代表後續輔助使用或視窗操作已改變視窗。例如 `window focus left` 可能沒有相鄰視窗，App 指令也可能在沒有聚焦 App 時到達。

`profile activate` 與 `workspace activate` 會等待完整啟用流程，回傳 `completed` 或最終失敗。暫存區僅供借用，請使用 `workspace borrow from <workspace>`。

切換指令不具冪等性。用戶端結果中斷或未知時，先檢查狀態，不要盲目重試，否則可能復原首次操作。

<a id="profiles-and-workspaces"></a>
### 設定組合與工作空間

|指令|行為|
| --- | --- |
|`profile activate <profile>`|啟用設定組合並等待最終完成。|
|`workspace activate <workspace> [--profile …]`|啟用工作空間，必要時啟用所屬組合，再等待完成。|
|`workspace next` / `previous` / `recent`|依工作空間記錄或順序切換。|
|`workspace move-app next` / `previous`|把聚焦 App 移到相鄰工作空間並切換。|
|`workspace assign-app to <workspace> [--profile …]`|保留現有工作空間成員關係並新增聚焦 App，必要時切換組合，再啟用目標。|
|`workspace assign-app next` / `previous` / `recent`|保留現有成員關係並新增聚焦 App，然後切換到相對工作空間。|
|`workspace borrow from <workspace>`|為作用中組合的工作空間開啟互動式借用方向選擇器。|
|`workspace borrow next` / `previous` / `recent`|借用相對工作空間。|
|`workspace dismiss-borrow`|歸還游標所在顯示器的借用工作空間。|

儲存 App 歸屬或排列的指令預設會開啟確認提示視窗。確認後才會變更設定，並在同一提示視窗中顯示結果。可在設定 → 一般 → 變更前確認中逐項設定。「不再詢問」只會在確認後關閉對應操作的確認；取消則維持開啟。

<a id="windows-and-displays"></a>
### 視窗與顯示器

|指令|行為|
| --- | --- |
|`window focus left` / `right` / `up` / `down`|聚焦相鄰並排視窗。|
|`window cycle next` / `previous`|在可見的 Tatami 工作空間內循環切換。|
|`window resize grow` / `shrink`|依一個步長調整聚焦的 BSP 分割。|
|`window swap left` / `right` / `up` / `down`|沿指定方向交換聚焦的並排視窗。|
|`window toggle-fullscreen`|切換聚焦視窗的 Tatami 排列全螢幕狀態。|
|`window toggle-floating` / `toggle-shared-floating`|切換聚焦 App 在工作空間或共用 App 中的並排、置頂模式。|
|`display focus next` / `previous`|聚焦相鄰顯示器的工作空間。|

CLI 與手勢視窗循環立即執行。按住輔助鍵的切換工作階段僅用於實際全域快速鍵。

<a id="layout-and-tiling"></a>
### 排列與並排

|指令|行為|
| --- | --- |
|`layout toggle-orientation`|切換聚焦分割的方向。|
|`layout balance`|重新平均調整作用中排列。|
|`layout toggle-tiling`|全域暫停或恢復 Tatami 並排。|

<a id="focused-app"></a>
### 聚焦的 App

|指令|行為|
| --- | --- |
|`app toggle-workspace`|若聚焦 App 已屬於目前工作空間，則移除；否則從作用中組合內其他工作空間移入，並設為並排。|
|`app toggle-shared`|把聚焦 App 以並排模式加入共用 App，已共用則移除。|

<a id="hooks"></a>
### 掛鉤

`tatami hook list` 列出所有設定的 Hook，包含停用與無效項。可在**設定 → Hook**中管理，或直接編輯 `config.toml` 中的 `[[hooks]]`。手動變更仍受支援並即時生效。

支援 `tatamiLaunched`、`profileChanged`、`workspaceActivated`、`hud`。`tatamiLaunched` 在啟動確定作用中組合後，每個 Tatami 程序僅傳送一次，包含該組合並省略 `previousProfile`、`workspace`、`display`、`hud`。它與啟動時的 `profileChanged` 獨立，可訂閱任一或兩者。`hud` 向 SketchyBar 等整合傳遞精簡的操作回饋。

編輯器分別儲存執行檔和各參數，直接對應 `command[0]` 與其餘 argv。Tatami 不串接 shell 指令，不依空白拆分、不解讀引號或展開變數。需要 shell 語法時，明確選擇 `/bin/zsh`，分別傳入 `-lc` 與指令稿。fish 使用 `which fish` 回傳的路徑，再分別傳入 `-c` 和指令文字。例如 `command ls` 略過使用者定義的 `ls` 函式。Hook 事件透過標準輸入傳送，讀取 stdin 的指令會收到該 JSON。

完整事件、標準輸入、環境、工作目錄與逾時約定見[設定參考](https://pangmo5.dev/Tatami/zh-Hant/configuration.html#hooks)。

<a id="json-output-and-exit-status"></a>
## JSON 輸出與結束狀態

在末端指令之後加上 `--json`，不能放在 `tatami --json profile list` 這樣的父層位置。

範例：

```sh
tatami profile list --json
tatami workspace apps "Coding" --profile "Dual" --json
tatami window focus left --json
```

成功的 JSON 寫入標準輸出，分派器結果如下：

```json
{
  "command": "window.focus.left",
  "title": "Focus left",
  "status": "accepted"
}
```

`command` 與 `status` 是穩定的指令稿欄位；`title` 跟隨執行中 App 的語言，用於顯示。設定組合、工作空間、App、Hook 和修改指令回傳包含識別碼與中繼資料的結構化物件，不包裝一般文字。

參數解析後，失敗會向標準錯誤寫入 `{"error":"…"}` 並以非零代碼結束。ArgumentParser 的用法與說明仍為一般文字。要求 `--json` 時，新 CLI 會拒絕舊 App 回傳的一般輸出，不會靜默當成機器可讀資料。

<a id="socket-and-development-isolation"></a>
## Socket 與開發環境隔離

預設兩個程序使用目前使用者 Darwin 暫存目錄中的 `tatami.socket`。將 `TATAMI_SOCKET_PATH` 設為絕對路徑可隔離開發 App 與 CLI，兩者必須收到完全相同的值。

```sh
socket="${TMPDIR%/}/tatami-example.socket"
TATAMI_SOCKET_PATH="$socket" /path/to/Tatami.app/Contents/MacOS/Tatami &
TATAMI_SOCKET_PATH="$socket" /path/to/tatami workspace list
```

Socket 由 App 持有。App 未執行時，CLI 以非零代碼結束並提示確認 Tatami 是否正在執行。

<a id="scripting-examples"></a>
## 指令稿範例

使用 UUID 選擇，並用 `jq` 驗證 JSON 約定：

```sh
profile_id="$(tatami profile list --json | jq -r '.[] | select(.isActive).id')"
tatami workspace list --profile "$profile_id" --json \
  | jq -r '.[] | [.id, .name, .kind] | @tsv'
```

無法提交操作指令時立即失敗：

```sh
if ! result="$(tatami layout balance --json)"; then
  printf 'Tatami layout command failed\n' >&2
  exit 1
fi
printf '%s\n' "$result" | jq -e '.status == "accepted"' >/dev/null
```
