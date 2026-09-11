<!-- LANGUAGE-LINKS:START -->
[English](../CONFIGURATION.md) · [한국어](../ko/CONFIGURATION.md) · [日本語](../ja/CONFIGURATION.md) · [简体中文](../zh-Hans/CONFIGURATION.md) · [繁體中文](CONFIGURATION.md)
<!-- LANGUAGE-LINKS:END -->

<a id="configuration"></a>
# 設定指南

Tatami 從以下路徑讀取設定：

```
~/.config/tatami/config.toml
```

路徑支援 XDG。設定 `$XDG_CONFIG_HOME` 後使用 `$XDG_CONFIG_HOME/tatami/config.toml`。首次啟動建立檔案，App 內變更時寫回；手動編輯也即時生效，可納入 dotfiles 管理。

外部寫入者必須參與 `NSFileCoordinator`，或先寫暫存檔，再不可分割地取代 `config.toml`。Tatami 會偵測並拒絕與自身設定交易競爭的取代。不支援跨重新命名持有作用中文件描述符繼續寫入，例如先開啟 `config.toml`，其他程序取代路徑後仍截斷或寫入該描述符；POSIX rename 無法重新導向已開啟的描述符。採用暫存檔與不可分割取代的編輯器符合約定。

首次啟動會開啟**引導設定**，依 App 資訊與顯示器建立草稿，在安全的虛擬桌面學習功能。選擇**套用設定**時才寫入檔案，可從**設定 → 一般 → 執行引導設定**再次開啟。

檔案分為四個最上層部分：

- **`[settings.*]`：** 下文說明的全域偏好
- **`[[sharedApps]]`：** 在每個工作空間並排或置頂的 App
- **`[[profiles]]`：** 工作空間及其 App 指派
- **`[[hooks]]`：** 由生命週期與操作回饋事件觸發的程式

<a id="shortcut-syntax"></a>
## 快速鍵語法

快速鍵使用 skhd 風格字串：零個或多個輔助鍵以 `+` 連接，後接 ` - ` 與按鍵。

```
ctrl + alt - h
alt + shift - tab
ctrl + alt + shift + cmd - z
```

輔助鍵：`ctrl`、`alt`（option）、`shift`、`cmd`。按鍵可為字母、數字、`tab`、`return`、方向鍵（`left`/`right`/`up`/`down`）、標點等。

<a id="settingsgeneral"></a>
## `[settings.general]`

|鍵|型別|預設值|說明|
| --- | --- | --- | --- |
|`launchAtLogin`|bool|`false`|將 Tatami 註冊為登入項目，登入時啟動。|
|`checkForUpdatesAutomatically`|bool|`true`|定期檢查新版本。|
|`checkInterval`|string|`"daily"`|背景更新檢查頻率：`hourly`、`daily` 或 `weekly`。|
|`debugLogging`|bool|`false`|向 `~/.config/tatami/tatami.log` 附加診斷事件，首次啟用時清空原內容。|

<a id="settingsconfirmations"></a>
## `[settings.confirmations]`

可分別設定各項操作的確認，預設全部開啟。選取「不再詢問」並確認後，只會關閉對應操作的確認。取消不會變更偏好。舊的全域確認設定會移轉到這些選項，明確設定的單項值優先。

|鍵|預設值|操作|
| --- | --- | --- |
|`addWorkspaceApp`|`true`|將 App 指派到工作空間|
|`moveWorkspaceApp`|`true`|在工作空間之間移動 App|
|`removeWorkspaceApp`|`true`|從工作空間移除 App|
|`floatWorkspaceApp`|`true`|將工作空間 App 置頂|
|`tileWorkspaceApp`|`true`|並排工作空間 App|
|`unmanageWorkspaceApp`|`true`|維持工作空間 App 原狀|
|`addSharedApp`|`true`|加入共用 App|
|`removeSharedApp`|`true`|移除共用 App|
|`floatSharedApp`|`true`|將共用 App 置頂|
|`tileSharedApp`|`true`|並排共用 App|
|`unmanageSharedApp`|`true`|維持共用 App 原狀|
|`deleteWorkspace`|`true`|刪除工作空間|
|`deleteProfile`|`true`|刪除設定組合|
|`deleteWorkspaceChain`|`true`|刪除工作空間鏈|
|`deleteHook`|`true`|刪除鉤子|
|`removeOverlayException`|`true`|移除視窗顯示例外|
|`copyWorkspace`|`true`|複製工作空間設定|
|`copyProfile`|`true`|複製設定組合設定|
|`resetSetup`|`true`|重新開始引導設定|
|`reloadSetup`|`true`|重新載入引導設定草稿|
|`applySetup`|`true`|套用引導設定草稿|
|`applySetupRecommendation`|`true`|套用設定建議|
|`deleteSetupWorkspace`|`true`|從設定草稿刪除工作空間|
|`deleteSetupProfile`|`true`|從設定草稿刪除設定組合|
|`uninstallCLI`|`true`|解除安裝命令列工具|

<a id="settingsvisibility"></a>
## `[settings.visibility]`

|鍵|型別|預設值|說明|
| --- | --- | --- | --- |
|`overlayAwareApps`|string[]|`[]`|擁有持續高層控制項的 App 套件 ID。註冊程序在非零 WindowServer 層有可見最上層 AX 視窗時，Tatami 保持程序可見，但把一般視窗排除在焦點、循環切換、排列、拖移與成員操作之外；它們仍可能出現在 Mission Control。|

這是明確的逐 App 例外，不是所有浮動視窗的通用規則。沒有符合的高層最上層視窗時，App 恢復一般隱藏；每次工作空間或借用顯示交易都會重新評估。

```toml
[settings.visibility]
overlayAwareApps = ["notion.id"]
```

症狀、App 範例與設定操作流程見[疑難排解](https://github.com/PangMo5/Tatami/blob/main/docs/TROUBLESHOOTING.md#a-floating-control-disappears-or-brings-its-app-back)。

<a id="settingsmenubar"></a>
## `[settings.menuBar]`

|鍵|型別|預設值|說明|
| --- | --- | --- | --- |
|`showWorkspaceIcon`|bool|`true`|在選單列顯示作用中工作空間圖像。|
|`showWorkspaceName`|bool|`true`|在選單列顯示作用中工作空間名稱。|
|`showProfileIcon`|bool|`true`|有多個設定組合時顯示作用中組合圖像。|
|`showProfileName`|bool|`false`|有多個設定組合時顯示作用中組合名稱。|

<a id="settingshud"></a>
## `[settings.hud]`

用來確認操作的簡短回饋。為相容保留歷史表名 `hud`，App 中稱為**操作回饋**。`enabled` 是總開關，其餘鍵選擇哪些操作顯示回饋。

|鍵|型別|預設值|說明|
| --- | --- | --- | --- |
|`enabled`|bool|`true`|所有操作回饋的總開關。|
|`workspaceSwitch`|bool|`true`|切換時顯示工作空間名稱。|
|`windowCycle`|bool|`true`|按住視窗切換輔助鍵顯示精簡清單。用快速鍵或方向鍵繼續，Return、放開輔助鍵或點按確認，Escape 取消。輕按不顯示清單。|
|`profileSwitch`|bool|`true`|手動或自動切換組合時顯示名稱。|
|`floating`|bool|`true`|顯示工作空間與共用 App 的置頂狀態變化，鍵名為相容而保留。|
|`appMembership`|bool|`true`|App 加入或移出工作空間、共用 App 時顯示回饋。|
|`tilingPaused`|bool|`true`|已暫停／繼續並排。|
|`fullscreen`|bool|`true`|進入或離開工作空間全螢幕放大。|
|`borrow`|bool|`true`|顯示借用、歸還及方向選擇提示。|
|`layout`|bool|`true`|為平均排列等沒有獨立視覺提示的指令顯示回饋。|
|`position`|string|`"top"`|簡短操作回饋的位置：`topLeading`、`top`、`topTrailing`、`leading`、`center`、`trailing`、`bottomLeading`、`bottom` 或 `bottomTrailing`。互動式 App 視窗清單獨立維持置中。|
|`size`|string|`"default"`|簡短操作回饋的整體大小：`small`、`default` 或 `large`。互動式 App 視窗清單維持固定大小。|
|`durationMs`|int|`900`|進入和離開動畫之間完全可見的時間，單位毫秒。帶後續提示時顯示兩倍時間。|

<a id="settingslayout"></a>
## `[settings.layout]`

|鍵|型別|預設值|說明|
| --- | --- | --- | --- |
|`gapInner`|int|`8`|相鄰並排視窗之間的像素間距。|
|`gapOuter`|int|`8`|並排區域與螢幕邊緣之間的像素間距。|
|`autoBalance`|string|`"none"`|每次插入或移除後重新平均調整分割，可選 `none`、`horizontal`、`vertical`、`both`。舊 bool 仍可解析：`true` → `both`、`false` → `none`。|
|`splitType`|string|`"auto"`|新視窗分割區域時的預設軸：`auto`（依寬高比）、`horizontal`、`vertical`。|
|`windowPlacement`|string|`"second"`|新分割中放置新視窗的一側：`first`（上、左）或 `second`（下、右）。|

<a id="window-and-layout-restoration"></a>
### 視窗與配置回復

Tatami 會分別記住每個工作空間的分割方向、比例和全螢幕狀態。視窗關閉或陸續開啟時，現有視窗會填滿可用空間，同時保留缺少視窗的位置。重新開啟的視窗可以回到這些位置。手動調整大小、重新排列或切換全螢幕等配置操作，會依目前的視窗重新儲存配置。

由 macOS 和各個 App 決定重新開啟哪些視窗。Tatami 會將記住的配置套用至這些視窗，不會自行重新開啟文件。以下 macOS 設定分別控制不同情況：

- **系統設定 → 桌面與 Dock**中的**結束應用程式時關閉視窗**：關閉此選項後，支援此功能的 App 可以在下次啟動時重新開啟視窗。開啟時，App 可能改為開啟新視窗。
- 登出、重新啟動或關機對話框中的**再次登入時重新打開視窗**：勾選後，macOS 會在下次登入時重新開啟 App 和視窗。啟用 Tatami 的**登入時啟動**，或在登入後開啟 Tatami，即可套用配置。

Tatami 依 App 和視窗順序比對配置位置，而非文件名稱。如果 App 改變重新建立視窗的順序，其他文件可能佔用原先儲存的位置。新視窗也可以使用舊位置。工作空間的**自動開啟**設定用於啟動 App，與 macOS 的文件回復各自獨立。

<a id="settingsfocus"></a>
## `[settings.focus]`

|鍵|型別|預設值|說明|
| --- | --- | --- | --- |
|`mouseFollowsFocus`|bool|`false`|把游標移到 Tatami 聚焦的視窗。方向焦點、App 視窗切換、工作空間變化、關閉後還原焦點、交換、分割方向與全螢幕放大的進入離開都會移動游標。置頂和維持原狀使用實際視窗邊框。透過 Dock、Spotlight 等外部啟用 App 時，跟隨系統實際置前的視窗，而非工作空間最近視窗。點按、結束拖移、拖移交換或分割、拖移彈回等由游標引起的變化不移動游標。放大縮小與平均排列也排除在外，避免按住鍵時每次都重新置中。|
|`mouseHidesOnFocus`|bool|`false`|切換工作空間時隱藏游標，直到滑鼠移動。|
|`focusFollowsMouse`|bool|`false`|游標移動時聚焦其下方視窗。|
|`refocusOnClose`|bool|`true`|聚焦視窗關閉且 App 已無視窗時，依最近使用順序，把焦點移到工作空間中剩下的視窗。|
|`focusFollowsMouseIgnoreFullscreen`|bool|`true`|啟用焦點跟隨游標時，不切換到佔滿整部顯示器的全螢幕或最大化視窗。|
|`focusFollowsMouseDisableHotkey`|string|`"Alt"`|暫時停止焦點跟隨游標的輔助鍵：`None`、`Alt`、`Cmd`、`Ctrl`、`Shift`。|

<a id="settingsswitching"></a>
## `[settings.switching]`

|鍵|型別|預設值|說明|
| --- | --- | --- | --- |
|`loop`|bool|`true`|從最後一個工作空間繼續切換至第一個，反之亦然。|
|`skipEmpty`|bool|`false`|前後切換時略過沒有執行中 App 的工作空間。|
|`followAppFocus`|bool|`true`|啟用 App 時切換到其所屬工作空間。|
|`cycleAcrossDisplays`|bool|`false`|在所有顯示器間切換前後工作空間，而非僅游標所在螢幕。鍵名為相容而保留。|
|`recentAcrossDisplays`|bool|`true`|所有顯示器共用最近工作空間記錄。目標已在其他顯示器可見時，直接在那裡聚焦，不移動它。設為 `false` 使用嚴格的逐顯示器記錄。|
|`switchToRecentWhenEmpty`|bool|`false`|作用中工作空間最後一個視窗關閉，且沒有並排視窗或該工作空間專屬置頂視窗時，切換到最近工作空間。共用 App 不計入，因為它們加入所有工作空間。|
|`cycleSameAppWindows`|bool|`false`|前後視窗切換粒度。預設 `false` 依 App 切換並還原該 App 最近視窗；`true` 走訪每個視窗，包含同一 App 的多個視窗。作用中工作空間的並排、置頂和維持原狀視窗參與；借用時兩側並排區域組成同一順序。鍵名為相容保留。|
|`includeSharedAppsInWindowSwitcher`|bool|`true`|在 App 視窗切換器中包含共用 App。借用時，非並排共用視窗與兩側並排區域一起參與；`false` 在所有情境中排除共用 App。|
|`toggleBorrowOnRepeat`|bool|`true`|再次借用已在旁邊的工作空間會歸還並還原主工作空間；`false` 則移動借來的工作空間。|
|`borrowDefaultEdge`|string?|_（未設定）_|預設借用停靠位置：`top`、`bottom`、`left`、`right`。未設定時等待 h/j/k/l 或方向鍵；工作空間的 `borrowEdge` 會覆寫此值。|
|`borrowFraction`|double|`0.4`|借用區域沿分割軸佔螢幕的比例（0.1…0.9），工作空間的 `borrowFraction` 會覆寫此值。|

Tatami 執行期間，鍵盤視窗切換會為每個工作空間分別記住最近的焦點順序。短按並放開「下一個視窗」快速鍵，即可回到上次使用的 App 或視窗。按住修飾鍵可瀏覽清單，清單順序會維持不變，直到放開或取消。切換工作空間或重新排列視窗不會清除該空間的紀錄。視窗切換手勢仍依排列順序移動。

<a id="settingsgestures"></a>
## `[settings.gestures]`

|鍵|型別|預設值|說明|
| --- | --- | --- | --- |
|`enabled`|bool|`false`|辨識設定的三指與四指觸控式軌跡板滑動。|
|`threshold`|double|`0.3`|觸發操作所需的滑動距離，值越低越靈敏，保留兩位小數。|
|`threeFinger`|table|左 → `nextWorkspace`，右 → `previousWorkspace`|三指向 `left`、`right`、`up`、`down` 滑動的操作，缺少的方向為 `none`。|
|`fourFinger`|table|所有方向 → `none`|四指向 `left`、`right`、`up`、`down` 滑動的操作。|

每個方向儲存一個動作字串。App 的巢狀選單會自動寫入穩定 UUID，是設定組合與工作空間操作最方便的方式。

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

可用的固定動作字串：

- **工作空間：** `nextWorkspace`、`previousWorkspace`、`recentWorkspace`、`moveAppToNextWorkspace`、`moveAppToPreviousWorkspace`、`assignAppToRecentWorkspace`、`assignAppToNextWorkspace`、`assignAppToPreviousWorkspace`
- **焦點與顯示器：** `focusNextDisplay`、`focusPreviousDisplay`、`focusLeft`、`focusRight`、`focusUp`、`focusDown`
- **視窗切換：** `cycleNextWindow`、`cyclePreviousWindow`
- **排列：** `growWindow`、`shrinkWindow`、`swapLeft`、`swapRight`、`swapUp`、`swapDown`、`toggleOrientation`、`toggleFullscreen`、`balanceLayout`
- **App 與並排：** `toggleFloating`、`toggleSharedFloating`、`toggleTiling`、`toggleAppInWorkspace`、`toggleAppInSharedApps`。`floating` 保留為**置頂**的穩定設定識別碼。
- **借用：** `borrowRecentWorkspace`、`borrowNextWorkspace`、`borrowPreviousWorkspace`、`dismissBorrow`
- **未綁定：** `none`

目標專用操作附加穩定識別碼：`activateWorkspace:<workspace UUID>`、`assignAppToWorkspace:<workspace UUID>`、`borrowWorkspace:<workspace UUID>` 或 `activateProfile:<profile UUID>`。借用指定工作空間要求其組合處於作用中；啟用或指派工作空間則可以先切換到所屬組合。

舊設定 `fingerCount = 3` 或 `4` 會自動移轉：該手指數量的左右保留原有前後工作空間行為，其他方向及手指數量維持未綁定。

<a id="settingsmarker"></a>
## `[settings.marker]`

角落的小圓點用來識別放大、置頂與借來的視窗。

|鍵|型別|預設值|說明|
| --- | --- | --- | --- |
|`fullscreenEnabled`|bool|`true`|聚焦工作空間全螢幕放大的視窗時顯示圓點。|
|`fullscreenColorHex`|string|`"#007AFF"`|全螢幕圓點顏色（`#RRGGBB`）。|
|`floatingEnabled`|bool|`true`|置頂視窗始終顯示圓點，便於一眼辨識狀態。|
|`floatingColorHex`|string|`"#FF9500"`|置頂圓點顏色（`#RRGGBB`）。|
|`borrowEnabled`|bool|`true`|借用可見時，為每個借來的視窗顯示工作空間圖像。|
|`borrowColorHex`|string|`"#AF52DE"`|借用標記顏色（`#RRGGBB`）。|
|`size`|double|`14`|圓點直徑，單位點。借用標記繪製得更大，確保符號清楚。|
|`corner`|string|`"bottomTrailing"`|圓點所在視窗角落：`topLeading`、`topTrailing`、`bottomLeading`、`bottomTrailing`。|
|`hideOnHover`|bool|`true`|游標停在圓點上方時淡化。|

<a id="settingsshortcuts"></a>
## `[settings.shortcuts]`

多數值為 skhd 風格字串，省略鍵則不綁定。沒有 `config.toml` 的新設定會加入[建議預設值](#recommended-defaults)，所有快速鍵都可重新錄製或清除。例外是下方三個 `*Modifiers` 陣列，用於每個工作空間的**按鍵**模型。

<a id="workspace-keys-switch--assign--borrow"></a>
### 工作空間按鍵：切換、指派、借用

不用為每個工作空間綁定三個獨立快速鍵，只需指定一個字元的**按鍵**（`keyEquivalent`），與三種全域輔助鍵組合之一搭配選擇操作。

|鍵|型別|預設值|操作|
| --- | --- | --- | --- |
|`keyEquivalentModifiers`|string[]|`["ctrl", "alt"]`|+ 工作空間按鍵 → **切換**到該工作空間|
|`assignModifiers`|string[]|`["ctrl", "alt", "shift"]`|+ 工作空間按鍵 → **指派**聚焦 App 並切換過去|
|`borrowModifiers`|string[]|`["ctrl", "alt", "cmd"]`|+ 工作空間按鍵 → **借用**到目前螢幕|

輔助鍵代碼為 `ctrl`、`alt`、`shift`、`cmd`。空陣列停用該動作的按鍵組合，避免單獨按鍵攔截輸入。

上表的**預設值**用於*既有*設定缺少鍵時。全新安裝會使用建議組合 `keyEquivalentModifiers = ["ctrl", "alt", "shift"]` 與 `assignModifiers = ["alt", "shift", "cmd"]`，詳見[建議預設值](#recommended-defaults)。

同樣三種輔助鍵也用於**最近、下一個、上一個**目標，各目標有自己的按鍵。

|鍵|型別|說明|
| --- | --- | --- |
|`recentWorkspaceKey`|string?|最近工作空間按鍵，與切換、指派或借用輔助鍵組合。|
|`nextWorkspaceKey`|string?|下一個工作空間按鍵。|
|`previousWorkspaceKey`|string?|上一個工作空間按鍵。|

上述操作都可設定**明確覆寫**快速鍵，優先於輔助鍵加工作空間按鍵組合。

- 每個工作空間可指定 `activateShortcut`、`assignAppShortcut`、`borrowShortcut`，見下方工作空間部分。
- **每個導覽目標：** `switchTo{Recent,Next,Previous}Workspace`、`assign{Recent,Next,Previous}Workspace`、`borrow{Recent,Next,Previous}Workspace`，均使用 skhd 字串。

工作空間按鍵與明確的快速鍵只在所屬組合內生效，不同組合可重複使用。全域快速鍵仍與所有組合檢查衝突，拷貝與複製也會在儲存到目標組合前驗證所選變更。

未設定預設邊緣（`settings.switching.borrowDefaultEdge` 或工作空間的 `borrowEdge`）時，借用會等待 h/j/k/l 或方向鍵。`dismissBorrow` 歸還借用並還原主工作空間佔滿螢幕。

<a id="action-shortcuts"></a>
### 操作快速鍵

|鍵|操作|
| --- | --- |
|`focusLeft` / `focusRight` / `focusUp` / `focusDown`|聚焦指定方向的並排區域，在邊緣可跨入借用區域。|
|`swapLeft` / `swapRight` / `swapUp` / `swapDown`|沿指定方向交換聚焦區域。|
|`resizeGrow` / `resizeShrink`|依上層分割的左右或上下方向，擴大或縮小目前選取視窗的區域|
|`toggleOrientation`|切換聚焦分割的方向。|
|`toggleFullscreen`|把聚焦視窗放大到整個工作空間。|
|`balance`|套用設定的 `autoBalance` 軸。關閉自動平均排列時，依目前視窗順序重建標準 BSP 拓樸與比例。|
|`cycleNextWindow` / `cyclePreviousWindow`|在可見的 Tatami 工作空間內切換 App 或視窗。排除 Command-Tab 中無關的執行中 App，也能跨越 Command-backtick 的單一 App 範圍。|
|`moveToNextWorkspace` / `moveToPreviousWorkspace`|把聚焦 App 移到前後工作空間並跟隨過去。|
|`dismissBorrow`|歸還借用工作空間，還原主工作空間佔滿螢幕。|
|`focusNextDisplay` / `focusPreviousDisplay`|聚焦前後顯示器的作用中工作空間，到邊緣後循環。|
|`toggleFloating`|讓聚焦 App 在目前工作空間置頂，需要時加入該工作空間。再次執行恢復並排。|
|`toggleSharedFloating`|讓聚焦 App 在所有地方置頂，需要時加入共用 App。關閉後變為共用*並排*，用 `toggleAppInSharedApps` 移除成員關係。|
|`toggleFocusedAppInActiveWorkspace`|把聚焦視窗的 App 加入作用中工作空間，已屬於時則移除。|
|`toggleAppInSharedApps`|把聚焦 App 加入共用 App，在每個工作空間並排；已共用則移除。|
|`toggleSpaceActivated`|暫停或恢復並排|

<a id="recommended-defaults"></a>
### 建議預設值

沒有 `config.toml` 的全新設定會提供可立即使用的組合。`⌃⌥` 控制視窗與並排，工作空間**切換**使用 `⌃⌥⇧`，**指派**使用 `⌥⇧⌘`，避免單字元工作空間鍵與 `⌃⌥` 焦點鍵衝突。所有設定都可重新錄製或清除。

|操作|快速鍵|
| --- | --- |
|向左、下、上、右聚焦|`⌃⌥H` · `⌃⌥J` · `⌃⌥K` · `⌃⌥L`|
|向左、下、上、右交換|`⌃⌥←` · `⌃⌥↓` · `⌃⌥↑` · `⌃⌥→`|
|放大、縮小|`⌃⌥=` · `⌃⌥-`|
|切換方向|`⌃⌥S`|
|切換全螢幕|`⌃⌥⏎`|
|平衡|`⌃⌥E`|
|切換到前後視窗|`⌥⇥` · `⌥⇧⇥`|
|切換置頂狀態|`⌥⌘⏎`|
|切換共用置頂狀態|`⌥⇧⌘⏎`|
|切換並排暫停|`⌃⌥⇧⌘Z`|
|切換 App 的工作空間歸屬|`⌃⌥/`|
|切換 App 的共用狀態|`⌃⌥⇧/`|
|把 App 移到前後工作空間|`⌃⌥⇧[` · `⌃⌥⇧]`|
|聚焦前後顯示器|`⌃⌥⇧←` · `⌃⌥⇧→`|
|歸還借用工作空間|`⌃⌥⌘/`|
|最近、下一個、上一個工作空間按鍵|`\` · `.` · `,`|

工作空間的**切換、指派、借用**將上面的輔助鍵與每個工作空間按鍵，以及最近、前後按鍵組合使用。

<a id="sharedapps"></a>
## `[[sharedApps]]`

這裡的 App 加入**每個**工作空間。`layout` 可為 `tiled`（預設，參與並排）、`floating`（**置頂**，透過鏡像在所有區域上方顯示）或 `unmanaged`（**維持原狀**，保留成員關係但不移動、並排或鏡像）。可選 `autoOpen`（bool，預設 `false`）在啟用工作空間且沒有螢幕內視窗時啟動或重開 App；`iconPath` 是自動寫入的管理用字串，不應手動設定。

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

置頂不需要關閉 SIP。Tatami 用 ScreenCaptureKit 把視窗鏡像到置頂面板，需要**螢幕錄製**權限（設定 → 一般 → 權限）。App 本身取得焦點時隱藏鏡像並停止擷取。`unmanaged` 不操作實際視窗，不需該權限。

可在**工作空間 → 共用 App**中編輯並排、置頂或維持原狀。

舊 `[[floatingApps]]` 設定在首次讀取時自動移轉，每項變為 `layout = "floating"` 的共用 App。1.4 之前的 `floating` bool 也會移轉：`true` → `floating`，否則為 `tiled`。

<a id="hooks"></a>
## `[[hooks]]`

Tatami 發布以下事件時，Hook 執行程式：

- `tatamiLaunched`：啟動確定作用中組合後，每個程序傳送一次，傳入該組合，不包含 `previousProfile`、`workspace`、`display`。同一程序中後來新增的 Hook 不會重播此事件。
- `profileChanged`：作用中設定組合發生變化。啟動時不包含 `previousProfile`。
- `workspaceActivated`：工作空間啟用已在顯示器上發布可見狀態，失敗或逾時不會傳送。
- `hud`：已發布簡短操作回饋，包含傳送給 Tatami 的確切在地化標題、SF Symbol、可選副標題、持續時間、位置、大小和可選目標顯示器，供 SketchyBar 等外部介面顯示相同回饋。

啟動時的 `tatamiLaunched` 與 `profileChanged` 相互獨立，依需要選擇程序啟動或組合生命週期變化，也可同時訂閱。

在**設定 → Hook**中管理 Hook。執行檔、各參數、工作目錄、逾時和環境變數分別輸入，寫入下文相同的 `[[hooks]]` 項，因此直接編輯 `config.toml` 仍完整受支援並即時生效。

**執行測試**驗證目前編輯草稿，並用範例事件執行一次，不新增或更新 Hook，也不寫入 `config.toml`。要保留草稿，請另外選擇**儲存**。

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

|鍵|型別|預設值|說明|
| --- | --- | --- | --- |
|`id`|string|_（必填）_|唯一診斷識別碼，使用 ASCII 字母、數字、`.`、`_` 或 `-`，最長 64 個字元。|
|`event`|string|_（必填）_|`tatamiLaunched`、`profileChanged`、`workspaceActivated` 或 `hud`。|
|`enabled`|bool|`true`|是否執行該 Hook。停用的 Hook 仍會顯示在 `tatami hook list` 中。|
|`command`|string[]|_（必填）_|執行檔後接參數，每個元素是一個 argv 值。|
|`timeoutMs`|int|`5000`|執行時間上限為 100 到 300000 毫秒。|
|`workingDirectory`|string?|Tatami 設定目錄|絕對路徑，或以 `~/` 開頭的路徑。|
|`environment`|table|`{}`|新增到 App 繼承環境中的值，下方 Tatami 情境值優先。|

Tatami 直接執行 `command`，不啟動 shell、不拆詞、不解讀引號或展開變數。編輯器中 `command[0]` 是執行檔，每個參數行對應一個 argv。需要 shell 時明確使用 `command = ["/bin/zsh", "-lc", "your pipeline"]`；fish 使用 `which fish` 回傳的路徑，依 `command = ["/opt/homebrew/bin/fish", "-c", "command ls"]` 分開參數。事件 JSON 透過 stdin 傳送。包含 `/` 的執行檔依路徑處理並展開開頭的 `~/`；單純名稱從 App 繼承的 `PATH` 尋找。Finder 啟動時，絕對執行路徑最可預期。

每個 Hook 透過 stdin 接收一個帶版本的 JSON，包含 `schemaVersion`、`event`、`occurredAt`、`profile`，以及適用時的 `previousProfile`、`workspace`、`display`、`hud`。`hud` 物件包含 `title`、`symbolIconName`、`subtitle`、可選的 `subtitleSymbolIconName`、`durationMs`、`position`、`size`。能識別螢幕時，HUD 事件攜帶解析後的 `display`；工作空間鏈依受影響顯示器分別傳送該螢幕的工作空間回饋。`durationMs` 是完全可見的停留時間，外部介面另加進入離開動畫。還會設定以下便利變數：

- `TATAMI_HOOK_ID`, `TATAMI_HOOK_EVENT`
- `TATAMI_PROFILE_ID`, `TATAMI_PROFILE_NAME`
- 工作空間事件包含 `TATAMI_WORKSPACE_ID`、`TATAMI_WORKSPACE_NAME`、`TATAMI_WORKSPACE_KIND`。
- 已知顯示器時包含 `TATAMI_DISPLAY_UUID`、`TATAMI_DISPLAY_NAME`。
- `hud` 事件包含 `TATAMI_HUD_TITLE`、`TATAMI_HUD_SYMBOL_ICON_NAME`、`TATAMI_HUD_SUBTITLE`、`TATAMI_HUD_SUBTITLE_SYMBOL_ICON_NAME`、`TATAMI_HUD_DURATION_MS`、`TATAMI_HUD_POSITION`、`TATAMI_HUD_SIZE`。可選值不存在時省略，不設為空字串。

例如 SketchyBar 橋接可訂閱 `event = "hud"`，將 `command` 指向把 `TATAMI_HUD_*` 變數轉送給自訂事件的小型指令稿。stdin 也提供 JSON，需要結構化可選欄位時不必解析環境變數約定。Hook 自身的失敗或復原回饋不會再次發布為 `hud`，以防失敗 Hook 遞迴啟動自己。

stdout 與 stderr 各限 64 KiB。非零結束、訊號、啟動錯誤、輸出過量或逾時會顯示在問題清單，並在啟用時寫入偵錯記錄，不回復或阻擋組合、工作空間變化。指令執行於獨立程序工作階段；逾時或結束時先要求正常終止，再強制結束剩餘後代，包含 shell 背景工作群組。Hook 不能自行脫離為新工作階段。同一 `id` 仍執行時，新事件獨立執行，只有最新呼叫更新目前問題；修改、停用或刪除會取消舊定義的執行並清除問題。

<a id="profiles-and-workspaces"></a>
## `[[profiles]]` 與工作空間

設定組合是一組命名工作空間。可定義多個並切換，為每部顯示器重新並排，也可依連接狀態**自動啟用**。目前組合、逐顯示器記錄與全域最近順序是工作階段狀態，存於 `config.toml` 旁的 `profile-session.json`，不寫入 `config.toml`。啟動時無條件還原最後的手動組合；帶顯示器條件的組合僅在條件仍符合時還原，否則由自動解析器選擇最佳符合項目。

各組合的工作空間獨立，App 與設定可能逐漸不同。詳細資料中的**從其他設定拷貝**可展示差異，只拷貝勾選保留的變更，不必手動編輯。

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

設定組合欄位：

|鍵|型別|說明|
| --- | --- | --- |
|`id`|UUID|穩定識別碼。|
|`name`|string|顯示名稱。|
|`symbolIconName`|string?|側邊欄、選單列與切換回饋中的組合 SF Symbol，省略時使用 `rectangle.stack`。|
|`shortcut`|string?|切換到此組合的 skhd 風格快速鍵。|
|`autoActivation`|table?|顯示器符合下方條件時自動啟用，省略則僅手動。表存在但無條件時符合任何設定。|
|`workspaceChains`|table[]|跨顯示器一起切換的對等工作空間群組。目標在啟用時解析，不存入鏈；不用時省略。|

**`[profiles.autoActivation]`：** 所有鍵均可選，以 AND 組合。多個符合時選最具體的：`exactly` 高於 `contains`，條件越多越優先，相同時選擇排列更前的組合。

|鍵|型別|說明|
| --- | --- | --- |
|`displayCount`|string?|已連接顯示器數量：`"==1"`、`">=2"`、`"<=1"`。|
|`whenConnected`|string[]?|必須連接的顯示器（`"<uuid>::<name>"` 或 `"<name>"`）。|
|`whenConnectedMatch`|string|預設 `"contains"` 要求清單中的顯示器存在，允許額外顯示器；`"exactly"` 要求連接集合與清單完全相同。|
|`whenDisconnected`|string[]?|必須中斷連接的顯示器。|

**`[[profiles.workspaceChains]]`：** 鏈是沒有錨點或父層的對等群組，儲存有序的穩定工作空間 UUID，不儲存顯示器槽位。每個工作空間在組合內最多屬於一條鏈；每條鏈至少有兩個不同項目，且都指向同組合的一般工作空間。重新命名是安全的。

只有使用者實際切換到的工作空間啟動鏈，鏈還原的工作空間不會遞迴觸發鏈。使用者明確選擇的工作空間必須放置，採用與單獨啟用相同的固定、游標與全域最近規則。先還原夥伴，再還原觸發工作空間，保留使用者選擇的焦點。

顯示器放置不是靜態設定驗證規則，而依當時連接狀態解析。先保留觸發工作空間，再依 `workspaceIds` 從上到下處理其他成員。固定成員使用已連接且空閒的目標，中斷的固定目標直接略過。動態成員從游標所在顯示器開始使用下一個空位；`dynamicWorkspaceIds` 可讓固定工作空間僅作為鏈夥伴時採用此行為，不改變一般固定設定。被高優先順序佔用或無剩餘顯示器時略過並繼續，因此 `workspaceIds` 決定可預期的優先順序，不需要求每個成員都有顯示器。

鏈動態夥伴優先佔用空閒顯示器。鏈之外的顯示器依一般順序還原：有效最近記錄、固定到該螢幕的工作空間、未使用的動態工作空間。無效參照與跨鏈衝突保持可見以便修復，對應鏈不執行。

工作空間鏈欄位：

|鍵|型別|說明|
| --- | --- | --- |
|`id`|UUID|穩定鏈識別碼，在設定組合內必須唯一。|
|`name`|string?|設定中顯示的可選名稱，不影響啟用。|
|`workspaceIds`|UUID[]|兩個或更多不同的一般工作空間 ID，依確定的衝突解決順序排列。|
|`dynamicWorkspaceIds`|UUID[]?|`workspaceIds` 的子集合，其中固定工作空間作為鏈夥伴放置時使用下一個空閒顯示器。不使用時省略。|

工作空間欄位：

|鍵|型別|說明|
| --- | --- | --- |
|`id`|UUID|穩定識別碼。|
|`name`|string|顯示名稱。|
|`symbolIconName`|string?|選單列與側邊欄使用的 SF Symbol。|
|`kind`|string|`normal`（預設）或 `scratchpad`。暫存區**僅供借用**，排除一般切換，不單獨啟用，借到其他工作空間旁邊時自動開啟 App。|
|`keyEquivalent`|string?|此工作空間的單字元按鍵，與切換、指派、借用輔助鍵組合，見 `[settings.shortcuts]`。省略則停用其按鍵操作。|
|`activateShortcut`|string?|切換組合的明確覆寫。|
|`assignAppShortcut`|string?|指派組合的明確覆寫：新增聚焦 App，保留其他成員關係並切換到此處。|
|`borrowShortcut`|string?|借用組合的明確覆寫。|
|`borrowEdge`|string?|覆寫此工作空間的預設借用邊緣：`top`、`bottom`、`left`、`right`。省略則使用 `settings.switching.borrowDefaultEdge`，其也未設定時選擇方向。|
|`borrowFraction`|double?|覆寫此工作空間借用區域的大小（0.1…0.9），省略使用 `settings.switching.borrowFraction`。|
|`appToFocusBundleId`|string?|啟用時聚焦的已指派 App 套件 ID，省略則使用最近 App。|
|`displayHint`|string?|用 `"<uuid>::<name>"` 或 `"<name>"` 固定到顯示器。省略則在游標所在螢幕開啟，固定顯示器缺少時回到主螢幕。動態工作空間離開後，原顯示器依自身記錄補位，只能使用固定到該螢幕的工作空間，或未被其他螢幕使用的動態工作空間。不會拉入固定到已中斷顯示器的工作空間；無候選時保持空白。|

App 指派欄位：

|鍵|型別|說明|
| --- | --- | --- |
|`bundleIdentifier`|string|App 套件 ID。|
|`name`|string|顯示名稱。|
|`autoOpen`|bool|啟用工作空間時啟動 App，關閉視窗後重新進入時再次開啟。|
|`layout`|string|`tiled`（**並排**）、`floating`（**置頂**，不並排，以鏡像置於上方）或 `unmanaged`（**維持原狀**，保留位置和成員關係，無並排、鏡像或螢幕錄製）。從 1.4 前的 `floating` bool 移轉。|
|`iconPath`|string?|自動寫入的 App 圖像快取路徑，不應手動設定。|
