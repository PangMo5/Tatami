<!-- LANGUAGE-LINKS:START -->
[English](../SCENES.md) · [한국어](../ko/SCENES.md) · [日本語](../ja/SCENES.md) · [简体中文](../zh-Hans/SCENES.md) · [繁體中文](SCENES.md)
<!-- LANGUAGE-LINKS:END -->

<a id="scenes-and-acceptance"></a>
# 場景與驗收

場景為 JSON，包含 `name`、`title` 與可選的 `requires`、`setup`、`openingApps`、`steps`。`setup` 在錄製前執行，`steps` 是可見過程，操作實際 Tatami 與原生示範 App。

```sh
./bin/democtl scene tour --dry-run
./bin/democtl take tour --output recordings/iteration/tour.mov
```

<a id="preparation"></a>
## 準備

在 `openingApps` 宣告首影格必須可見的 App，多重集合必須符合實際一般視窗，包含刻意的重複資料視窗。`autoopen` 以開啟工作空間為首操作，因此使用空陣列。幾何穩定 400 ms 後檢查。

錄製前透過 Tatami 準備工作空間。不要把尚未完成的自動開啟與手動重新啟動混用，否則同一套件 ID 可能出現兩個程序、兩個視窗。開場檢查失敗應修正準備過程，不在後製裁掉意外視窗。

<a id="real-actions"></a>
## 實際操作

|類型|欄位|效果|
| --- | --- | --- |
|`click`|`app`, `identifier`|定位原生 AX 控制項，移動游標並點按。|
|`typeText`|`app`, `text`, `ms?`|在預期聚焦 App 中逐字輸入。|
|`hover`|`app`, `identifier`|捲動讓原生控制項進入可見區域，再移入游標。|
|`scroll`|`app`, `identifier`, `pixels`|移動到原生控制項並捲動。|
|`key`|`chord`, `repeats?`, `holdMs?`|按實際快速鍵並產生相應按鍵顯示。|
|`hold`|`modifiers`, `keys`, `gapMs?`, `releaseAfterMs?`|在切換互動期間持續按住實際輔助鍵。|
|`activateApp`|`app`|點按可見標題列，再透過 AX 確認焦點。被遮住的視窗需要實際切換操作。|
|`activateWorkspace`|`workspace`, `profile?`|執行等待完成的 Tatami 啟用指令。|
|`activateProfile`|`profile`|執行等待完成的設定組合指令。|
|`cli`|`args`, `expect?`|執行其他 Tatami 指令；`accepted` 只表示排入佇列。|
|`borrow`|`workspace`, `expectApps?`, `timeoutMs?`|進階排練用 CLI 借用，發布影片使用實際按鍵。|
|`dismissBorrow`|`settleMs?`|進階排練用 CLI 歸還。|
|`pointer`|`display`, `x`, `y`|用正規化顯示器座標放置游標。|
|`launch`|`apps`, `windows?`|明確啟動示範 App，主要用於錄製前。|
|`quitApps`|`apps?`|結束指定示範 App 或整個集合。|
|`dragWindow`|`app`, `target`, `x`, `y`|把實際標題列拖到目標視窗的正規化位置。|
|`restoreWindow`|`app`|透過實際游標拖移還原視窗大小與位置，再驗證原始邊界。|
|`rightClick`|`app`, `identifier`|開啟控制項的原生快顯選單。|
|`resizeWindow`|`app`, `x`, `y?`|拖移原生視窗邊緣。|
|`virtualDisplay`|`connected`|連接或中斷實際虛擬顯示器工具。|
|`configure`|`key`, `value`|不可分割地修改實驗 TOML 中允許的即時設定。|
|`clipboard`|`text`|提供本機範例文字，同時保留並還原所有剪貼簿類型。|
|`closeSettings`|—|編輯後關閉原生設定視窗。|
|`appWindows`|`app`, `count`|設定原生視窗數量，主要用於準備。|

沒有 `appState` 指令，視圖不能跳到預製成功狀態。它們使用一般控制項，透過 `StoryRepository` 共用儲存的文案、審閱、檢查、待辦與訊息。`seed` 重設故事，切換工作空間不會。聊天是沒有網路傳輸的本機示範。

<a id="assertions-and-pacing"></a>
## 斷言與節奏

|類型|欄位|驗收條件|
| --- | --- | --- |
|`expectPlacement`|`app`, `target`, `value`|驗證來源 App 的所有視窗都位於目標視窗的左側、右側、上方或下方。|
|`expectProfileCount`|`count`|透過實際 CLI 驗證設定組合數量。|
|`expectAssignment`|`app`, `workspace`, `profile`|驗證複製的 App 已指派給目標工作空間。|
|`expectValue`|`app`, `identifier`, `value`|讀回實際原生輸入值。|
|`expectStory`|`field`, `value`|驗證儲存的標題、核准、意見、最後待辦與訊息、檢查或完成項。|
|`expectFront`|`app`|透過輔助使用驗證實際聚焦 App。|
|`expectPointer`|`app`|要求游標位於目標視窗內。|
|`expectCommand`|`text`, `code`|驗證示範 Terminal 的實際程序結果。|
|`expectHook`|`field`, `value`|檢查實際 Tatami Hook 寫入的資料。|
|`saveWindow` / `assertWindow`|`app`|跨成員關係變化儲存並比較同一視窗。|
|`saveControlFrame` / `expectControlMoved`|`app`, `identifier`, `text`|驗證排列編輯操作實際改變了預覽。|
|`waitWindows`|`apps`, `timeoutMs?`|等待可見視窗和穩定幾何。|
|`waitWorkspace`|`workspace`, `timeoutMs?`|觀察上一步產生的啟用 Hook。|
|`waitProfile`|`profile`, `timeoutMs?`|觀察設定組合 Hook。|
|`saveLayout`|`text`|依檢查點名稱儲存可見示範視窗 ID 與邊界。|
|`assertLayout`|`text`|要求相同視窗集合與邊界在 4 點誤差內還原。|
|`beat`|`ms`, `note?`|明確宣告的閱讀停頓，沒有隱藏啟動等待。|
|`note`|`text`|僅記錄到日誌的說明。|

每步前後檢查權限與設定視窗，失敗時中止錄製並寫入失敗記錄，輸出器拒絕失敗片。

<a id="narration"></a>
## 說明與字幕

`chapter`、`caption` 攜帶 `text`，字幕可使用 `headline | explanation`。空文字清除目前軌道，`clearOverlay` 清除全部說明；`key`、`hold` 自動產生按鍵顯示。獨立 `keys` 標籤只允許手動排練，發布場景停用，以免暗示未發生的輸入。

`take` 預設 `--overlay off`，文字儲存在可編輯 ASS 與 JSON 中。輸出在實際桌面上下預留區域，字幕和按鍵不遮擋 App。`scene` 的即時排練面板與最終設計不同。

位置與時間、容量預算見 [publication.json](../../publication.json)；錄製、輸出與檢查指令見 [README.md](../../zh-Hant/README.md)。
