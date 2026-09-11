<!-- LANGUAGE-LINKS:START -->
[English](../TROUBLESHOOTING.md) · [한국어](../ko/TROUBLESHOOTING.md) · [日本語](TROUBLESHOOTING.md) · [简体中文](../zh-Hans/TROUBLESHOOTING.md) · [繁體中文](../zh-Hant/TROUBLESHOOTING.md)
<!-- LANGUAGE-LINKS:END -->

<a id="troubleshooting"></a>
# トラブルシューティング

<a id="a-floating-control-disappears-or-brings-its-app-back"></a>
## 独立したコントロールが消える、またはアプリが戻る

一部のアプリは会議記録や PiP を通常のウインドウと同じプロセスで表示します。作業を離れると macOS の非表示操作がその面も隠し、消えたり、アプリが再度有効化されて元のウインドウや作業が戻ったりすることがあります。

代表的な例です。

- AI Meeting Notes で録音中の Notion
- Google Chrome や Dia などの PiP

アプリを表示の例外として登録します。

1. **設定 → ワークスペース**を開き、独立したフローティングコントロールを持つアプリの設定まで移動します。
2. **+** で実行中のアプリを選びます。起動していなければ、ファイルから選択します。
3. 元の作業への割り当ては保ちます。共有アプリへの追加より範囲の狭い設定です。

登録したアプリを常に表示するわけではありません。作業や借りる表示の変更時、通常レイヤー外の最上位コントロールが画面にある場合だけプロセスを残します。その間、通常ウインドウは生存しますが、フォーカス、切り替え、配置、ドラッグ、所属操作から外れます。背後や Mission Control には見えることがあります。

条件に合うコントロールがなくなると、次の変更から通常の非表示に戻ります。画面外、透明、通常レイヤー、補助プロセス所有、最上位 AX ウインドウでないものは対象外です。

> [!NOTE]
> PiP がタイル表示される問題は別です。通常レイヤー以外の PiP は自動で対象外になるため登録不要です。作業の切り替えでブラウザと一緒に PiP が隠れる場合だけ登録してください。

`config.toml` を直接管理する場合は、正確なアプリのバンドル ID を使います。

```toml
[settings.visibility]
overlayAwareApps = [
  "notion.id",
  "com.google.Chrome",
  "company.thebrowser.dia",
]
```

消える場合は**設定 → 一般**でデバッグログを有効にし、一度作業を切り替えて `~/.config/tatami/tatami.log` の `OverlayAware evaluate ... preserve=` を確認します。`preserve=false` は条件を満たさなかったことを示します。

<a id="fullscreen-zoom-changes-after-connecting-a-display"></a>
## ディスプレイの接続後に全画面表示が変わる

現在のプロファイルとワークスペースを確認してください。接続中のモニターが変わると、ディスプレイルールによってプロファイルが自動で切り替わることがあります。別のプロファイルに同じアプリがあっても、配置と全画面表示の状態はワークスペースごとに記憶されます。使う各プロファイルで配置を設定するか、意図しない切り替えならプロファイルのディスプレイルールを調整してください。
