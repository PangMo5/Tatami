<!-- LANGUAGE-LINKS:START -->
[English](../../README.md) · [한국어](../ko/README.md) · [日本語](README.md) · [简体中文](../zh-Hans/README.md) · [繁體中文](../zh-Hant/README.md)
<!-- LANGUAGE-LINKS:END -->

<a id="tatami-demo-lab"></a>
# Tatami Demo Lab

実際の Tatami を録画し、統一した紹介動画を機能説明の横に置きます。アプリと内容はデモ用ですが、切り替え、配置、借りる操作、フォーカスはインストールした Tatami が行います。

<a id="publication-contract"></a>
## 公開用動画の規則

[`publication.json`](../../publication.json) が一覧と編集上限です。各場面を Web の区分に結び、時間とサイズを制限します。

紹介動画はデザイン、執筆、レビュー、借りる操作、自動化から、実際の画面構成変更まで進みます。各動画集では作業、プロファイルと画面、配置とフォーカス、借りる操作、表示方法、CLI・フック、ガイドを扱います。一覧は `publication.json` から生成します。

主動画は**作業を変えても元の場所に戻れる**ことを示します。機能別は別の活動を扱い、同じ動画を繰り返しません。[範囲と検証の境界](COVERAGE.md)を参照してください。

<a id="capture--export--review--install-locally"></a>
## 録画 → 書き出し → 確認 → ローカル反映

普段のデスクトップではなく専用の Tart VM を使います。`reset` と `seed` は実行先の Tatami を終了して設定を変えます。設定と配置は `.build/lab/` に隔離し、環境設定を別途保存して `democtl restore` で復元できます。

```sh
# Host: run from the repository root.
swift build --package-path Tools -c release
TOOL=Tools/.build/release/tatami-tools
"$TOOL" vm-sync

# Guest: a fresh seed for every scene. Existing takes are never overwritten.
tart exec tatami-demo /Users/admin/DemoLab/.build/tools/tatami-tools capture \
  --root /Users/admin/DemoLab --output /Users/admin/DemoLab/recordings/publish

# Host: fetch that exact batch, including originals, metadata and scene snapshots.
GUEST_DIR=DemoLab/recordings/publish "$TOOL" vm-fetch-recordings DemoLab/recordings/publish

# Host: new output directory; no ambiguous “latest take” selection.
"$TOOL" export --takes DemoLab/recordings/publish --output ~/Downloads/TatamiDemoLab-review

# Open index.html and inspect playback, opening frames, actions and every feature.
# Install the verified bundle into this checkout only; this does not push or deploy.
"$TOOL" install-assets ~/Downloads/TatamiDemoLab-review
```

ホストには Swift 6.2 以降、`tart`、libass/libx264 に対応した `mpv`、`ffmpeg`、`ffprobe` が必要です。ホストのコマンドはリポジトリのルートで実行します。ゲストには Xcode Command Line Tools が必要です。ソースの同期時にビルド済みの自動化実行ファイルも転送するため、ゲストでパッケージをダウンロードする必要はありません。レコーダーは Tatami の Tuist グラフから独立した SwiftPM パッケージです。

自動化には `swift-subprocess`、ArgumentParser、SwiftSoup、Hummingbird、`swift-markdown`、`swift-cmark`、Swift Crypto を使います。JSON とプロパティリストは Foundation で処理します。録画の合格条件、翻訳単位、動画の時間・容量の上限は Tatami 固有のルールとして管理します。依存関係のバージョンは `Tools/Package.resolved` で固定します。

書き出し側の Mac には Fontconfig も必要です。エンコード前に指定したフォントと、すべての字幕文字が表示できるかを確認します。OCR 検証では、映像に重ねた字幕をタイムラインと照合します。

<a id="a-small-set-of-useful-apps"></a>
## 実際に使える小さなアプリ集

|ワークスペース|アプリ|実際の作業|
| --- | --- | --- |
|Design|Canvas + Docs|配色を変え、保存した下書きを確認し、PNG を書き出します。|
|Write|Editor + Docs|資料を読み、見出しを直して下書きを保存します。|
|Review|Review + Docs|保存した文章を確認し、コメントして承認します。|
|Chat|Chat|ローカルのデモ返信を入力して送ります。|
|Build|Terminal|実際の Tatami CLI と同梱スクリプトを実行します。|
|Notes（借りる専用）|Notes|次の作業を追加し、チェック項目を完了します。|
|Focus|Canvas + Notes|その作業でメモを手前に置いて使います。|
|共有アプリ|Monitor|保存した状態や実際の作業・フィードバックのフックを確認します。|

8 個のアプリが保存済みローカルデータを使います。保存すると Review と Canvas に反映され、PNG も実際に作ります。メモや会話は切り替えても残ります。Terminal は許可したコマンドだけを実行し、フックは実際の環境を受け取ります。会話サービスには接続せず、AI は明示したローカル例です。

<a id="what-changed-in-the-capture-contract"></a>
## 録画規則の変更

場面は二段階に分かれます。

- `setup` は**録画前**に終了処理、起動、作業の準備、データと配置を整えます。
- `steps` が映る操作です。録画前に `openingApps` の窓と配置を安定させます。`autoopen` だけは自動で開く機能を示すため、短い空画面から始めます。

録画前と各操作の前後で、背後も含め権限・設定ウインドウを確認します。切り抜きやエラー抑制ではなく、そのダイアログを解決してください。

**録画ツールと Tatami の許可は別です。** `doctor` に通っても古い Tatami の画面収録要求が残っていました。「常に手前」は別のストリームなので、録画の準備だけでは確認できません。`shared` を試して実際の窓を確認します。Monitor は全場面で開かず、`shared` が録画前に明示的に開きます。

`waitWindows` は対象アプリと配置の安定を待ちます。`saveLayout`/`assertLayout` は切り替え、返却、ズーム復帰後の同じ ID と枠を比較し、窓の増減や 4 pt を超える差で失敗します。

`key`、`hold` は実際の入力からキー表示を作ります。CLI をキー操作に見せる `keys` は使えません。最初のエンコード済みフレームがなければ開始せず、その単調時刻で字幕と動画を合わせます。

<a id="presentation"></a>
## 動画の見せ方

元の MOV には、撮影したデスクトップ全体が含まれます。書き出しは 1920×1200、2 画面の場合は 1920×600 です。説明字幕は映像の下部、章名は左上、実際のキー入力は右上に重ねます。半透明の背景により、明るいアプリでも暗いアプリでも読みやすくなります。色はウェブサイトの配色を使うため、表示の変更に再撮影は必要ありません。

サムネイルの時点は、`publication.json` の `posterSeconds` または `posterCaptionIndex` で指定します。機能が実際に反映された後のフレームを選んでください。サムネイルの URL には画像のハッシュを使うため、画像だけを差し替える場合に動画を再エンコードする必要はありません。

字幕の編集で元映像を再利用できるのは、撮影した操作、入力内容、検証条件、待機時間がすべて同じ場合だけです。書き出しツールは撮影時に固定したシーンのハッシュと操作を検証し、元のタイムライン上の説明文を差し替えます。検証資料には、編集前後のシーンとタイムラインを両方含めます。

各テイクには次のファイルがあります。

- `.mov`：字幕なしの原本。
- `.ass`：編集できる説明と実際のキー入力時刻。
- `.timeline.json`：全イベントの開始・終了時刻。
- `.take.json`：成否、場面ハッシュ、バージョン、言語、出力別フレーム数と損失、開始時刻、表示モード。
- `.scene.json`：録画開始時に固定した場面の正確なバイト列。

失敗したテイクは診断用に残しますが、書き出しには使えません。撮影条件の検証、正常な字幕、1% 未満のフレーム欠落、遅れのない冒頭字幕、映像とタイムラインの長さの一致が必要です。出力は時間・容量の上限を守り、H.264/yuv420p を使用し、FFmpeg で全編をデコードできる必要があります。`faststart` は MP4 ヘッダーを映像データより前に配置します。

書き出しには再生ギャラリー、ポスター、検証用フレーム、元映像と出力のハッシュ、すべての付随ファイルが含まれます。自動検証だけでは実際の動作確認を代替できません。特に共有ウインドウのミラーリングとフォーカス先は目視確認が必要です。ウェブプレイヤーは標準コントロールと `preload="none"` を使い、手動で再生し、同時に再生する動画は一つです。各動画集にはサムネイル一覧、件数、前後のボタンがあります。各動画から関連する設定キーにも移動できます。矢印キー、Home/End、個別動画へのリンクは、一覧を別途展開せずに使えます。

2 画面ではゲストに実際の仮想画面を接続し、別々に録画して最初の時刻で揃えます。[確認済み構成](MULTI-DISPLAY.md)を参照してください。

<a id="work-on-one-scene"></a>
## 一つの場面を調整する

録画コマンドは専用ゲスト内で実行します。

```sh
.build/DemoLab/bin/democtl doctor
.build/DemoLab/bin/democtl reset
.build/DemoLab/bin/democtl seed
.build/DemoLab/bin/democtl scene tour --dry-run    # prints setup and visible steps
.build/DemoLab/bin/democtl take tour --output recordings/iteration/tour.mov
# Host: after fetching that batch; run from the repository root.
Tools/.build/release/tatami-tools export --takes DemoLab/recordings/iteration \
  --output ~/Downloads/TatamiDemoLab-iteration --scenes tour
```

`democtl scene` は実時間の表示で練習します。`take` の既定は `--overlay off` で、公開にはこのモードだけを使います。練習パネルと出力デザインは別です。`subtitle burn` は確認コピーを作れますが、上限・Web・証拠の検証は `tatami-tools export` を使います。

終了後はゲストで `democtl quit`、`democtl restore` を実行します。ホスト側の Tatami や設定には関与しません。

<a id="development-and-reference"></a>
## 開発と参考情報

```sh
swift test --package-path Tools
swift run --package-path Tools tatami-tools build-tool-notices --check
swift run --package-path Tools tatami-tools bundle-apps
DEMOLAB_LOCALIZATION_DIR="$PWD/DemoLab/.build/DemoLab/Localization" \
  swift test --package-path DemoLab
```

- [場面の語彙](SCENES.md)
- [VM の準備](VM-TART.md)
- [権限](PERMISSIONS.md)
- [実際の複数画面録画](MULTI-DISPLAY.md)

<a id="five-language-production"></a>
## 5 言語での制作

`en`、`ko`、`ja`、`zh-Hans`、`zh-Hant` に対応します。`Localization/Localizable.xcstrings` は UI と初期内容、`Localization/Films.json` は動画と入力、`Localization/Interface.json` は確認ギャラリーを管理します。固定 ID がなければ製品カタログの AX ラベルを使います。アプリ名やユーザーの作業・プロファイル名は保ちます。

```sh
Tools/.build/release/tatami-tools localize-scenes
Tools/.build/release/tatami-tools vm-sync
# Inside the guest:
.build/tools/tatami-tools capture --locale ko --output recordings/ko-batch
# After fetching that explicit batch to the host:
Tools/.build/release/tatami-tools export --locale ko --takes DemoLab/recordings/ko-batch --output ~/Downloads/Tatami-ko
```

デモと Tatami の言語を揃え、入力と検証に同じ文を使います。実際の CLI コマンドと出力は保ちます。最終動画が 30 fps なので、録画も 30 fps にして不要な処理を減らします。

`tatami-tools record-locales` は言語ごとに、未撮影または検証に失敗したテイクを見つけます。英語の映像を翻訳済み UI の検証とは見なしません。失敗したシーンは診断用に残し、ほかの言語は独立して進められます。

小さなツール窓は右下から始め、主動画では左下へ実際に動かします。調整時も文書の主な読み取り領域を空けてください。

ターミナルのコマンド終了後もローカルサイトのプレビューを続けるには、リポジトリのルートで `Tools/.build/release/tatami-tools preview-site --background` を実行します。
