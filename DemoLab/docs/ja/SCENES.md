<!-- LANGUAGE-LINKS:START -->
[English](../SCENES.md) · [한국어](../ko/SCENES.md) · [日本語](SCENES.md) · [简体中文](../zh-Hans/SCENES.md) · [繁體中文](../zh-Hant/SCENES.md)
<!-- LANGUAGE-LINKS:END -->

<a id="scenes-and-acceptance"></a>
# 場面と合格条件

シーンには `name`、`title`、`steps` が必要です。`summary`、`requires`、`setup`、`openingApps`、`captureSecondary` は任意のフィールドです。`setup` は録画前に実行され、`steps` が映像に映る操作を定義します。各操作は、インストール済みの Tatami とネイティブのデモアプリを実際に動かします。

メイン画面を録画し続け、2 台目の画面は接続中だけ録画するホットプラグのシーンでは、`captureSecondary` を `true` に設定します。

```sh
.build/DemoLab/bin/democtl scene tour --dry-run
.build/DemoLab/bin/democtl take tour --output recordings/iteration/tour.mov
```

<a id="preparation"></a>
## 準備

最初に見えるアプリを `openingApps` に指定します。意図した複数窓も含め、実際の通常ウインドウと一致させます。`autoopen` は開く操作が目的なので空配列です。400 ms 安定してから検証します。

録画前に Tatami で作業を準備します。自動起動中に同じアプリを手動で起動すると、同じ ID のプロセスと窓が二つできます。開始時の失敗は後で切り取らず、準備を直します。

<a id="real-actions"></a>
## 実際の操作

|種類|フィールド|効果|
| --- | --- | --- |
|`click`|`app`, `identifier`|AX コントロールを探し、ポインタを移してクリックします。|
|`typeText`|`app`, `text`, `ms?`|想定したアプリに、一文字ずつ入力します。|
|`hover`|`app`, `identifier`|コントロールをスクロール内に見せ、ポインタを移します。|
|`scroll`|`app`, `identifier`, `pixels`|コントロールへ移動してスクロールします。|
|`key`|`chord`, `repeats?`, `holdMs?`|実際のキーを押し、その入力を表示します。|
|`hold`|`modifiers`, `keys`, `gapMs?`, `releaseAfterMs?`|切り替え操作中、実際の修飾キーを保持します。|
|`activateApp`|`app`|見えるタイトルバーを押して AX で確認します。隠れた窓には実際の切り替え操作が必要です。|
|`activateWorkspace`|`workspace`, `profile?`|完了を待つ Tatami の有効化コマンドを実行します。|
|`activateProfile`|`profile`|完了を待つプロファイルコマンドを実行します。|
|`cli`|`args`, `expect?`|別の Tatami コマンドを実行します。`accepted` はキューに入った意味だけです。|
|`borrow`|`workspace`, `expectApps?`, `timeoutMs?`|詳細な練習用の CLI 借りる操作です。公開動画では実際のキーを使います。|
|`dismissBorrow`|`settleMs?`|詳細な練習用の CLI 返却です。|
|`pointer`|`display`, `x`, `y`|正規化した画面座標にポインタを置きます。|
|`launch`|`apps`, `windows?`|主に録画前に、デモアプリを明示して起動します。|
|`quitApps`|`apps?`|指定したアプリ、またはデモ全体を終了します。|
|`dragWindow`|`app`, `target`, `x`, `y`|タイトルバーを、対象窓の正規化した位置へドラッグします。|
|`restoreWindow`|`app`|実際のドラッグで保存した大きさと位置へ戻し、元の枠を確認します。|
|`rightClick`|`app`, `identifier`|コントロールの標準コンテキストメニューを開きます。|
|`resizeWindow`|`app`, `x`, `y?`|実際の窓の端をドラッグします。|
|`virtualDisplay`|`connected`|ゲストの実際の仮想画面ヘルパーを接続・切断します。|
|`configure`|`field`, `value`|ラボの TOML で許可された設定を原子的に変更します。|
|`clipboard`|`text`|クリップボードの全形式を保存・復元し、例文を渡します。|
|`closeSettings`|フィールドなし|編集後に設定ウインドウを閉じます。|
|`prepareSettings`|フィールドなし|コントロールを操作する前に、Tatami のネイティブ設定ウインドウのサイズと位置を整えます。|
|`appWindows`|`app`, `count`|主に準備時に、実際のウインドウ数を設定します。|

`appState` はありません。用意した成功画面へ飛ばず、通常の操作と `StoryRepository` で文章、レビュー、チェック、タスク、会話を同じ場所に保存します。`seed` でだけ初期化し、作業の切り替えでは戻しません。会話はネット接続のないローカル例です。

<a id="assertions-and-pacing"></a>
## 検証とペース

|種類|フィールド|合格条件|
| --- | --- | --- |
|`expectPlacement`|`app`, `target`, `value`|対象アプリのすべてのウインドウが、比較先の左・右・上・下の指定位置にあるか確認します。|
|`expectProfileCount`|`count`|実際の CLI でプロファイル数を確認します。|
|`expectAssignment`|`app`, `workspace`, `profile`|コピーしたアプリが対象ワークスペースに含まれるか確認します。|
|`expectValue`|`app`, `identifier`, `value`|実際の入力値を読み戻します。|
|`expectStory`|`field`, `value`|保存した見出し、承認、コメント、最後のタスク・会話、チェック、完了数を確認します。|
|`expectFront`|`app`|アクセシビリティで実際のフォーカスを確認します。|
|`expectPointer`|`app`|ポインタが対象窓の内側にあることを確認します。|
|`expectCommand`|`text`, `code`|Terminal の実際のプロセス結果を確認します。|
|`expectHook`|`field`, `value`|実際の Tatami フックが書いた内容を読みます。|
|`saveWindow` / `assertWindow`|`app`|所属の変更をまたいで、一つの窓を保存・比較します。|
|`saveControlFrame` / `expectControlMoved`|`app`, `identifier`, `text`|配置エディタの操作で実際のプレビューが変わったか確認します。|
|`waitWindows`|`apps`, `timeoutMs?`|見える窓と配置の安定を待ちます。|
|`waitWorkspace`|`workspace`, `timeoutMs?`|直前の操作による有効化フックを確認します。|
|`waitProfile`|`profile`, `timeoutMs?`|プロファイルのフックを確認します。|
|`saveLayout`|`text`|見えるデモ窓の ID と枠を、名前付きの確認点に保存します。|
|`expectLayoutChanged`|`text`|現在表示されている配置が、指定した名前の保存済みチェックポイントと異なることを確認します。|
|`assertLayout`|`text`|同じ窓と枠へ、4 pt 以内で戻ることを要求します。|
|`beat`|`ms`, `note?`|明示した読む時間です。隠れた起動待ちはありません。|
|`note`|`text`|ログだけに残す説明です。|

操作の前後で権限・設定の窓を確認し、失敗なら録画を中断して記録します。失敗したものは書き出せません。

<a id="narration"></a>
## 説明と字幕

`chapter`、`caption` は `text` を持ち、字幕には `headline | explanation` を使えます。空文字はそのトラック、`clearOverlay` は全説明を消します。`key`、`hold` は実際のキー表示を作ります。独立した `keys` は手動練習専用で、公開では未実行の入力に見えるため禁止します。

`take` の既定値は `--overlay off` で、テキストは編集可能な ASS と JSON のサイドカーファイルに記録します。書き出した映像では、画面下部に字幕、左上にチャプター、右上に実際のキー入力を重ねます。半透明の背景で読みやすくしていますが、アプリの内容に重なるため、重要なコントロールはその領域を避けて配置してください。`scene` はライブのリハーサルパネルを使い、最終映像とは表示方法が異なります。

配置と時間・容量上限は [publication.json](../../publication.json)、録画・出力・確認のコマンドは [README.md](README.md) を参照してください。
