<!-- LANGUAGE-LINKS:START -->
[English](../CONFIGURATION.md) · [한국어](../ko/CONFIGURATION.md) · [日本語](CONFIGURATION.md) · [简体中文](../zh-Hans/CONFIGURATION.md) · [繁體中文](../zh-Hant/CONFIGURATION.md)
<!-- LANGUAGE-LINKS:END -->

<a id="configuration"></a>
# 設定ガイド

Tatami は次の場所から設定を読みます。

```
~/.config/tatami/config.toml
```

XDG に対応し、`$XDG_CONFIG_HOME` があれば `$XDG_CONFIG_HOME/tatami/config.toml` を使います。初回に作成し、アプリでの変更時に保存します。手での編集も即時に反映するため、dotfiles として管理できます。

外部から書く場合は `NSFileCoordinator` に参加するか、一時ファイルを書いて `config.toml` を原子的に置き換えます。設定トランザクションと競合する置き換えは拒否します。`config.toml` を開いたまま名前変更後も同じ記述子へ書く方法は未対応です。POSIX rename は開いた記述子を新しいファイルへ付け替えません。一時ファイルから原子的に保存するエディタを使えます。

案内に沿って始めるなら、初回の**ガイド設定**を使います。アプリ情報と画面から下書きを作り、仮想画面で練習できます。**設定を適用**したときだけ保存します。**設定 → 一般 → ガイド設定を開始**で再開できます。

ファイルは四つの最上位部分に分かれます。

- **`[settings.*]`：** 以下で説明する全体設定
- **`[[sharedApps]]`：** 全ワークスペースでタイル表示または手前に置くアプリ
- **`[[profiles]]`：** ワークスペースとアプリの割り当て
- **`[[hooks]]`：** 状態や操作フィードバックで実行するプログラム

<a id="shortcut-syntax"></a>
## ショートカットの書き方

skhd 形式を使います。0 個以上の修飾キーを `+` で結び、` - ` の後にキーを書きます。

```
ctrl + alt - h
alt + shift - tab
ctrl + alt + shift + cmd - z
```

修飾キーは `ctrl`、`alt`（option）、`shift`、`cmd`。キーには文字、数字、`tab`、`return`、矢印（`left`/`right`/`up`/`down`）、記号などを使えます。

<a id="settingsgeneral"></a>
## `[settings.general]`

|キー|型|デフォルト|説明|
| --- | --- | --- | --- |
|`launchAtLogin`|bool|`false`|ログイン時に起動するよう、Tatami をログイン項目に登録します。|
|`checkForUpdatesAutomatically`|bool|`true`|新しいリリースを定期的に確認します。|
|`checkInterval`|string|`"daily"`|バックグラウンドの更新確認頻度：`hourly`、`daily`、`weekly`。|
|`debugLogging`|bool|`false`|診断イベントを `~/.config/tatami/tatami.log` に追記します。初めて有効にすると既存内容を空にします。|

<a id="settingsvisibility"></a>
## `[settings.visibility]`

|キー|型|デフォルト|説明|
| --- | --- | --- | --- |
|`overlayAwareApps`|string[]|`[]`|常に浮いているコントロールを持つアプリの ID です。登録したプロセスが非ゼロレイヤーの最上位 AX ウインドウを表示している場合は隠さず、通常ウインドウを各自動操作から外します。Mission Control には表示されることがあります。|

アプリごとの明示的な例外で、浮いたウインドウ全体への規則ではありません。条件に合う最上位ウインドウがなければ通常どおり隠し、ワークスペースや借りる表示を変えるたびに確認します。

```toml
[settings.visibility]
overlayAwareApps = ["notion.id"]
```

症状、アプリ例、設定での操作は[トラブルシューティング](https://github.com/PangMo5/Tatami/blob/main/docs/TROUBLESHOOTING.md#a-floating-control-disappears-or-brings-its-app-back)を参照してください。

<a id="settingsmenubar"></a>
## `[settings.menuBar]`

|キー|型|デフォルト|説明|
| --- | --- | --- | --- |
|`showWorkspaceIcon`|bool|`true`|現在のワークスペースのアイコンをメニューバーに表示します。|
|`showWorkspaceName`|bool|`true`|現在のワークスペース名をメニューバーに表示します。|
|`showProfileIcon`|bool|`true`|複数のプロファイルがある場合、現在のアイコンを表示します。|
|`showProfileName`|bool|`false`|複数のプロファイルがある場合、現在の名前を表示します。|

<a id="settingshud"></a>
## `[settings.hud]`

操作の結果を短く示すフィードバックです。互換性のためテーブル名 `hud` を保ちますが、アプリでは**操作フィードバック**と呼びます。`enabled` が全体スイッチで、ほかのキーは対象の操作を選びます。

|キー|型|デフォルト|説明|
| --- | --- | --- | --- |
|`enabled`|bool|`true`|すべての操作フィードバックの主スイッチです。|
|`workspaceSwitch`|bool|`true`|切り替え時にワークスペース名を表示します。|
|`windowCycle`|bool|`true`|切り替え修飾キーを保持すると一覧が出ます。キーや矢印で移動し、Return、修飾キーを離す、クリックで確定します。Escape で取り消し、短押しでは表示しません。|
|`profileSwitch`|bool|`true`|手動・自動のプロファイル切り替えで名前を表示します。|
|`floating`|bool|`true`|ワークスペースのアプリと共有アプリの手前表示の変更を示します。キー名は互換性のため維持します。|
|`appMembership`|bool|`true`|ワークスペースや共有アプリへの追加・削除を示します。|
|`tilingPaused`|bool|`true`|タイル表示を一時停止／再開しました。|
|`fullscreen`|bool|`true`|ワークスペースズームの開始・終了を示します。|
|`borrow`|bool|`true`|借りる・返す操作と方向選択のヒントを表示します。|
|`layout`|bool|`true`|均等配置など、独自の視覚変化を示さない操作の結果を表示します。|
|`position`|string|`"top"`|短いフィードバックの位置です。`topLeading`、`top`、`topTrailing`、`leading`、`center`、`trailing`、`bottomLeading`、`bottom`、`bottomTrailing` から選びます。対話式の一覧は独立して中央に表示します。|
|`size`|string|`"default"`|短いフィードバックの大きさです。`small`、`default`、`large` から選び、対話式一覧は固定サイズを保ちます。|
|`durationMs`|int|`900`|出入りのアニメーションの間、完全に表示する時間（ms）です。次の操作のヒントがある場合は 2 倍になります。|

<a id="settingslayout"></a>
## `[settings.layout]`

|キー|型|デフォルト|説明|
| --- | --- | --- | --- |
|`gapInner`|int|`8`|隣接するタイル間のピクセル間隔です。|
|`gapOuter`|int|`8`|タイルと画面の端のピクセル間隔です。|
|`autoBalance`|string|`"none"`|追加・削除時に比率を整えます。`none`、`horizontal`、`vertical`、`both` から選び、従来の bool も `true` → `both`、`false` → `none` として読めます。|
|`splitType`|string|`"auto"`|新しいウインドウで分割するときの既定方向です。`auto`（縦横比で判断）、`horizontal`、`vertical` を使えます。|
|`windowPlacement`|string|`"second"`|新しい分割のどちらへ入れるかを選びます。`first` は上・左、`second` は下・右です。|

ワークスペースは常に配置を覚えます。分割方向と比率を保存して再起動時に復元し、スリープ中はツリーを保ちます。復帰時に macOS が画面を作り直しても、保存済み配置へ再接続し、一時状態を上書きしません。

<a id="settingsfocus"></a>
## `[settings.focus]`

|キー|型|デフォルト|説明|
| --- | --- | --- | --- |
|`mouseFollowsFocus`|bool|`false`|Tatami が選んだウインドウへカーソルを移します。方向操作、アプリ・ウインドウ切り替え、ワークスペース変更、閉じた後、入れ替え、分割方向、ズームの往復に追従します。手前・そのままでは実際の枠を使います。Dock や Spotlight からの起動では、最近のウインドウでなくシステムが実際に上げたものへ移ります。クリック、ドラッグ完了、入れ替え・分割・戻しなどポインタ自身が原因の変更では動かしません。拡大・縮小・均等配置でも動かさず、キーの連続入力で毎回中央へ戻ることを防ぎます。|
|`mouseHidesOnFocus`|bool|`false`|ワークスペースの切り替え後、マウスを動かすまでカーソルを隠します。|
|`focusFollowsMouse`|bool|`false`|カーソルの移動に合わせ、その下のウインドウを選びます。|
|`refocusOnClose`|bool|`true`|選んだウインドウを閉じてそのアプリに窓がなくなったら、同じワークスペースの残りから使用履歴順にフォーカスを移します。|
|`focusFollowsMouseIgnoreFullscreen`|bool|`true`|マウスにフォーカスを追従させる際、画面全体を占める窓には移しません。|
|`focusFollowsMouseDisableHotkey`|string|`"Alt"`|FFM を一時停止する修飾キーです。`None`、`Alt`、`Cmd`、`Ctrl`、`Shift` から選びます。|

<a id="settingsswitching"></a>
## `[settings.switching]`

|キー|型|デフォルト|説明|
| --- | --- | --- | --- |
|`loop`|bool|`true`|最後のワークスペースから先頭へ、先頭から最後へループします。|
|`skipEmpty`|bool|`false`|次・前への移動で、実行中アプリのないワークスペースを飛ばします。|
|`followAppFocus`|bool|`true`|アプリを有効にすると、所属するワークスペースへ切り替えます。|
|`cycleAcrossDisplays`|bool|`false`|次・前のワークスペースをポインタの画面だけでなく全画面で探します。キー名は互換性のため保ちます。|
|`recentAcrossDisplays`|bool|`true`|全画面で直前のワークスペース履歴を共有します。対象が別画面に見えていれば移動せずそこで選びます。画面別に分けるには `false` にします。|
|`switchToRecentWhenEmpty`|bool|`false`|最後の窓を閉じ、タイルやワークスペース固有の手前ウインドウがなくなったら直前のワークスペースへ移ります。全ワークスペースにいる共有アプリは数えません。|
|`cycleSameAppWindows`|bool|`false`|切り替えの単位です。既定の `false` はアプリごとに最近の窓を選び、`true` は同じアプリの窓も一つずつ訪ねます。ワークスペース内のタイル・手前・そのままが参加し、借りている間は両側のタイルが一つの順番になります。キー名は互換性のため維持します。|
|`includeSharedAppsInWindowSwitcher`|bool|`true`|共有アプリを一覧に含めます。借りている間はタイル外の共有窓も両側のタイルと一緒に参加し、`false` ならすべての共有アプリを除外します。|
|`toggleBorrowOnRepeat`|bool|`true`|すでに横にあるワークスペースを再度借りると返して元に戻します。`false` では借りたワークスペースを移動します。|
|`borrowDefaultEdge`|string?|_（未設定）_|既定の借りる位置です。`top`、`bottom`、`left`、`right` を使えます。未設定ならキー操作の後に h/j/k/l または矢印を待ち、ワークスペースの `borrowEdge` を優先します。|
|`borrowFraction`|double|`0.4`|分割方向で借りた領域が占める割合（0.1〜0.9）です。ワークスペースの `borrowFraction` が優先されます。|

<a id="settingsgestures"></a>
## `[settings.gestures]`

|キー|型|デフォルト|説明|
| --- | --- | --- | --- |
|`enabled`|bool|`false`|設定した 3 本指・4 本指のスワイプを認識します。|
|`threshold`|double|`0.3`|操作を実行するまでのスワイプ距離です。小さいほど敏感で、小数点以下 2 桁で保存します。|
|`threeFinger`|table|左 → `nextWorkspace`、右 → `previousWorkspace`|3 本指の `left`、`right`、`up`、`down` の操作です。省略した方向は `none` です。|
|`fourFinger`|table|全方向 → `none`|4 本指の `left`、`right`、`up`、`down` の操作です。|

各方向に操作文字列を一つ保存します。アプリの階層メニューを使うと安定した UUID を書くため、ワークスペースやプロファイルを簡単に指定できます。

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

使用できる固定の操作文字列です。

- **ワークスペース：** `nextWorkspace`、`previousWorkspace`、`recentWorkspace`、`moveAppToNextWorkspace`、`moveAppToPreviousWorkspace`、`assignAppToRecentWorkspace`、`assignAppToNextWorkspace`、`assignAppToPreviousWorkspace`
- **フォーカスと画面：** `focusNextDisplay`、`focusPreviousDisplay`、`focusLeft`、`focusRight`、`focusUp`、`focusDown`
- **ウインドウ切り替え：** `cycleNextWindow`、`cyclePreviousWindow`
- **配置：** `growWindow`、`shrinkWindow`、`swapLeft`、`swapRight`、`swapUp`、`swapDown`、`toggleOrientation`、`toggleFullscreen`、`balanceLayout`
- **アプリとタイル表示：** `toggleFloating`、`toggleSharedFloating`、`toggleTiling`、`toggleAppInWorkspace`、`toggleAppInSharedApps`。**常に手前**の設定識別子は `floating` を保ちます。
- **借りる：** `borrowRecentWorkspace`、`borrowNextWorkspace`、`borrowPreviousWorkspace`、`dismissBorrow`
- **未割り当て：** `none`

特定の対象には `activateWorkspace:<workspace UUID>`、`assignAppToWorkspace:<workspace UUID>`、`borrowWorkspace:<workspace UUID>`、`activateProfile:<profile UUID>` のように安定した ID を付けます。借りる操作は所属プロファイルが有効な間に使え、有効化・割り当てでは先にそのプロファイルへ切り替えられます。

以前の `fingerCount = 3`、`4` は自動移行します。その指の本数の左右は従来の次・前を保ち、ほかの方向と本数は未割り当てになります。

<a id="settingsmarker"></a>
## `[settings.marker]`

ズーム・手前・借りた窓を示す、角の小さな印です。

|キー|型|デフォルト|説明|
| --- | --- | --- | --- |
|`fullscreenEnabled`|bool|`true`|ワークスペース全体に広げた窓が選ばれている間、点を表示します。|
|`fullscreenColorHex`|string|`"#007AFF"`|ズームの点の色（`#RRGGBB`）です。|
|`floatingEnabled`|bool|`true`|手前の窓は状態がすぐわかるよう、常に点を表示します。|
|`floatingColorHex`|string|`"#FF9500"`|手前表示の点の色（`#RRGGBB`）です。|
|`borrowEnabled`|bool|`true`|借りている間、各窓に所属ワークスペースのアイコンを表示します。|
|`borrowColorHex`|string|`"#AF52DE"`|借りるバッジの色（`#RRGGBB`）です。|
|`size`|double|`14`|点の直径をポイントで指定します。借りるバッジは記号が読めるよう大きく描きます。|
|`corner`|string|`"bottomTrailing"`|点を置く窓の角です。`topLeading`、`topTrailing`、`bottomLeading`、`bottomTrailing` から選びます。|
|`hideOnHover`|bool|`true`|カーソルが点に重なる間は薄くします。|

<a id="settingsshortcuts"></a>
## `[settings.shortcuts]`

多くは skhd 形式で、省略した操作は未割り当てです。`config.toml` がない新規設定には[推奨値](#recommended-defaults)を入れます。すべて変更・削除でき、下の三つの `*Modifiers` 配列だけはワークスペースの**キー**を定める別の仕組みです。

<a id="workspace-keys-switch--assign--borrow"></a>
### ワークスペースのキー：切り替え・割り当て・借りる

ワークスペースごとに三つ作る代わりに、一文字の**キー**（`keyEquivalent`）を決め、三つの共通修飾キーのいずれかと組み合わせて操作を選びます。

|キー|型|デフォルト|操作|
| --- | --- | --- | --- |
|`keyEquivalentModifiers`|string[]|`["ctrl", "alt"]`|+ ワークスペースのキー → そのワークスペースへ**切り替え**|
|`assignModifiers`|string[]|`["ctrl", "alt", "shift"]`|+ ワークスペースのキー → アプリを**割り当て**て切り替え|
|`borrowModifiers`|string[]|`["ctrl", "alt", "cmd"]`|+ ワークスペースのキー → 現在の画面に**借りる**|

修飾キーは `ctrl`、`alt`、`shift`、`cmd` です。空配列は組み合わせを無効にし、文字入力が奪われないようにします。

上の**既定値**は*既存*の設定にキーがない場合の値です。新規インストールでは `keyEquivalentModifiers = ["ctrl", "alt", "shift"]`、`assignModifiers = ["alt", "shift", "cmd"]` を設定します。[推奨値](#recommended-defaults)を参照してください。

同じ三つの修飾キーで、個別のキーを持つ**直前・次・前**へも移れます。

|キー|型|説明|
| --- | --- | --- |
|`recentWorkspaceKey`|string?|直前のワークスペースのキーです。切り替え・割り当て・借りる修飾キーと使います。|
|`nextWorkspaceKey`|string?|次のワークスペースのキーです。|
|`previousWorkspaceKey`|string?|前のワークスペースのキーです。|

各操作に**明示的な上書き**を指定でき、修飾キーと作業キーの組み合わせより優先します。

- ワークスペースごとに `activateShortcut`、`assignAppShortcut`、`borrowShortcut` を指定できます。後のワークスペース項目を参照してください。
- **移動先ごと：** `switchTo{Recent,Next,Previous}Workspace`、`assign{Recent,Next,Previous}Workspace`、`borrow{Recent,Next,Previous}Workspace`。すべて skhd 形式です。

ワークスペースのキーと上書きは所属プロファイル内だけで有効なので、別のプロファイルで再利用できます。グローバルキーは全体と照合し、コピー・複製も保存前に選んだ変更を検証します。

既定の位置（`settings.switching.borrowDefaultEdge` またはワークスペースの `borrowEdge`）がなければ、h/j/k/l か矢印を待ちます。`dismissBorrow` で返すと、元のワークスペースを画面全体へ戻します。

<a id="action-shortcuts"></a>
### 操作ショートカット

|キー|操作|
| --- | --- |
|`focusLeft` / `focusRight` / `focusUp` / `focusDown`|指定方向のタイルを選びます。端では借りた領域へ移ります。|
|`swapLeft` / `swapRight` / `swapUp` / `swapDown`|選んだタイルを指定方向に入れ替えます。|
|`resizeGrow` / `resizeShrink`|選択中のウインドウを含む分割の向きに合わせ、左右または上下に領域を拡大・縮小|
|`toggleOrientation`|選んだ分割の向きを切り替えます。|
|`toggleFullscreen`|選んだ窓をワークスペース全体に広げます。|
|`balance`|設定した `autoBalance` の軸を適用します。自動均等化がオフなら、現在の順番から標準 BSP 構造と比率を再構築します。|
|`cycleNextWindow` / `cyclePreviousWindow`|今のワークスペース内でアプリや窓を切り替えます。Command-Tab のように無関係なアプリは含まず、Command-backtick のように一つのアプリにも限定されません。|
|`moveToNextWorkspace` / `moveToPreviousWorkspace`|アプリを次・前のワークスペースへ移して、そこへ切り替えます。|
|`dismissBorrow`|借りたワークスペースを返し、元のワークスペースを画面全体に戻します。|
|`focusNextDisplay` / `focusPreviousDisplay`|次・前の画面のワークスペースへフォーカスを移し、端では循環します。|
|`toggleFloating`|選んだアプリを現在のワークスペースで手前に置き、必要なら追加します。もう一度実行するとタイル表示に戻ります。|
|`toggleSharedFloating`|アプリをどこでも手前に置き、必要なら共有へ追加します。オフにすると共有の*タイル表示*になり、所属を外すには `toggleAppInSharedApps` を使います。|
|`toggleFocusedAppInActiveWorkspace`|現在の窓のアプリをワークスペースへ追加し、すでに所属していれば外します。|
|`toggleAppInSharedApps`|アプリを共有に追加して全ワークスペースでタイル表示し、すでに共有なら外します。|
|`toggleSpaceActivated`|タイル表示を一時停止・再開|

<a id="recommended-defaults"></a>
### 推奨の初期設定

`config.toml` がない新規設定にはすぐ使えるキーを入れます。窓・タイルは `⌃⌥`、ワークスペースの**切り替え**は `⌃⌥⇧`、**割り当て**は `⌥⇧⌘` です。ワークスペースキーと `⌃⌥` のフォーカスキーが衝突しないよう分けており、すべて変更・削除できます。

|操作|ショートカット|
| --- | --- |
|左・下・上・右へフォーカス|`⌃⌥H` · `⌃⌥J` · `⌃⌥K` · `⌃⌥L`|
|左・下・上・右と入れ替え|`⌃⌥←` · `⌃⌥↓` · `⌃⌥↑` · `⌃⌥→`|
|拡大・縮小|`⌃⌥=` · `⌃⌥-`|
|方向を切り替え|`⌃⌥S`|
|フルスクリーンを切り替え|`⌃⌥⏎`|
|均等化|`⌃⌥E`|
|次・前のウインドウへ切り替え|`⌥⇥` · `⌥⇧⇥`|
|「常に手前」を切り替え|`⌥⌘⏎`|
|共有アプリの「常に手前」を切り替え|`⌥⇧⌘⏎`|
|タイル表示を一時停止／再開|`⌃⌥⇧⌘Z`|
|ワークスペースへの所属を切り替え|`⌃⌥/`|
|共有アプリへの所属を切り替え|`⌃⌥⇧/`|
|アプリを前・次のワークスペースへ移動|`⌃⌥⇧[` · `⌃⌥⇧]`|
|前・次の画面へフォーカス|`⌃⌥⇧←` · `⌃⌥⇧→`|
|借りたワークスペースを戻す|`⌃⌥⌘/`|
|直前・次・前のワークスペースキー|`\` · `.` · `,`|

ワークスペースの**切り替え・割り当て・借りる**は、上の修飾キーを各ワークスペースキーや直前・次・前のキーと組み合わせます。

<a id="sharedapps"></a>
## `[[sharedApps]]`

ここにあるアプリは**全ワークスペース**に属します。`layout` は `tiled`（既定のタイル）、`floating`（**常に手前**、ミラーで全ワークスペースの上へ）、`unmanaged`（**そのまま**、所属だけ保ち配置もミラーもしない）です。窓がなければ開く `autoOpen`（bool、既定 `false`）も選べます。`iconPath` は自動管理の文字列なので手で設定しません。

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

SIP を無効にせず、ScreenCaptureKit のミラーを手前のパネルに表示します。**画面収録**の許可が必要です（設定 → 一般 → 権限）。アプリ自体にフォーカスがある間はミラーを隠して収録を止めます。`unmanaged` は実際の窓を触らないため不要です。

アプリの**ワークスペース → 共有アプリ**で、タイル・手前・そのままを設定できます。

以前の `[[floatingApps]]` は初回読込時に `layout = "floating"` の共有アプリへ移行します。1.4 より前の `floating` bool も、`true` → `floating`、それ以外 → `tiled` に変換します。

<a id="hooks"></a>
## `[[hooks]]`

次のイベントを発行すると、フックがプログラムを実行します。

- `tatamiLaunched`：起動時にプロファイルを決めた後、各プロセスで一度発行します。そのプロファイルを渡し、`previousProfile`、`workspace`、`display` はありません。後で追加したフックには再送しません。
- `profileChanged`：現在のプロファイルが変わりました。起動時は `previousProfile` がありません。
- `workspaceActivated`：ワークスペースが画面へ表示状態を反映しました。失敗・時間切れでは発行しません。
- `hud`：短いフィードバックを発行しました。Tatami と同じ翻訳済みタイトル、SF Symbol、任意の副題、時間、位置、サイズ、任意の対象画面を渡し、SketchyBar などでも同じ内容を表示できます。

起動時の `tatamiLaunched` と `profileChanged` は別です。プロセス起動かプロファイル変更か、必要に応じて片方・両方を設定します。

**設定 → フック**で追加、編集、削除、有効・無効化できます。実行ファイル、引数、作業フォルダ、時間制限、環境を別々に入力します。下記と同じ `[[hooks]]` を保存するので、`config.toml` の手編集も即時反映します。

**テスト実行**は編集中の下書きを検証し、サンプルイベントで一度動かします。フックの追加・更新や `config.toml` への書き込みはせず、残すには別途**保存**します。

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

|キー|型|デフォルト|説明|
| --- | --- | --- | --- |
|`id`|string|_（必須）_|ASCII の英数字、`.`、`_`、`-` を使う一意の診断 ID です。最大 64 文字です。|
|`event`|string|_（必須）_|`tatamiLaunched`、`profileChanged`、`workspaceActivated`、`hud` のいずれかです。|
|`enabled`|bool|`true`|フックを実行するかを指定します。無効でも `tatami hook list` には表示されます。|
|`command`|string[]|_（必須）_|実行ファイルの後に引数を指定します。各要素が一つの argv です。|
|`timeoutMs`|int|`5000`|実行時間の上限は 100〜300000 ms です。|
|`workingDirectory`|string?|Tatami の設定フォルダ|絶対パス、または `~/` で始まるパスです。|
|`environment`|table|`{}`|アプリが引き継いだ環境へ追加する値です。下の Tatami の値が優先されます。|

Tatami は `command` を直接実行し、シェル起動、単語分割、引用符解釈、変数展開をしません。編集画面でも `command[0]` が実行ファイルで各行が一つの argv です。シェルが必要なら `command = ["/bin/zsh", "-lc", "your pipeline"]` と明示します。fish は `which fish` のパスを使い、`command = ["/opt/homebrew/bin/fish", "-c", "command ls"]` のように分けます。標準入力にはイベント JSON を送ります。`/` を含む実行名はパスとして先頭の `~/` を展開し、名前だけなら `PATH` から探します。Finder 起動では絶対パスが確実です。

各フックへバージョン付き JSON を一つ stdin で送ります。`schemaVersion`、`event`、`occurredAt`、`profile` と、該当時は `previousProfile`、`workspace`、`display`、`hud` を含みます。`hud` には `title`、`symbolIconName`、`subtitle`、任意の `subtitleSymbolIconName`、`durationMs`、`position`、`size` があります。画面が特定できれば `display` を渡し、チェーンでは影響した画面ごとにそのワークスペースの情報を送ります。`durationMs` は完全表示の時間で、外部側は前後のアニメーションを別途加えます。次の環境変数も設定します。

- `TATAMI_HOOK_ID`, `TATAMI_HOOK_EVENT`
- `TATAMI_PROFILE_ID`, `TATAMI_PROFILE_NAME`
- ワークスペースイベントには `TATAMI_WORKSPACE_ID`、`TATAMI_WORKSPACE_NAME`、`TATAMI_WORKSPACE_KIND` があります。
- 画面を特定できれば `TATAMI_DISPLAY_UUID`、`TATAMI_DISPLAY_NAME` を渡します。
- `hud` イベントには `TATAMI_HUD_TITLE`、`TATAMI_HUD_SYMBOL_ICON_NAME`、`TATAMI_HUD_SUBTITLE`、`TATAMI_HUD_SUBTITLE_SYMBOL_ICON_NAME`、`TATAMI_HUD_DURATION_MS`、`TATAMI_HUD_POSITION`、`TATAMI_HUD_SIZE` があります。任意値がなければ空文字にせず省略します。

SketchyBar なら `event = "hud"` を購読し、`command` に `TATAMI_HUD_*` を独自イベントへ渡すスクリプトを指定できます。stdin の JSON を使えば任意フィールドの環境変数規則を解析する必要もありません。フック自身の失敗・復旧は `hud` に再発行せず、再帰的な起動を防ぎます。

stdout と stderr は各 64 KiB までです。異常終了、シグナル、起動失敗、出力超過、時間切れは問題一覧と有効なログに残します。ワークスペースやプロファイルの変更は妨げず戻しません。独立セッションで動かし、終了・時間切れでは正常終了を求めてからシェルの背景グループを含む子を強制終了します。新セッションへ離脱してはいけません。同じ `id` の実行中も新イベントは独立し、最新だけが現在の問題を更新します。定義の変更・無効化・削除は古い実行を止め問題を消します。

<a id="profiles-and-workspaces"></a>
## `[[profiles]]` とワークスペース

プロファイルは名前付きのワークスペースセットです。切り替えると各画面を整え、接続状態で**自動有効化**もできます。選択中のプロファイル、画面別の履歴、全体の最近順は `config.toml` の隣の `profile-session.json` に保存し、`config.toml` には書きません。起動時は最後の手動プロファイルを必ず戻します。画面条件付きなら条件が一致するときだけ戻し、そうでなければ最適な自動選択を使います。

ワークスペースは独立しているため、アプリや設定が異なることがあります。詳細の**コピー元を選ぶ**機能で差分を確認し、選んだ変更だけを取り込めます。

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

プロファイルの項目：

|キー|型|説明|
| --- | --- | --- |
|`id`|UUID|安定した識別子です。|
|`name`|string|表示する名前です。|
|`symbolIconName`|string?|プロファイルのサイドバー、メニュー、切り替えに使う SF Symbol です。省略時は `rectangle.stack` です。|
|`shortcut`|string?|このプロファイルへ切り替える skhd 形式のキーです。|
|`autoActivation`|table?|下の画面条件が合うと自動で有効化します。省略は手動のみ、条件のないテーブルはすべてに一致します。|
|`workspaceChains`|table[]|複数画面で一緒に切り替える対等なワークスペースグループです。画面はチェーンに保存せず、有効化時に決めます。不要なら省略します。|

**`[profiles.autoActivation]`：** 全キーは任意で AND 結合です。複数が一致すると具体的なものを優先し、`exactly` は `contains` より上、条件が多いものが上、同じなら先のプロファイルを使います。

|キー|型|説明|
| --- | --- | --- |
|`displayCount`|string?|接続画面数：`"==1"`、`">=2"`、`"<=1"`。|
|`whenConnected`|string[]?|接続が必要な画面（`"<uuid>::<name>"` または `"<name>"`）です。|
|`whenConnectedMatch`|string|既定の `"contains"` は一覧の画面があれば追加も許可します。`"exactly"` は接続集合が一覧と完全一致する必要があります。|
|`whenDisconnected`|string[]?|接続されていてはいけない画面です。|

**`[[profiles.workspaceChains]]`：** チェーンは親や基準を持たない対等なグループです。画面枠ではなく安定したワークスペース UUID を順に保存します。ワークスペースは一つのチェーンだけに属し、同じプロファイルの異なる通常ワークスペースが 2 個以上必要です。名前変更は安全です。

ユーザーが直接選んだワークスペースだけがチェーンを開始し、チェーンによる復元は再帰的に開始しません。選んだワークスペースを必須とし、単独と同じ固定・ポインタ・全体履歴の規則で配置します。仲間を先に、選択を最後に復元してフォーカスを保ちます。

配置は固定検証ではなく、現在の接続画面で解決します。選択を予約してから `workspaceIds` 順に仲間を見ます。固定先が接続中で空なら使い、未接続なら他画面へ移さず飛ばします。動的ワークスペースはポインタ画面から空きを使います。`dynamicWorkspaceIds` は通常の固定を保ち、仲間の場合だけ同じ動的配置にします。優先度の高いワークスペースと重なる、または空きがなければ次へ進みます。全員分の画面は不要で、`workspaceIds` が決まった優先順になります。

チェーンの動的な仲間は通常復元より先に空きを確保します。残りは有効な履歴、その画面への固定、未使用の動的ワークスペースの順で戻します。不正参照やチェーン間の所属競合は修正できるよう表示し、そのチェーンは実行しません。

ワークスペースチェーンの項目：

|キー|型|説明|
| --- | --- | --- |
|`id`|UUID|プロファイル内で一意の、安定したチェーン ID です。|
|`name`|string?|設定に表示する任意の名前です。有効化には影響しません。|
|`workspaceIds`|UUID[]|決まった競合解決順に並べた、異なる通常ワークスペースの ID が 2 個以上必要です。|
|`dynamicWorkspaceIds`|UUID[]?|仲間として配置するときだけ次の空き画面を使う、`workspaceIds` の固定ワークスペースの部分集合です。不要なら省略します。|

ワークスペースの項目：

|キー|型|説明|
| --- | --- | --- |
|`id`|UUID|安定した識別子です。|
|`name`|string|表示する名前です。|
|`symbolIconName`|string?|メニューバーとサイドバーの SF Symbol です。|
|`kind`|string|`normal`（既定）または `scratchpad` です。一時スペースは**借りる専用**で、通常切り替えや単独有効化には入らず、借りるとアプリを開きます。|
|`keyEquivalent`|string?|切り替え・割り当て・借りる修飾キーと使う一文字キーです。`[settings.shortcuts]` を参照してください。省略すると無効になります。|
|`activateShortcut`|string?|切り替えの組み合わせを上書きするキーです。|
|`assignAppShortcut`|string?|元の所属を保ってアプリを追加し、ここへ切り替える割り当てキーの上書きです。|
|`borrowShortcut`|string?|借りる組み合わせを上書きするキーです。|
|`borrowEdge`|string?|このワークスペースの位置を `top`、`bottom`、`left`、`right` で上書きします。省略時は `settings.switching.borrowDefaultEdge`、それもなければ方向を選びます。|
|`borrowFraction`|double?|このワークスペースの借りる割合（0.1〜0.9）を上書きし、省略時は `settings.switching.borrowFraction` を使います。|
|`appToFocusBundleId`|string?|有効化時に選ぶ割り当て済みアプリの ID です。省略時は最近使ったものを選びます。|
|`displayHint`|string?|`"<uuid>::<name>"` または `"<name>"` で画面に固定します。省略ならポインタの画面、固定先不在なら主画面です。動的ワークスペースが離れた画面は自身の履歴から、その画面の固定ワークスペースか他画面が使っていない動的ワークスペースだけで補います。未接続画面への固定は呼び込まず、候補がなければ空にします。|

アプリ割り当ての項目：

|キー|型|説明|
| --- | --- | --- |
|`bundleIdentifier`|string|アプリのバンドル ID です。|
|`name`|string|表示する名前です。|
|`autoOpen`|bool|ワークスペースを有効にすると起動し、閉じた窓も入り直すと開きます。|
|`layout`|string|`tiled`（**タイル表示**）、`floating`（**常に手前**、ミラーで上に表示）、`unmanaged`（**そのまま**、所属と位置を保ちタイル・ミラー・画面収録なし）です。1.4 より前の `floating` bool から移行します。|
|`iconPath`|string?|自動保存するアプリアイコンのパスです。手では設定しません。|
