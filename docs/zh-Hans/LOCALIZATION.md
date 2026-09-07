<!-- LANGUAGE-LINKS:START -->
[English](../LOCALIZATION.md) · [한국어](../ko/LOCALIZATION.md) · [日本語](../ja/LOCALIZATION.md) · [简体中文](LOCALIZATION.md) · [繁體中文](../zh-Hant/LOCALIZATION.md)
<!-- LANGUAGE-LINKS:END -->

<a id="tatami-localization-and-ux-writing"></a>
# Tatami 本地化与 UX 文案

不同语言保留同一套产品模型，但不逐字翻译英语。每种语言都应让下一步操作清楚可见：工作区是任务环境，配置方案是一组适合某种环境的工作区，借用则把另一个工作区暂时放在旁边。

<a id="supported-locales"></a>
## 支持的语言

|区域语言|受众|文案风格|
| --- | --- | --- |
|`en`|全球英语用户|采用 Apple 风格的清晰行动文案：先说明结果，使用熟悉的词，只在有助于下一步操作时介绍实现细节。|
|`ko`|韩国|采用 Toss 风格的通俗表达：一次传达一个信息，去掉赘词，先说好处再说实现。|
|`ja`|日本|采用 LINE 和 SmartHR 风格：自然对话、降低阅读负担，错误信息不责怪用户，并说明下一步操作。|
|`zh-Hans`|中国大陆|采用 Ant Design 的用户中心文案：重要信息优先，说明结果和下一步，避免命令口吻及内部术语。|
|`zh-Hant`|台湾|面向台湾，围绕任务表述，使用熟悉的 `App`／`顯示器`／`設定`／`快速鍵` 术语。|

`zh-Hant` 当前面向台湾用语，不混入香港词汇。将来支持香港时，单独添加 `zh-HK`。

<a id="tatami-voice"></a>
## Tatami 的表达方式

- 先说明结果，例如：“把这个工作区放到当前工作区旁边。”
- 一句话只表达一个意思，前提条件另起一句。
- 说用户操作的对象，不说 Tatami 的内部子系统。
- 按钮直接使用动作，如“应用设置”“打开系统设置”。
- 在用户确认前，说明破坏性操作的结果。
- 不要用委婉措辞掩盖错误。说明哪里失败，以及用户接下来可以做什么。
- 保留路径、命令、键盘符号、应用名称，以及用户输入的工作区和配置方案名称。

<a id="core-terminology"></a>
## 核心术语

|概念|`en`|`ko`|`ja`|`zh-Hans`|`zh-Hant`|
| --- | --- | --- | --- | --- | --- |
|工作区|Workspace|작업 공간|ワークスペース|工作区|工作空間|
|工作区链|Workspace Chain|작업 공간 체인|ワークスペースチェーン|工作区链|工作空間鏈|
|配置方案|Profile|프로필|プロファイル|配置方案|設定組合|
|共享应用|Shared Apps|공용 앱|共有アプリ|共享应用|共用 App|
|借用|Borrow|빌려오기|借りる|借用|借用|
|暂存区|Scratchpad|임시 공간|一時スペース|暂存区|暫存區|
|平铺|Tiling / Tiled|타일링|タイル表示|平铺|並排|
|置顶|Always on Top|항상 위|常に手前|置顶|置頂|
|保持原样 / 忽略|Leave As Is|그대로 두기|そのまま|保持原样|維持原狀|
|焦点|Focus|포커스|フォーカス|焦点|焦點|
|窗口切换|Window Switching|창 전환|ウインドウ切り替え|窗口切换|視窗切換|
|操作反馈|On-Screen Feedback|화면 알림|操作フィードバック|操作反馈|操作回饋|

一致使用这些术语。可以为自然表达重写整句，但不能悄悄改变功能含义。

韩语中只保留产品名 `Tatami` 为英文。功能使用易懂的韩语：작업 공간、프로필、공용 앱、빌려오기、임시 공간、항상 위。优先使用表示结果的 `항상 위에 두기`，避免技术音译 `플로팅`。

<a id="english-voice"></a>
### 英语文案

- 遵循 Apple 写作原则：清晰、简洁、实用、行动明确，先讲结果或好处，再讲步骤。
- 使用用户可见的对象和动作 `Always on Top`、`Window Switching`、`On-Screen Feedback`，代替内部术语 `Floating`、`Cycle`、`HUD`、`Overlay`。
- 按钮和菜单命令以动词开头，设置标签说明启用后会发生什么。
- 空状态说明缺少什么，并在有帮助时提供一个下一步操作。错误说明失败内容、仍然安全的部分和恢复方法。
- 只在检查或配置实现本身的地方显示 `BSP`、`TOML` 和文件名。

<a id="korean-voice"></a>
### 韩语文案

- 标题、空状态、说明、确认和错误使用韩语 해요 体。按钮、选项和区块标题用简短动作或名词，便于扫描。
- 描述用户的动作，而非系统状态：把 `선택된 항목 없음` 改为 `선택한 항목이 없어요`，把 `추가됨` 改为 `추가했어요`。
- 问题后说明可行的下一步，不在正文中重复标题。
- 优先日常结果而非实现术语，用 `화면 알림` 代替 `HUD` 或 `오버레이`，但保留必要的 `BSP`、`TOML` 和键名。
- 不要在用户输入的名字后直接附加会变化的韩语助词。把 `“%@”을 삭제할까요?` 改写为 `삭제할까요? · “%@”`。

<a id="japanese-voice"></a>
### 日语文案

- 使用熟悉的口语，避免过多客套。说明使用完整的 `です／ます` 句式，按钮和菜单使用简短动作。
- 优先使用 `借りる`、`常に手前`、`タイル表示`、`一時スペース`、`作業環境`，避免生硬直译或未经解释的外来语。
- 空状态使用 `項目が選択されていません` 这样的完整陈述，错误说明问题和下一步，不责怪用户。

<a id="simplified-chinese-voice"></a>
### 简体中文文案

- 先说结果，再说操作。措辞简短完整，失败时明确下一步。
- 一致使用 `应用`、`场景`、`借用`、`置顶`、`窗口切换`、`操作反馈`，不要在大陆界面文案中混用英文 `App`。
- 标签不加多余标点，完整句子和多步骤说明使用适当标点。

<a id="traditional-chinese-voice"></a>
### 繁体中文文案

- 面向台湾用语，使用 `App`、`工作空間`、`設定組合`、`顯示器`、`快速鍵`、`借用`、`置頂`、`視窗切換`、`操作回饋`。
- 优先描述任务和可见结果，而非逐字翻译技术术语。在 macOS 场景中使用熟悉的 `點按`、`檔案`、`游標`、`螢幕`。
- 不要在 `zh-Hant` 中混入香港特有词汇，需要时单独添加 `zh-HK`。

<a id="implementation-rules"></a>
## 实现规则

- 应用和 `TatamiKit` 的界面字符串放在 `Tatami/Resources/Localizable.xcstrings`。`TatamiKit` 是静态框架，因此运行时目录由 Tatami 主应用包持有。
- 保持提取的英语源键稳定，把审核后的英语显示文本存为明确的 `en` 本地化值，避免每次优化文案都重命名 Swift 查询键。
- 模型、辅助代码和视图间传递固定文案使用 `LocalizedStringResource`；用户输入的名称和发现的应用、显示器名称保留为 `String`。
- 把字符串字面量直接传给 SwiftUI 控件。
- 只在 SwiftUI 初始化器之外需要具体 `String` 时使用 `String(localized:)`。
- 插值完整句子，不拼接已翻译的碎片。
- 保留格式占位符，允许各语言调整顺序。
- 用户可见的数字和日期使用支持区域语言的 `FormatStyle`。
- 不要在运行时把本地化文案转换为大写。
- 界面文案不用 em dash，拆成句子或使用符合语言习惯的标点。

<a id="documentation-website-and-demo-films"></a>
## 文档、网站与演示视频

应用之外也遵循相同术语和写作规则。

- 以英语文档为源，从 `Localization/Docs.json` 生成各语言 README 和指南，保留命令、代码示例、标识符、链接目标及明确的标题锚点。
- `Localization/Web.json` 保存完整网站文本单元。每种语言有独立 URL 和文档语言，覆盖导航、无障碍标签、加载与错误状态、文档和视频集控件。
- Demo Lab 使用独立的 `DemoLab/Localization/Localizable.xcstrings` 目录，各演示应用都在主包中包含它。共享辅助代码传递 `LocalizedStringResource`，保存的演示内容按本次录制语言解析完整字符串。
- 字幕、标题和人工输入共用 `DemoLab/Localization/Films.json`，从相同值生成输入断言。翻译后的标签可能相同，因此优先使用稳定的无障碍标识符。
- 按每种应用语言录制并验证。英语界面加翻译字幕，不能证明实际测试了本地化应用。
- 在构建时拒绝缺失翻译或被改变的占位符，不通过静默回退英语让构建通过。
- 历史版本说明和许可证、版权文本保留原文。翻译导航与解释，并明确链接到权威原文。

<a id="review-checklist"></a>
## 检查清单

1. 使用 `SWIFT_EMIT_LOC_STRINGS=YES` 构建，再把编译器生成的 `.stringsdata` 同步到目录。
2. 确认每个可翻译键都有所有支持语言的翻译。
3. 确认每条翻译保留源文占位符集合。
4. 通过 scheme 的 Application Language 覆盖设置，分别启动各语言。
5. 检查设置、菜单栏、破坏性确认、空状态和所有设置向导步骤，确认没有截断或混合语言。
6. 发布前请母语审阅者检查语气和术语。根据屏幕上下文编写目录，不以机器翻译填充。

<a id="public-references"></a>
## 公开参考资料

- Toss：<https://toss.tech/article/21022>
- Apple 人机界面指南：写作：<https://developer.apple.com/design/human-interface-guidelines/writing>
- Apple WWDC25：用小幅文案改动带来大影响：<https://developer.apple.com/videos/play/wwdc2025/404/>
- LINE Voice：<https://designsystem.line.me/about/line-voice-ja>
- SmartHR 写作风格：<https://smarthr.design/products/contents/writing-style/>
- SmartHR 界面文案：<https://smarthr.design/products/contents/ui-text/app-writing/>
- SmartHR 错误信息：<https://smarthr.design/products/contents/error-messages/overview/>
- Ant Design 文案：<https://ant.design/docs/spec/copywriting-cn/>
- 台湾政府网站内容指南：<https://www.webguide.nat.gov.tw/guidelines/442/show>
