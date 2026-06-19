# WIP: Borrow / Composition feature

`/compact` 후 이 파일을 Read해서 이어가기 위한 상태 문서. 작업 브랜치 `feature/borrow-composition` (main 1.4.2와 분리, clean).

> 이 문서는 여러 차례의 재설계(chord → **mode-less borrow**, keyEquivalent, recorder 모니터, Settings IA 리팩토링)를 모두 반영한 최신본이다.

## 목표 & 철학 (locked)
다른 워크스페이스를 현재 화면 가장자리(상/하/좌/우)에 **빌려와(borrow)** 나란히 타일.
- **2레벨 경계**: host/borrowed 각자 자기 BSP 트리 유지. 최상위 `[host 블록 | borrowed 블록]` 분할. 창은 워크스페이스 경계 못 넘음(단일 트리라 directional op 자동 차단).
- **라이브 양방향**: borrowed 블록 = 그 워크스페이스의 실제 트리(`tilingTrees[borrowedId]`). 세션은 공유 트리, 디스크는 persist.
- **핵심 통찰**: 2레벨 트리 literal 병합 금지. 두 `BSPNode`를 별도 유지 → 각자 sub-rect에 `frames(in:)` → merge → 한 번 apply.

## 단축키 모델 (전체의 중심)
**워크스페이스(또는 nav 타겟)마다 키 하나 + 액션마다 전역 모디파이어.**
- `keyEquivalentModifiers`(switch, 기본 ⌃⌥) + 키 → 활성
- `assignModifiers`(기본 ⌃⌥⇧) + 키 → 포커스 앱 assign + 이동
- `borrowModifiers`(기본 ⌃⌥⌘) + 키 → borrow (이후 방향)
- 각 액션은 명시 HotKey로 **override** 가능. `hotKeyBindings`(AppConfig+HotKeys.swift)가 "override 있으면 그것, 없으면 modifier+key" 합성.
- 충돌 검사: 키 입력 시 **세 조합(switch/assign/borrow) 전부** 기존 바인딩과 교차 검증(`keyEquivalentConflict`). override는 자기 액션 제외.

## Mode-less borrow 흐름
`borrowModifiers+키`(또는 `Workspace.borrowShortcut`) → `beginBorrowDirection(workspaceId)`:
- **기본 edge 있으면**(`workspace.borrowEdge ?? settings.switching.borrowDefaultEdge`) → 즉시 `performBorrow(.peek)`.
- 없으면 → `BorrowChordClient.setArmed(true)`(direction-only CGEventTap) + HUD 힌트 + 5s 타임아웃. h/j/k/l/화살표 → `performBorrow(target, edge, .peek)`; esc/그외/타임아웃 → 취소 + `workspaceHUD.dismiss()`.
- **재-borrow(이미 borrow된 타겟)** → dismiss 아니라 **edge 재도킹**(`performBorrow` 내부).
- **현재(host) 워크스페이스 borrow 차단** + "Already here" HUD.
- borrow는 **tiled 앱만** 참여(float/unmanaged 무시). **scratchpad는 모든 앱 auto-open 강제**(manager가 `request.borrowedApps` autoOpen 처리).
- borrow 크기 = `workspace.borrowFraction ?? settings.switching.borrowFraction`(기본 0.4).

## Focus
- **directional focus(←↓↑→)가 host↔borrowed 경계 넘음**(`crossBlockFocus`, sibling 블록 최근접 창). bspFocusResolved의 no-neighbor 분기에서 호출.
- **borrow된 워크스페이스 키로 활성 = 진짜 전환**(composition 드롭). focus-into-borrowed 가드는 제거됨(전환을 가로채던 버그). focus만 옮기는 건 directional focus 담당.

## 완료 (전부 빌드 OK, 사용자 실사용 테스트 완료)
- **Domain/Workspace.swift**: `kind`, `keyEquivalent`, `borrowShortcut`, `borrowEdge`, `borrowFraction` + Codable. `BorrowEdge(.opposite)`, `BorrowMode`, `BorrowedSlot`, `Composition`.
- **Domain/AppSettings.swift**: `Shortcuts`에 keyEquivalentModifiers/assignModifiers/borrowModifiers, {recent,next,previous}WorkspaceKey, switchTo/assign/borrow {Recent,Next,Previous}Workspace(override), dismissBorrow. `Switching`에 borrowDefaultEdge/borrowFraction. `HUD.borrow` 카테고리. `Shortcuts` 커스텀 init/CodingKeys/decode 주의(필드 추가 시 4곳 갱신).
- **Domain/HotKey.swift**: `keyName(for:)`, `keyCode(forName:)`, `carbonModifiers(from:)`, `modifierSymbols(from:)`, `keySymbol(forName:)`(글리프).
- **WorkspaceActivationFeature**(+Activate/+Sync/.swift): composition state(`compositionsByDisplay`, `combineBorrows`, `borrowCaptureTarget`), resolver(`composedOwner`/`workspaceOwning`), `applyComposition`/`flushLayout`/`tilingContext`/`performBorrow`(재도킹·tiled-only)/`dismissBorrow`(nil→focusedDisplay)/`beginBorrowDirection`/`crossBlockFocus`/`recentWorkspaceId`. sync/prune/drag/BSP-op 전부 owning 블록 라우팅. recent/next/prev assign·borrow 액션 + 핸들러.
- **Dependencies/BorrowChordClient.swift**: direction-only keyDown CGEventTap(EventTapThread), `events()`/`setArmed(Bool)`. BorrowChordKey{edge, cancel}.
- **Dependencies/WorkspaceHUDClient.swift**: `dismiss()` 추가.
- **Dependencies/WorkspaceManagerClient.swift**: borrowedApps auto-open(`autoOpenIfNeeded`), keepVisible union.
- **HotKeysClient/AppConfig+HotKeys/AppFeature**: HotKeyAction(activate/assign/borrowWorkspace(id) + nav assign/borrow + dismissBorrow), 합성/라우팅.
- **GUI**:
  - `Tatami/Sources/Settings/ShortcutRecorder.swift`: `KeyEquivalentRecorder`(단일 bare 키), `RecorderField`(full combo) — **둘 다 로컬 NSEvent keyDown 모니터**로 캡처(특수키 안정), `ComboCapsule`(읽기전용 파생 조합).
  - `Settings/SettingsView.swift`/`SettingsView+Panes.swift`: **Shortcuts pane 제거**. pane 순서 General→Tiling→Workspaces→Focus&Mouse→Appearance. 단축키 분산(Tiling: Move&Resize·Toggles / Focus&Mouse: Directional Focus·Window Cycling / Workspaces: Workspace Keys(modifierToggleRow+navTarget)·Borrow(기본 dir/size+dismiss)·Move App & Displays). 헬퍼: `shortcut`, `navTarget`/`navDerivedRow`, `modifierToggleRow`/`modifierToggle`, `keyEquivalentConflict`.
  - `WorkspaceDetail/WorkspaceDetailView.swift` + `WorkspaceDetailFeature.swift`: Key equivalent(키만) + Kind picker(상단), Shortcuts(Activate/Assign/Borrow `derivedShortcutRow` + override), Borrow Placement(edge/fraction override, "Use Global (값)"), scratchpad는 무의미 옵션 숨김(Activate/Assign/On-Activation/Display + 앱별 layout/auto-open). Add App 빈 상태 버그 수정(List+overlay).
  - `WorkspaceList/WorkspaceListView.swift`: scratchpad/borrowed 뱃지 + "Borrow Here" 컨텍스트 메뉴.

## 남은 작업
### #18 엣지 케이스 (완료)
- 해소: float/unmanaged 무시, target==host 차단, 재도킹, cross-block focus, 외부 핫키 충돌(코드 이슈 아님).
- **combine 데드코드 제거 완료**(`34704f0`): `.peek`만 쓰이고 `combineBorrows`는 채워지지도 않던 죽은 영속 골격 → `BorrowMode`/`BorrowedSlot.mode`/`combineBorrows`/activationCompleted 재establish/mode 인자 전부 삭제. borrow는 항상 transient. dismissBorrow는 유지(실사용).
- **fullscreen-zoom × composition 검증 → 버그 없음**: zoom은 `flushLayout`→`applyComposition` 경유로 처리되고 `computeFrames(targetRect:)`가 zoom 창을 블록 sub-rect에 가둠.
- **borrow marker 완료**(`f2958d4`): 빌려온 블록의 각 창에 빌려온 워크스페이스 아이콘 배지(MarkerTarget.symbol). `borrowMarkerTargets()`가 모든 composition 수집→모든 마커 push 경로에 머지, flushComposition에서 재푸시. 설정 `marker.borrowEnabled/borrowColorHex`(Appearance). 심볼 마커는 dot의 2배 크기.
- 멀티 디스플레이: borrow는 focusedDisplay 기준, 마커는 전 디스플레이 composition 수집으로 처리됨.
### 메뉴바 정리 (완료)
- scratchpad 전용 "Scratchpads" 섹션 분리(`4a90146`), Pause Tiling 제거(`be1219e`, 핫키 `toggleSpaceActivated`로 접근).
### #19 문서 + 1.5.0 릴리즈 (다음)
- `docs/CONFIGURATION.md`(kind/keyEquivalent/3 modifiers/nav keys/borrow defaults/scratchpad), `CHANGELOG.md` 1.5.0(기존 Breaking 포맷), `WhatsNewClient.swift`, `README.md`. `Project.swift` `appVersion` → 1.5.0, `v1.5.0` 태그 push(release CI가 태그=appVersion 검증). **태그 push는 outward/destructive → 사용자 확인 후.**

## 주의 / 함정
- **Tuist**: 신규 .swift는 `tuist generate --no-open` 필요(glob `**`). `BorrowChordClient.swift` 추가 시 이미 generate함. 버전 단일 소스 = `Project.swift` `appVersion`.
- **테스트 스킴 이름**: `TatamiTests` 아님 — 실제 스킴 확인 필요(`xcodebuild -workspace Tatami.xcworkspace -list`).
- **swiftformat 깨짐**: `.swiftformat`의 `--type-blank-lines consistent`가 설치된 0.61.1 미지원 → lint 실패. 수동 스타일 유지.
- **debugLog는 앱 타깃에서 internal**(접근 불가) — 레코더 등 앱 타깃 진단은 reducer 경유 로그로.
- 모디파이어 토큰은 `"cmd"`(not `"command"`) — modifierToggle과 round-trip.

## 빌드 / 실행
- 로직: `xcodebuild -workspace Tatami.xcworkspace -scheme TatamiKit -destination 'platform=macOS' build`
- 전체: `-scheme Tatami`
- 실행: `killall Tatami; open ~/Library/Developer/Xcode/DerivedData/Tatami-abzoohblcyzqwbfbfgakdjqklexa/Build/Products/Debug/Tatami.app`
- 디버그 로그: Settings → General → Debug ON → `~/.config/tatami/tatami.log` (`[Borrow]`/`[BorrowChord]`/`[HotKey]`/`[BSP]`/`[Sync]`/`[Prune]`).
