# WIP: Borrow / Composition feature

`/compact` 후 이 파일을 Read해서 이어가기 위한 상태 문서. 작업 브랜치 `feature/borrow-composition`.

## 목표 & 철학 (locked)
다른 워크스페이스를 현재 화면 가장자리(상/하/좌/우)에 **빌려와** 나란히 타일.
- **2레벨 경계**: host/borrowed 각자 자기 BSP 트리 유지. 최상위는 `[host 블록 | borrowed 블록]` 분할. **창은 워크스페이스 경계 못 넘음**(directional op이 단일 트리라 자동 차단).
- **라이브 양방향**: borrowed 블록 = 그 워크스페이스의 실제 트리(`tilingTrees[borrowedId]`). 조작이 본진에 반영(세션은 공유 트리, 디스크는 persist).
- **모드 2개**: `.peek`(전환 시 해제) / `.combine`(명시 해제까지 + host 재활성 시 재현).
- **scratchpad kind**: 빌리기 전용(사이클/단독 활성 제외). 일반 워크스페이스도 빌림 가능.

핵심 통찰: 2레벨 트리 **literal 병합 금지**. host/borrowed 두 `BSPNode`를 별도 유지 → 각자 sub-rect에 `frames(in:)` → merge → 한 번 apply. 경계 금지가 공짜.

## 브랜치 & 커밋 (최신순)
- `feature/borrow-composition` (main 1.4.2와 분리)
- `76a03d4` keyEquivalent + nvim-style borrow chord
- `8d5e9fe` recent-borrow 핫키(4방향) + boundary resize
- `54218a9` M4 HUD + 워크스페이스 목록 affordance
- `1b19730` M3 scratchpad kind
- `f0021d8` M3 combine 영속
- `1e5f8ee` M2 sync/prune/drag/mru 라우팅
- `8298d96` M2 BSP op 라우팅
- `4cf16e8` M1

## 완료 (M1~M4 + 핫키/chord) — 전부 빌드 OK
- **Domain** (`Workspace.swift`): `WorkspaceKind{normal,scratchpad}`, `BorrowEdge`, `BorrowMode{peek,combine}`, `BorrowedSlot{workspace,edge,fraction,mode}`, `Composition{host,borrowed}`. `Workspace.kind`, `Workspace.keyEquivalent`(단일 문자, Codable 마이그레이션).
- **State** (`WorkspaceActivationFeature.swift`): `compositionsByDisplay`, `combineBorrows`, `borrowCaptureEdge`. resolver `composedOwner(bundleId:key:)` / `workspaceOwning(_:)` / `focusedWorkspaceID` — composition 없으면 `primaryActiveWorkspaceID` fallback.
- **Tiling** (`+Activate.swift`): `computeFrames(targetRect:)`, `static subRects`, `applyComposition(display:state:)`(`CancelID.applyComposition`), `tilingContext(for:state:)`, `performBorrow`, `dismissBorrow`, `resizeBorrow`. `flushLayout(workspaceId:state:)`(composition-aware flush, `WorkspaceActivationFeature.swift`).
- **M2 라우팅**: bspFocus/cycle/applyBSPOp(+`.balance` 통합, `applyTreeTransform` 제거)/drag(syncTreeRatio·dropDecision·applyDrop)/sync/prune/reflow/retile 전부 owning 블록으로. sync는 `composedOwner`로 owning ws 결정, borrowed write-through. prune은 host+borrowed 두 트리. empty 처리: host→`switchToRecentIfEmpty`, borrowed→`collapseIfBorrowedEmpty`(dismiss). 모든 flush가 `flushLayout` 경유.
- **M3 combine**: `performActivate`가 display 재타일 시 `compositionsByDisplay[display]=nil`(peek blur). `activationCompleted`에서 `combineBorrows[id]` 있으면 `.borrow(.combine)` 재발행.
- **M3 scratchpad**: `adjacentWorkspaceId`/`activateInitial`에서 제외, `performActivate`에서 scratchpad 단독 활성→`performBorrow(.peek,.right)` redirect. WorkspaceDetail Kind picker.
- **M4 UI**: borrow/dismiss HUD(`settings.hud.borrow` 카테고리+토글, edge 아이콘). 워크스페이스 목록 scratchpad/borrowed 뱃지 + "Borrow Here" 컨텍스트 메뉴.
- **핫키 (one-shot)**: `borrowRecent{Left,Right,Up,Down}`, `borrowGrow`/`borrowShrink`(resizeBorrow ±0.05), `dismissBorrow`. HotKeyAction/Shortcuts/AppConfig/AppFeature/SettingsView 전부 와이어.
- **chord (nvim식)**: `enterBorrowMode` 리더 핫키 → `borrowCaptureEdge=.right` + `BorrowChordClient.setArmed(true, initials)` + 5s 타임아웃 + HUD 힌트. `BorrowChordClient`(신규 파일, `EventTapThread` 위 keyDown CGEventTap, `MirrorClickTap` 패턴) → `.borrowChordKey(BorrowChordKey)`. h/j/k/l·화살표=edge, 워크스페이스 keyEquivalent=소환, backtick=recent, esc/그외=취소. ⌘/⌃/⌥ 동반 키는 pass-through+취소. `events()` 구독은 `startObservingWindowEvents` merge에 상주.
- **keyEquivalent 활성화**: `settings.shortcuts.keyEquivalentModifiers`([String] skhd 토큰, default `["ctrl","alt"]`). `hotKeyBindings`가 explicit `activateShortcut` 없고 모디파이어 비어있지 않으면 `modifier+keyEquivalent → activateWorkspace` 합성. `HotKey.keyCode(forName:)`/`keyName(for:)`/`carbonModifiers(from:)` 헬퍼 추가.
- **GUI**: WorkspaceDetail "Key equivalent" 필드(소문자 1자) + Kind picker. Settings→Shortcuts "Switch modifier" 토글(⌃⌥⇧⌘ button toggle) + "Borrow mode" recorder row + recent/resize/dismiss rows.

## 주의 / 알려진 한계
- **Tuist**: 신규 .swift 추가 시 `tuist generate --no-open` 필요(glob `**`). 이미 `BorrowChordClient.swift` 추가 후 generate 완료. `Project.swift` `appVersion`(현재 1.4.2)이 버전 단일 소스.
- **swiftformat 깨짐**: repo `.swiftformat`의 `--type-blank-lines consistent`가 설치된 0.61.1에서 미지원 → lint 실패. 내 코드 문제 아님. 수동 스타일 유지 중. (원하면 `.swiftformat`에서 그 줄을 `preserve`로 고치는 것도 별도 작업.)
- **combine 재현 flash**: combine host 재활성 시 host 단독 타일 → borrow 재발행이라 한 번 깜빡임(이중 activate). 허용. #18에서 개선 가능(performActivate를 combine-aware로).
- **borrowed marker dot 미구현**: M4에서 의도적 보류(공간 분할로 충분). #18 후보.
- **per-workspace borrowShortcut**: keyEquivalent+borrow mode로 대체됨(별도 HotKey 안 만듦).

## 남은 작업
### #18 엣지 케이스
- 멀티 디스플레이(borrowed `displayHint` 무시 — 현재 focusedDisplay 기준), fullscreen-zoom 블록 내, floating/unmanaged 미러 스코프(composition 시 borrowed floating 위치), target==host 가드(있음), combine flash 개선, borrowed marker dot(옵션).
- borrow 중 다른 display 활성/디스플레이 분리 시 composition 정리 검증.
### #19 문서 + 1.5.0 릴리즈
- `docs/CONFIGURATION.md`(kind/keyEquivalent/keyEquivalentModifiers/borrow 핫키/borrow mode), `CHANGELOG.md` 1.5.0(기존 Breaking 포맷 맞춰), `WhatsNewClient.swift`, `README.md`. `Project.swift` `appVersion` → 1.5.0, `v1.5.0` 태그 push(release CI가 태그=appVersion 검증).
- main 머지 전략: feature 브랜치 → main PR or fast-forward.

## 빌드 / 테스트
- 로직: `xcodebuild -workspace Tatami.xcworkspace -scheme TatamiKit -destination 'platform=macOS' build`
- 전체: `-scheme Tatami`
- 실행: `killall Tatami; open ~/Library/Developer/Xcode/DerivedData/Tatami-abzoohblcyzqwbfbfgakdjqklexa/Build/Products/Debug/Tatami.app`
- 테스트 절차: 워크스페이스 2개에 keyEquivalent 지정(예: a, d) → Settings→Shortcuts에서 "Borrow mode"에 핫키(예 ⌥;), "Switch modifier" ⌃⌥ 확인 → ⌃⌥+a/d 전환 동작 확인 → Borrow mode 핫키 후 `l`(우) 그다음 `d` → d가 우측에 나란히. backtick=recent. esc 취소. dismiss 핫키/토글 복원.
- 디버그 로그: Settings→Debug ON → `~/.config/tatami/tatami.log` (`[Borrow]`/`[BorrowChord]`/`[BSP]`/`[Sync]`/`[Prune]`).
