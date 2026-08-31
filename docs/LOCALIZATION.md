# Tatami Localization and UX Writing

Tatami keeps one product model across languages, but it does not translate
English word for word. Each locale should make the next action obvious while
preserving the app's core concepts: a workspace is a task context, a profile is
a group of workspaces for a setup, and Borrow temporarily places one workspace
beside another.

## Supported locales

| Locale | Audience | Writing model |
| --- | --- | --- |
| `en` | Global English | Apple-style clear, action-oriented writing: lead with the outcome, prefer familiar words, and reveal implementation detail only when it helps the next action |
| `ko` | Korea | Toss-style plain language: one message at a time, remove filler, explain the benefit before implementation details |
| `ja` | Japan | LINE and SmartHR-style clarity: use conversational Japanese, reduce reading effort, and make errors explain the next action without blaming the user |
| `zh-Hans` | Mainland China | Ant Design-style user-centered copy: put important information first, state the result and next action, and avoid commands or internal terminology |
| `zh-Hant` | Taiwan | Taiwan-centered, task-oriented writing with familiar `App`/`顯示器`/`設定`/`快速鍵` terminology |

`zh-Hant` currently targets Taiwan usage. Do not mix Hong Kong vocabulary into
this locale. Add `zh-HK` separately if Tatami supports Hong Kong later.

## Tatami voice

- Lead with the outcome: “Bring this workspace beside the current one.”
- Use one idea per sentence. Put prerequisites in a separate sentence.
- Name the user's object, not Tatami's internal subsystem.
- Use direct actions for buttons: “Apply Setup”, “Open System Settings”.
- Explain destructive results before the user confirms them.
- Do not hide an error behind a friendly euphemism. Say what failed and what
  the user can do next.
- Keep paths, commands, keyboard glyphs, app names, and user-entered workspace
  or profile names unchanged.

## Core terminology

| Concept | `en` | `ko` | `ja` | `zh-Hans` | `zh-Hant` |
| --- | --- | --- | --- | --- | --- |
| Workspace | Workspace | 작업 공간 | ワークスペース | 工作区 | 工作空間 |
| Profile | Profile | 프로필 | プロファイル | 配置方案 | 設定組合 |
| Shared Apps | Shared Apps | 공용 앱 | 共有アプリ | 共享应用 | 共用 App |
| Borrow | Borrow | 빌려오기 | 借りる | 借用 | 借用 |
| Scratchpad | Scratchpad | 임시 공간 | 一時スペース | 暂存区 | 暫存區 |
| Tiling | Tiling / Tiled | 타일링 | タイル表示 | 平铺 | 並排 |
| Always on top | Always on Top | 항상 위 | 常に手前 | 置顶 | 置頂 |
| Left untouched / Ignore | Leave As Is | 그대로 두기 | そのまま | 保持原样 | 維持原狀 |
| Focus | Focus | 포커스 | フォーカス | 焦点 | 焦點 |
| Window switching | Window Switching | 창 전환 | ウインドウ切り替え | 窗口切换 | 視窗切換 |
| On-screen feedback | On-Screen Feedback | 화면 알림 | 操作フィードバック | 操作反馈 | 操作回饋 |

Use these terms consistently. A locale may rewrite an entire sentence around
the term; it must not silently change the underlying behavior.

In Korean, keep only the product name `Tatami` in English. Write functional
concepts in immediately understandable Korean: 작업 공간, 프로필, 공용 앱,
빌려오기, 임시 공간, and 항상 위. Prefer an outcome such as `항상 위에 두기`
over a technical transliteration such as `플로팅`.

### English voice

- Follow Apple writing guidance: make copy clear, concise, useful, and
  action-oriented. Put the result or benefit before instructions.
- Prefer the user's visible object and action: `Always on Top`, `Window
  Switching`, and `On-Screen Feedback` replace internal terms such as
  `Floating`, `Cycle`, `HUD`, and `Overlay`.
- Buttons and menu commands start with a verb. Settings labels describe what
  happens when the setting is on.
- Empty states name what is missing and, when useful, follow with one next
  action. Errors say what failed, what remains safe, and how to recover.
- Keep `BSP`, `TOML`, and file names only where the implementation itself is
  being inspected or configured.

### Korean voice

- Use 해요체 for titles, empty states, descriptions, confirmations, and
  errors. Keep buttons, picker values, and section headings as short action or
  noun labels when a full sentence would slow scanning.
- Describe the user's action, not a system state: `선택된 항목 없음` becomes
  `선택한 항목이 없어요`, and `추가됨` becomes `추가했어요`.
- Follow a problem with the next useful action when one exists. Do not repeat
  the title in the body.
- Prefer everyday outcomes over implementation terms: use `화면 알림` instead
  of `HUD` or `오버레이`, but keep necessary domain terms such as `BSP`,
  `TOML`, and keyboard key names.
- Never attach a variable Korean postposition to a user-entered name. Rewrite
  `“%@”을 삭제할까요?` as `삭제할까요? · “%@”`.

### Japanese voice

- Use familiar spoken Japanese without overusing polite filler. Descriptions
  use complete `です／ます` sentences; buttons and menu commands use short
  actions.
- Prefer `借りる`, `常に手前`, `タイル表示`, `一時スペース`, and
  `作業環境` over stiff translations or unexplained loanwords.
- Empty states are complete statements such as `項目が選択されていません`.
  Errors explain the problem and the next useful action without blaming the
  user.

### Simplified Chinese voice

- Put the outcome before the operation. Use short, complete wording and make
  the next action explicit when something fails.
- Use `应用`, `场景`, `借用`, `置顶`, `窗口切换`, and `操作反馈`
  consistently. Do not mix English `App` into Mainland Chinese UI copy.
- Keep labels free of unnecessary punctuation. Use punctuation for complete
  sentences and multi-step guidance.

### Traditional Chinese voice

- Target Taiwan usage. Use `App`, `工作空間`, `設定組合`, `顯示器`,
  `快速鍵`, `借用`, `置頂`, `視窗切換`, and `操作回饋`.
- Prefer task language and visible outcomes over literal technical
  translations. Use `點按`, `檔案`, `游標`, and `螢幕` in their familiar
  macOS contexts.
- Keep Hong Kong-specific vocabulary out of `zh-Hant`; add `zh-HK` as a
  separate locale if needed.

## Implementation rules

- Put app and `TatamiKit` UI strings in
  `Tatami/Resources/Localizable.xcstrings`. `TatamiKit` is a static framework,
  so Tatami intentionally owns the runtime catalog in the main app bundle.
- Keep extracted English source keys stable. Store reviewed displayed English
  as explicit `en` localizations in the catalog, so UX copy can improve without
  renaming every Swift lookup key.
- Use `LocalizedStringResource` for fixed UI copy passed between models,
  helpers, and views. Keep user-entered names and discovered app/display names
  as `String`.
- Pass string literals directly to SwiftUI controls.
- Use `String(localized:)` only when a concrete `String` is required outside a
  SwiftUI initializer.
- Interpolate a complete sentence. Never concatenate translated fragments.
- Preserve format placeholders and let each locale reorder them.
- Use locale-aware `FormatStyle` for user-visible numbers and dates.
- Do not uppercase localized copy at runtime.
- Do not use em dashes in interface copy. Split the thought into sentences or
  use punctuation that fits the locale.

## Review checklist

1. Build with `SWIFT_EMIT_LOC_STRINGS=YES`, then sync compiler-generated
   `.stringsdata` into the catalog.
2. Verify every supported locale has a translation for every translatable key.
3. Verify each translation preserves the source placeholder set.
4. Launch once per locale with the scheme's Application Language override.
5. Check Settings, menu bar, destructive confirmations, empty states, and all
   Guided Setup steps for clipping and mixed-language text.
6. Have a native reviewer check tone and terminology before release. Tatami's
   catalog is written from screen context; do not seed it with machine
   translation.

## Public references

- Toss: <https://toss.tech/article/21022>
- Apple Human Interface Guidelines: Writing:
  <https://developer.apple.com/design/human-interface-guidelines/writing>
- Apple WWDC25: Make a big impact with small writing changes:
  <https://developer.apple.com/videos/play/wwdc2025/404/>
- LINE Voice: <https://designsystem.line.me/about/line-voice-ja>
- SmartHR writing style:
  <https://smarthr.design/products/contents/writing-style/>
- SmartHR UI text:
  <https://smarthr.design/products/contents/ui-text/app-writing/>
- SmartHR error messages:
  <https://smarthr.design/products/contents/error-messages/overview/>
- Ant Design copywriting:
  <https://ant.design/docs/spec/copywriting-cn/>
- Taiwan government web content guidelines:
  <https://www.webguide.nat.gov.tw/guidelines/442/show>
