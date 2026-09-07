<!-- LANGUAGE-LINKS:START -->
[English](../MULTI-DISPLAY.md) · [한국어](../ko/MULTI-DISPLAY.md) · [日本語](MULTI-DISPLAY.md) · [简体中文](../zh-Hans/MULTI-DISPLAY.md) · [繁體中文](../zh-Hant/MULTI-DISPLAY.md)
<!-- LANGUAGE-LINKS:END -->

<a id="multiple-displays-inside-the-recording-vm"></a>
# 録画 VM 内の複数画面

macOS 26.6.2 の Tart ゲストは**内部の CoreGraphics 仮想画面**を作れます。ホストの `VZMacGraphicsDeviceConfiguration` に二つ目を追加するのとは別です。

以前は VZ のハードウェア制限をすべての画面の制限と誤解していました。実際に 1920×1200 の二画面が認識され、Tatami が Review と Chat を分け、独立した動画を録画できました。

<a id="reproduce"></a>
## 再現

専用ゲスト内で実行します。

```sh
.build/tools/tatami-tools build-virtual-display
.build/DemoLab/bin/democtl display connect
.build/DemoLab/bin/democtl displays
.build/DemoLab/bin/democtl reset
.build/DemoLab/bin/democtl seed
.build/DemoLab/bin/democtl take desk --display all --output recordings/desk.mov
.build/DemoLab/bin/democtl quit
.build/DemoLab/bin/democtl display disconnect
```

非公開の `CGVirtualDisplay` はラボ専用で Tatami には含めません。[DeskPad の定義](https://github.com/Stengo/DeskPad/blob/main/DeskPad/CGVirtualDisplayPrivate.h)を参照し、1920×1200 の通常解像度の画面を作ります。切断や期限まで保持し、PID の実行ファイルを確認してから終了します。不在・未対応なら明示的に失敗します。

<a id="synchronization-and-composition"></a>
## 同期と合成

`--display all` は画面ごとに原本を書きます。共通時計からの最初の差、画面の原点、個別のフレームと損失数を記録し、ホストへ取得してから使います。

```sh
Tools/.build/release/tatami-tools compose-displays DemoLab/recordings desk
```

物理原点の順と時刻差で揃え、原本を残して無損失の中間ファイルを作ります。単画面と同じ配色の横長動画にし、画像の複製やアニメーションで二画面を装いません。

<a id="hotplug-is-a-separate-scene"></a>
## 接続・取り外しは別の場面です。

画面接続のシーンでは、メイン画面を連続して録画します。2 台目の仮想ディスプレイが接続されると、別のレコーダーがその画面を録画し、切断の直前に停止します。両映像は実際の最初のフレーム時刻で同期します。合成時は左右に並べ、2 台目を録画していない区間は空白にします。メイン画面の複製や、切断後の静止画表示は行いません。撮影マニフェストには両方の元映像のハッシュと、2 台目の録画区間を保存します。

実物のケーブル、ドック、HDR、混在 DPI、ジェスチャ認識は別の実機確認です。ゲスト OS が変われば非公開 API の互換性を再確認します。
