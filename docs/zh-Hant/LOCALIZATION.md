<!-- LANGUAGE-LINKS:START -->
[English](../LOCALIZATION.md) · [한국어](../ko/LOCALIZATION.md) · [日本語](../ja/LOCALIZATION.md) · [简体中文](../zh-Hans/LOCALIZATION.md) · [繁體中文](LOCALIZATION.md)
<!-- LANGUAGE-LINKS:END -->

<a id="tatami-localization-and-ux-writing"></a>
# Tatami 在地化與 UX 文案

不同語言保留同一套產品模型，但不逐字翻譯英文。每種語言都應讓下一步操作清楚可見：工作空間是工作情境，設定組合是一組適合某種環境的工作空間，借用則把另一個工作空間暫時放在旁邊。

<a id="supported-locales"></a>
## 支援的語言

|地區語言|對象|文案風格|
| --- | --- | --- |
|`en`|全球英文使用者|採用 Apple 風格的清楚行動文案：先說明結果，使用熟悉的詞，只在有助於下一步操作時介紹實作細節。|
|`ko`|韓國|採用 Toss 風格的易懂表達：一次傳達一個訊息，去掉贅詞，先說好處再說實作。|
|`ja`|日本|採用 LINE 與 SmartHR 風格：自然對話、降低閱讀負擔，錯誤訊息不責怪使用者，並說明下一步操作。|
|`zh-Hans`|中國大陸|採用 Ant Design 的使用者中心文案：重要資訊優先，說明結果與下一步，避免命令口吻及內部術語。|
|`zh-Hant`|台灣|以台灣用語與工作目的為主，使用熟悉的 `App`／`顯示器`／`設定`／`快速鍵`。|

`zh-Hant` 目前以台灣用語為準，不混入香港詞彙。未來支援香港時，另行新增 `zh-HK`。

<a id="tatami-voice"></a>
## Tatami 的表達方式

- 先說明結果，例如：「把這個工作空間放到目前工作空間旁邊。」
- 一句話只表達一個意思，前提條件另起一句。
- 說使用者操作的對象，不說 Tatami 的內部子系統。
- 按鈕直接使用動作，如「套用設定」「開啟系統設定」。
- 在使用者確認前，說明破壞性操作的結果。
- 不要用委婉措辭掩蓋錯誤。說明哪裡失敗，以及使用者接下來可以做什麼。
- 保留路徑、指令、鍵盤符號、App 名稱，以及使用者輸入的工作空間與設定組合名稱。

<a id="core-terminology"></a>
## 核心用語

|概念|`en`|`ko`|`ja`|`zh-Hans`|`zh-Hant`|
| --- | --- | --- | --- | --- | --- |
|工作空間|Workspace|작업 공간|ワークスペース|工作区|工作空間|
|工作空間鏈|Workspace Chain|작업 공간 체인|ワークスペースチェーン|工作区链|工作空間鏈|
|設定組合|Profile|프로필|プロファイル|配置方案|設定組合|
|共用 App|Shared Apps|공용 앱|共有アプリ|共享应用|共用 App|
|借用|Borrow|빌려오기|借りる|借用|借用|
|暫存區|Scratchpad|임시 공간|一時スペース|暂存区|暫存區|
|並排|Tiling / Tiled|타일링|タイル表示|平铺|並排|
|置頂|Always on Top|항상 위|常に手前|置顶|置頂|
|維持原狀 / 忽略|Leave As Is|그대로 두기|そのまま|保持原样|維持原狀|
|焦點|Focus|포커스|フォーカス|焦点|焦點|
|視窗切換|Window Switching|창 전환|ウインドウ切り替え|窗口切换|視窗切換|
|操作回饋|On-Screen Feedback|화면 알림|操作フィードバック|操作反馈|操作回饋|

一致使用這些用語。可以為自然表達改寫整句，但不能悄悄改變功能含義。

韓文中只保留產品名 `Tatami` 為英文。功能使用易懂的韓文：작업 공간、프로필、공용 앱、빌려오기、임시 공간、항상 위。優先使用表示結果的 `항상 위에 두기`，避免技術音譯 `플로팅`。

<a id="english-voice"></a>
### 英文文案

- 遵循 Apple 寫作原則：清楚、簡潔、實用、行動明確，先講結果或好處，再講步驟。
- 使用使用者可見的對象與動作 `Always on Top`、`Window Switching`、`On-Screen Feedback`，取代內部術語 `Floating`、`Cycle`、`HUD`、`Overlay`。
- 按鈕和選單指令以動詞開頭，設定標籤說明啟用後會發生什麼。
- 空白狀態說明缺少什麼，並在有幫助時提供一個下一步操作。錯誤說明失敗內容、仍然安全的部分與復原方法。
- 只在檢查或設定實作本身的地方顯示 `BSP`、`TOML` 與檔案名稱。

<a id="korean-voice"></a>
### 韓文文案

- 標題、空白狀態、說明、確認與錯誤使用韓文 해요 體。按鈕、選項和區塊標題用簡短動作或名詞，便於瀏覽。
- 描述使用者的動作，而非系統狀態：把 `선택된 항목 없음` 改為 `선택한 항목이 없어요`，把 `추가됨` 改為 `추가했어요`。
- 問題後說明可行的下一步，不在內文中重複標題。
- 優先日常結果而非實作術語，用 `화면 알림` 取代 `HUD` 或 `오버레이`，但保留必要的 `BSP`、`TOML` 與按鍵名稱。
- 不要在使用者輸入的名字後直接附加會變化的韓文助詞。把 `“%@”을 삭제할까요?` 改寫為 `삭제할까요? · “%@”`。

<a id="japanese-voice"></a>
### 日文文案

- 使用熟悉的口語，避免過多客套。說明使用完整的 `です／ます` 句式，按鈕和選單使用簡短動作。
- 優先使用 `借りる`、`常に手前`、`タイル表示`、`一時スペース`、`作業環境`，避免生硬直譯或未經解釋的外來語。
- 空白狀態使用 `項目が選択されていません` 這樣的完整陳述，錯誤說明問題與下一步，不責怪使用者。

<a id="simplified-chinese-voice"></a>
### 簡體中文文案

- 先說結果，再說操作。措辭簡短完整，失敗時明確說明下一步。
- 一致使用 `应用`、`场景`、`借用`、`置顶`、`窗口切换`、`操作反馈`，不要在中國大陸介面文案中混用英文 `App`。
- 標籤不加多餘標點，完整句子與多步驟說明使用適當標點。

<a id="traditional-chinese-voice"></a>
### 繁體中文文案

- 以台灣用語為準，使用 `App`、`工作空間`、`設定組合`、`顯示器`、`快速鍵`、`借用`、`置頂`、`視窗切換`、`操作回饋`。
- 優先描述工作與可見結果，而非逐字翻譯技術用語。在 macOS 情境中使用熟悉的 `點按`、`檔案`、`游標`、`螢幕`。
- 不要在 `zh-Hant` 中混入香港特有詞彙，需要時另行新增 `zh-HK`。

<a id="implementation-rules"></a>
## 實作規則

- App 與 `TatamiKit` 的介面字串放在 `Tatami/Resources/Localizable.xcstrings`。`TatamiKit` 是靜態框架，因此執行時目錄由 Tatami 主 App 套件持有。
- 保持擷取的英文來源鍵穩定，把檢查後的英文顯示文字存為明確的 `en` 在地化值，避免每次改善文案都重新命名 Swift 查詢鍵。
- 模型、輔助程式碼與視圖間傳遞固定文案使用 `LocalizedStringResource`；使用者輸入的名稱與找到的 App、顯示器名稱保留為 `String`。
- 把字串常值直接傳給 SwiftUI 控制項。
- 只在 SwiftUI 初始化器之外需要具體 `String` 時使用 `String(localized:)`。
- 插值完整句子，不串接已翻譯的片段。
- 保留格式預留位置，允許各語言調整順序。
- 使用者可見的數字與日期使用支援地區語言的 `FormatStyle`。
- 不要在執行時把在地化文案轉換為大寫。
- 介面文案不用 em dash，拆成句子或使用符合語言習慣的標點。

<a id="documentation-website-and-demo-films"></a>
## 文件、網站與示範影片

App 之外也遵循相同用語與寫作規則。

- 以英文文件為來源，從 `Localization/Docs.json` 產生各語言 README 與指南，保留指令、程式碼範例、識別碼、連結目標及明確的標題錨點。
- `Localization/Web.json` 儲存完整網站文字單元。每種語言有獨立 URL 與文件語言，涵蓋導覽、輔助使用標籤、載入與錯誤狀態、文件和影片集控制項。
- Demo Lab 使用獨立的 `DemoLab/Localization/Localizable.xcstrings` 目錄，各示範 App 都在主套件中包含它。共用輔助程式碼傳遞 `LocalizedStringResource`，儲存的示範內容依本次錄製語言解析完整字串。
- 字幕、標題與人工輸入共用 `DemoLab/Localization/Films.json`，從相同值產生輸入斷言。翻譯後的標籤可能相同，因此優先使用穩定的輔助使用識別碼。
- 依每種 App 語言錄製並驗證。英文介面加翻譯字幕，不能證明實際測試了在地化 App。
- 在建置時拒絕缺少翻譯或被變更的預留位置，不透過靜默改用英文讓建置通過。
- 歷史版本說明與授權、著作權文字保留原文。翻譯導覽與解釋，並明確連結到具效力的原文。

<a id="review-checklist"></a>
## 檢查清單

1. 使用 `SWIFT_EMIT_LOC_STRINGS=YES` 建置，再把編譯器產生的 `.stringsdata` 同步到目錄。
2. 確認每個可翻譯鍵都有所有支援語言的翻譯。
3. 確認每條翻譯保留來源預留位置集合。
4. 透過 scheme 的 Application Language 覆寫設定，分別啟動各語言。
5. 檢查設定、選單列、破壞性確認、空白狀態與所有設定導覽步驟，確認沒有截斷或混合語言。
6. 發布前請母語審閱者檢查語氣與用語。依畫面情境撰寫目錄，不以機器翻譯填入。

<a id="public-references"></a>
## 公開參考資料

- Toss：<https://toss.tech/article/21022>
- Apple 人機介面指南：寫作：<https://developer.apple.com/design/human-interface-guidelines/writing>
- Apple WWDC25：用小幅文案改動帶來大影響：<https://developer.apple.com/videos/play/wwdc2025/404/>
- LINE Voice：<https://designsystem.line.me/about/line-voice-ja>
- SmartHR 寫作風格：<https://smarthr.design/products/contents/writing-style/>
- SmartHR 介面文案：<https://smarthr.design/products/contents/ui-text/app-writing/>
- SmartHR 錯誤訊息：<https://smarthr.design/products/contents/error-messages/overview/>
- Ant Design 文案：<https://ant.design/docs/spec/copywriting-cn/>
- 台灣政府網站內容指引：<https://www.webguide.nat.gov.tw/guidelines/442/show>
