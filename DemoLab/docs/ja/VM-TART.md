<!-- LANGUAGE-LINKS:START -->
[English](../VM-TART.md) · [한국어](../ko/VM-TART.md) · [日本語](VM-TART.md) · [简体中文](../zh-Hans/VM-TART.md) · [繁體中文](../zh-Hant/VM-TART.md)
<!-- LANGUAGE-LINKS:END -->

<a id="recording-in-a-tart-vm"></a>
# Tart VM で録画する

専用の `tatami-demo` で個人の窓・設定・権限を分離します。macOS 26.6.2、固定 1920×1200、実際の Tatami と 8 アプリを使います。二画面目は [MULTI-DISPLAY.md](MULTI-DISPLAY.md) の方法です。

<a id="prepare-the-guest"></a>
## ゲストの準備

ホストには Apple silicon と `exec` 対応 Tart、ゲストにはエージェント、Command Line Tools、Python 3、Tatami が必要です。明記がなければ `DemoLab/` で実行します。

```sh
./vm/tart/host-bootstrap.sh
```

`1920x1200px` と `--no-display-refit` で固定し、ホストの窓サイズを変えても録画の解像度が変わらないようにします。共有は `/Volumes/My Shared Files/demolab` です。

撮影する Tatami のビルドを、別の共有から渡します。

```sh
# Include both shares when starting the dedicated VM.
tart run tatami-demo --dir="demolab:$PWD" --dir="tatami:/Applications"

# From a separate host terminal:
tart exec tatami-demo /bin/bash -lc \
  'TATAMI_APP="/Volumes/My Shared Files/tatami/Tatami.app" \
   "/Volumes/My Shared Files/demolab/vm/tart/guest-provision.sh"'
```

`TATAMI_APP` の代わりに `TATAMI_DMG` も使えます。SwiftPM はゲストのローカルでビルドし、全アプリを LaunchServices に登録して ID で探せるようにします。

VM の窓や画面共有で開き、[PERMISSIONS.md](PERMISSIONS.md) に従って許可します。録画ツールと手前表示の両方を試します。今のエージェントには許可がありますが、新しい環境は別途確認します。DB を変えたり、録画だけでミラー権限を判断したりしません。

<a id="record-an-explicit-batch"></a>
## 指定したバッチを録画する

```sh
# Host: sync current sources and rebuild in the guest.
./vm/tart/sync.sh

# Guest: each scene gets fresh lab data and preferences suppression.
tart exec tatami-demo /bin/bash -lc \
  'cd ~/DemoLab && python3 scripts/capture.py --continue-on-error \
   --output /Users/admin/DemoLab/recordings/review-batch'

# Host: a new destination, retaining originals and all provenance sidecars.
GUEST_DIR=DemoLab/recordings/review-batch \
  ./vm/tart/fetch-recordings.sh recordings/review-batch

python3 scripts/export.py --takes recordings/review-batch \
  --output ~/Downloads/TatamiDemoLab-review
```

一部だけなら `--scenes tour cli desk` を使います。上書きせず、`--continue-on-error` は失敗を残して場面ごとに初期化し、失敗があれば非ゼロで終わります。`capture-report.json` に記録し、現在の場面に合う合格テイクだけを書き出します。

録画中はホストの重いエンコード・コンパイルを避けます。CPU を共有し損失は画面別に測るため、録画後に処理します。

<a id="shared-filesystem-correctness"></a>
## 共有ファイルの正確性

両方向で新しい名前のアーカイブを使います。ホストが前のファイルを移した後、同名への書き込みが古い内容や inode を参照しました。新規名でこの経路をなくします。

管理対象だけを同期し、削除した Swift が残らないようにします。`.build` と録画は保持します。固有マーカーで共有を確認し、両側の SHA256 を照合して新規フォルダへ展開します。動画と全付属データを含みます。

<a id="finish-or-preserve-the-image"></a>
## 終了とイメージの保存

```sh
tart exec tatami-demo /bin/bash -lc \
  'cd ~/DemoLab && ./bin/democtl quit && ./bin/democtl display disconnect && ./bin/democtl restore'
```

`restore` は撮影前の設定を戻し、個人ホストには触れません。停止して確認したゲストは `tart clone` で保存できます。廃棄前に原本と証拠を外へ保管してください。

<a id="verified-boundary"></a>
## 検証した範囲

v4 では実際の収録、入力・AX、タイルと借りる操作、二画面、チェーン、自動プロファイルを確認しました。ドック、実ジェスチャ、混在 DPI、HDR、新 OS は別検証です。全画面復帰の失敗は [COVERAGE.md](COVERAGE.md) にあります。
