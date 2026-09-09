<!-- LANGUAGE-LINKS:START -->
[English](../CLI.md) · [한국어](../ko/CLI.md) · [日本語](CLI.md) · [简体中文](../zh-Hans/CLI.md) · [繁體中文](../zh-Hant/CLI.md)
<!-- LANGUAGE-LINKS:END -->

<a id="tatami-command-line-reference"></a>
# Tatami コマンドラインリファレンス

アプリ内に `tatami` 実行ファイルを同梱しています。CLI は実行中のアプリと通信するため、先に Tatami を起動してください。

<a id="install"></a>
## インストール

**設定 → 一般 → コマンドライン → インストール**を開きます。`/usr/local/bin/tatami` にリンクを作り、追加・削除時に macOS が管理者パスワードを求めます。同じ場所でアプリを置き換えると CLI も更新されます。移動や名前変更後はリンクを再作成してください。

実行ファイルと起動中のアプリを両方確認します。

```sh
tatami --version     # bundled CLI version, no app connection required
tatami version       # version reported by the running Tatami app
```

<a id="command-overview"></a>
## コマンドの概要

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

`tatami help`、`tatami help <command>`、または各コマンドの後に `--help` を付けると、ArgumentParser の現在の使い方を確認できます。

<a id="select-profiles-and-workspaces"></a>
## プロファイルとワークスペースを選ぶ

`<profile>` と `<workspace>` は現在の名前か UUID で選べます。名前は `--profile` がなければ現在のプロファイル内で探します。UUID は全体で一意なので `--profile` なしで別のプロファイルも指定できます。ただし `workspace borrow from` は現在のプロファイル内だけで、必要なら先に切り替えます。

範囲内に同名があると何も変えずに失敗し、候補の UUID をすべて表示します。その UUID でやり直してください。

既存スクリプト向けに以前のフラットなコマンドも別名として残しています。新しい使い方を分類ごとに学べるよう、ルートのヘルプでは非表示にしています。

- `tatami list-workspaces` は現在のプロファイルに対する `tatami workspace list` です。
- `tatami list-apps <workspace>` は現在のプロファイルに対する `tatami workspace apps <workspace>` です。
- `tatami activate <workspace>` は現在のプロファイルに対する `tatami workspace activate <workspace>` です。

名前変更と複製は `config.toml` をトランザクションとして更新します。複製では設定の公開前に保存済み配置もコピーし、そのコピーに失敗すると設定を変えません。

CLI は選択シートを開かず全体を複製します。`workspace duplicate` は同じプロファイルに作るため、ワークスペースキーと有効化・割り当て・借りるキーを空にします。`profile duplicate` はプロファイルの切り替えと自動規則を空にし、ワークスペースキーはプロファイル別なので保ちます。一部だけ選ぶ場合はアプリの複製を使ってください。

<a id="run-dispatcher-commands-by-domain"></a>
## 分類ごとの操作コマンドを実行する

`profile`、`workspace`、`window`、`display`、`layout`、`app` は、3 本指・4 本指ジェスチャに割り当てられる全操作を提供します。有効化以外は `GestureAction` を経由し、同じ `HotKeyAction` に渡します。汎用の `action` 抜け道はありません。

多くの操作は `accepted` を返します。アプリが検証して共通 reducer に渡した意味で、後のウインドウ操作の成功までは示しません。`window focus left` に隣がない場合や、フォーカスなしでアプリ操作が届く場合もあります。

`profile activate` と `workspace activate` は有効化の全処理を待ち、`completed` または最終的な失敗を返します。一時スペースには借りる操作 `workspace borrow from <workspace>` を使います。

切り替えコマンドは繰り返すと結果が変わります。中断や結果不明の後は状態を確認してください。再試行が最初の操作を取り消すことがあります。

<a id="profiles-and-workspaces"></a>
### プロファイルとワークスペース

|コマンド|動作|
| --- | --- |
|`profile activate <profile>`|プロファイルを有効化し、最終完了を待ちます。|
|`workspace activate <workspace> [--profile …]`|ワークスペースと必要なら所属プロファイルを有効化し、完了を待ちます。|
|`workspace next` / `previous` / `recent`|履歴や並び順に沿ってワークスペースを切り替えます。|
|`workspace move-app next` / `previous`|選んだアプリを隣のワークスペースへ移し、切り替えます。|
|`workspace assign-app to <workspace> [--profile …]`|既存の所属を残してアプリを追加し、必要ならプロファイルを変えて対象を開きます。|
|`workspace assign-app next` / `previous` / `recent`|既存の所属を残して追加し、相対位置のワークスペースに切り替えます。|
|`workspace borrow from <workspace>`|現在のプロファイル内のワークスペースについて、借りる方向の選択を始めます。|
|`workspace borrow next` / `previous` / `recent`|相対位置のワークスペースを借ります。|
|`workspace dismiss-borrow`|ポインタの画面で借りる操作を終了します。|

アプリの所属や表示方法を保存するコマンドは、初期状態で確認HUDを開きます。確定後に設定を変更し、同じHUDで結果を表示します。「設定」→「一般」→「確認」で操作ごとに選べます。「次回から確認しない」は確定した操作だけに適用され、キャンセルでは変わりません。

<a id="windows-and-displays"></a>
### ウインドウと画面

|コマンド|動作|
| --- | --- |
|`window focus left` / `right` / `up` / `down`|隣のタイルウインドウへフォーカスを移します。|
|`window cycle next` / `previous`|表示中の Tatami ワークスペース内で順に切り替えます。|
|`window resize grow` / `shrink`|選んだ BSP 分割を一段階調整します。|
|`window swap left` / `right` / `up` / `down`|選んだタイルウインドウを指定方向に入れ替えます。|
|`window toggle-fullscreen`|選んだウインドウのワークスペースズームを切り替えます。|
|`window toggle-floating` / `toggle-shared-floating`|ワークスペースまたは共有アプリ内で、選んだアプリのタイル・手前表示を切り替えます。|
|`display focus next` / `previous`|隣の画面のワークスペースへフォーカスを移します。|

CLI とジェスチャの切り替えは即時に行います。修飾キーを押し続ける一覧は、実際のグローバルショートカット専用です。

<a id="layout-and-tiling"></a>
### 配置とタイル表示

|コマンド|動作|
| --- | --- |
|`layout toggle-orientation`|選んだ分割の向きを切り替えます。|
|`layout balance`|現在の配置を均等にします。|
|`layout toggle-tiling`|Tatami のタイル表示全体を一時停止・再開します。|

<a id="focused-app"></a>
### フォーカス中のアプリ

|コマンド|動作|
| --- | --- |
|`app toggle-workspace`|現在のワークスペースに所属していれば外し、そうでなければ同じプロファイルの別のワークスペースから移してタイル表示にします。|
|`app toggle-shared`|選んだアプリをタイル表示の共有アプリに追加し、すでに共有なら外します。|

<a id="hooks"></a>
### フック

`tatami hook list` は無効・不正な項目も含め全フックを表示します。**設定 → フック**で管理するか、`config.toml` の `[[hooks]]` を編集できます。手での変更も即時に反映します。

イベントは `tatamiLaunched`、`profileChanged`、`workspaceActivated`、`hud` です。`tatamiLaunched` は起動後にプロファイルを決めてから各プロセスで一度発生し、プロファイルを含み `previousProfile`、`workspace`、`display`、`hud` は省きます。起動時の `profileChanged` とは別で、両方を購読できます。`hud` は SketchyBar などへ短い操作情報を渡します。

実行ファイルと各引数は別フィールドで、先頭は `command[0]`、残りは argv になります。シェル結合、空白分割、引用符解釈、変数展開は行いません。必要なら `/bin/zsh` を選び、`-lc` とスクリプトを別引数にします。fish は `which fish` のパスに `-c` と本文を渡します。`command ls` はユーザーの `ls` 関数を避けます。標準入力を読むコマンドにはフックの JSON イベントが届きます。

イベント、標準入力、環境、作業フォルダ、時間制限の詳しい規則は[設定ガイド](https://pangmo5.dev/Tatami/ja/configuration.html#hooks)にあります。

<a id="json-output-and-exit-status"></a>
## JSON 出力と終了状態

末端コマンドの後に `--json` を付けます。`tatami --json profile list` のような親の位置には指定できません。

例：

```sh
tatami profile list --json
tatami workspace apps "Coding" --profile "Dual" --json
tatami window focus left --json
```

成功した JSON は標準出力へ出ます。操作結果は次の形です。

```json
{
  "command": "window.focus.left",
  "title": "Focus left",
  "status": "accepted"
}
```

`command` と `status` はスクリプト向けの固定フィールドで、`title` はアプリ言語に従う表示文です。プロファイル、ワークスペース、アプリ、フック、変更操作は、文を包むのではなく識別子と情報を持つ構造を返します。

引数解析後の失敗は標準エラーに `{"error":"…"}` を書き、非ゼロで終了します。ArgumentParser の案内は平文です。`--json` の要求に古いアプリが平文を返す場合、新しい CLI は機械可読データとして扱わず拒否します。

<a id="socket-and-development-isolation"></a>
## ソケットと開発環境の分離

既定では両プロセスがユーザーの Darwin 一時フォルダの `tatami.socket` を使います。開発用に分けるには `TATAMI_SOCKET_PATH` を絶対パスにし、アプリと CLI に同じ値を渡します。

```sh
socket="${TMPDIR%/}/tatami-example.socket"
TATAMI_SOCKET_PATH="$socket" /path/to/Tatami.app/Contents/MacOS/Tatami &
TATAMI_SOCKET_PATH="$socket" /path/to/tatami workspace list
```

ソケットはアプリが持ちます。起動していない場合、CLI は非ゼロで終了して Tatami の起動確認を案内します。

<a id="scripting-examples"></a>
## スクリプトの例

UUID で選び、`jq` で JSON の規則を確認します。

```sh
profile_id="$(tatami profile list --json | jq -r '.[] | select(.isActive).id')"
tatami workspace list --profile "$profile_id" --json \
  | jq -r '.[] | [.id, .name, .kind] | @tsv'
```

操作コマンドを送信できなければ、すぐ失敗させます。

```sh
if ! result="$(tatami layout balance --json)"; then
  printf 'Tatami layout command failed\n' >&2
  exit 1
fi
printf '%s\n' "$result" | jq -e '.status == "accepted"' >/dev/null
```
