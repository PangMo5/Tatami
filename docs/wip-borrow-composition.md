# WIP: Borrow / Composition feature

상태 문서 — `/compact` 후 이 파일을 Read해서 이어가기 위한 것. 작업 브랜치 `feature/borrow-composition`.

## 목표 & 철학 (locked)
다른 워크스페이스를 현재 화면 가장자리(상/하/좌/우)에 **빌려와** 나란히 타일.
- **2레벨 경계**: 두 워크스페이스가 각자 자기 BSP 트리를 유지. 최상위는 `[host 블록 | borrowed 블록]` 분할(위치/orientation/비율 조정 가능). **창은 워크스페이스 경계를 못 넘음**(directional swap/move가 단일 트리라 자동 차단).
- **라이브 양방향**: borrowed 블록 = 그 워크스페이스의 실제 트리(`tilingTrees[borrowedId]`). 빌린 상태 조작(창 이동/새 창)이 **본진에 반영**.
- **모드 2개**: `.peek`(fire-and-forget, 토글/blur 해제) / `.combine`(persistent, 명시 해제까지 + re-activation 재현).
- **scratchpad kind**: 빌리기 전용 워크스페이스(사이클/단독 활성 제외). 일반 워크스페이스도 빌림 가능.
- **UI 표식**: 두 모드 공통, borrowed 영역/윈도우 + 출처 워크스페이스 표시.

핵심 통찰: 2레벨 트리를 **literal 병합하지 말 것**. host/borrowed 두 `BSPNode`를 별도 유지 → 각자 sub-rect에 `frames(in:)` → `[WindowKey: CGRect]` merge → 한 번 apply. 경계 금지가 공짜(directionalNeighbor/swapping이 단일 트리).

## 브랜치 & 커밋
- `feature/borrow-composition` (main 1.4.2와 분리)
- `4cf16e8` M1, `ed179f2` M2 focus/cycle 라우팅

## 완료 (M1 + M2 일부) — 전부 빌드 OK
- **Domain** (`TatamiKit/Sources/Domain/Workspace.swift`): `WorkspaceKind {normal, scratchpad}`, `BorrowEdge`, `BorrowMode {peek, combine}`, `BorrowedSlot {workspace, edge, fraction, mode}`, `Composition {host, borrowed: [BorrowedSlot]}`. `Workspace.kind` 추가 + Codable 마이그레이션.
- **State** (`WorkspaceActivationFeature.swift`): `compositionsByDisplay: [DisplayName: Composition]`, `combineBorrows: [Workspace.ID: [BorrowedSlot]]`. resolver `workspaceOwning(_ key)` / `focusedWorkspaceID(focusedKey:)` — composition 없으면 `primaryActiveWorkspaceID` fallback(기존 동작 동일).
- **Tiling** (`WorkspaceActivationFeature+Activate.swift`): `computeFrames(..., targetRect: CGRect? = nil)`, `static subRects(workArea:edge:fraction:gap:)`, `applyComposition(display:state:)` (두 트리→두 sub-rect→merge→한 apply, `CancelID.applyComposition(DisplayName)`), `tilingContext(for:state:)` (composition이면 sub-rect+focusedDisplay, else full work area), `performBorrow(targetId:edge:mode:state:)`, `dismissBorrow(display:state:)`.
- **Manager** (`WorkspaceManagerClient.swift`): `ActivationRequest.borrowedApps` + `keepVisible` union(host ∪ shared ∪ borrowed).
- **Actions** (`WorkspaceActivationFeature.swift`): `.borrow(workspaceId:edge:mode:)`, `.borrowRecent(edge:mode:)`, `.dismissBorrow(display:)`, `.flushComposition(display:)` + 핸들러.
- **Hotkeys**: `borrowRecentRight`, `dismissBorrow` — `HotKeysClient`(case/nameKey/title), `AppSettings.Shortcuts`(필드/init/CodingKeys/decode), `AppConfig+HotKeys`(register), `AppFeature` route, `SettingsView+Panes` recorder.
- **followAppFocus 억제**: `compositionsByDisplay.isEmpty` 가드를 followAppFocus jump 조건에 추가.
- **M2 라우팅 완료**: `bspFocusResolved`, `cycleWindowResolved` → `workspaceOwning(key)` + `tilingContext` + `computeFrames(targetRect:)`. composition 중 cycle은 블록 트리만(floating/unmanaged 생략).

## M2 라우팅 패턴 (남은 op에 그대로 적용)
focus-relative op마다:
1. `let workspaceId = state.workspaceOwning(key) ?? state.primaryActiveWorkspaceID`
2. `let tree = state.tilingTrees[workspaceId]`
3. `let (display, workArea) = tilingContext(for: workspaceId, state: state)`
4. op은 `tree`(단일)만 → 경계 자동 차단
5. warp/frames는 `computeFrames(..., targetRect: workArea)`
6. 트리 변경 시 `state.tilingTrees[workspaceId] = newTree` + `persist(...)`(해당 ws 기준)
7. flush: composition이면 `applyComposition(display:state:)`, else `applyLayout(...)`

## 남은 작업 (task #로 추적 중)
### M2 나머지 — #10(op 라우팅), #13, #14
- **#10**: `applyBSPOp(windowKey:op:state:)`(swap/resize/toggleOrientation/toggleZoomFullscreen — `WorkspaceActivationFeature.swift` `case .bspOpResolved` → `applyBSPOp` 함수) + `applyTreeTransform`(balance) 를 위 패턴으로. 트리 write를 `workspaceOwning` 워크스페이스에, flush를 composition-aware로.
- **#13**: `syncAppWindows`(`+Sync.swift`) 새 창을 owning 블록 트리에 라우팅 + borrowed write-through(`tilingTrees[borrowedId]` + persist). `pruneOffscreenWindows`(`+Sync.swift`) 두 트리 prune + borrowed 비면 composition collapse(dismiss). 드래그 핸들러(`+Drag.swift`) dragged 윈도우 owner 트리. `windowFocused` mru는 owner 블록(이미 `workspaceOwning`스럽게 — 확인).
- **#14**: composition 활성 중 모든 `applyLayout` 호출 → `applyComposition`. `retileActive`/`reflowActiveWorkspace`(`+Sync.swift`) composition-aware.

### M3 — #12, #15
- **#12 combine 영속**: `.combine`이면 `combineBorrows[host]` 저장(이미 performBorrow에서 함). `performActivate`(host)에서 `combineBorrows[host]` 있으면 composition 재설정 + `borrowedApps` 채워 재렌더. dismiss 정책: peek=blur(다른 ws activate 시 clear)/toggle, combine=명시만.
- **#15 scratchpad**: `adjacentWorkspaceId`(`+Activate.swift`, cycle)에서 `.scratchpad` 제외, `activateInitial` 제외, `performActivate`에서 scratchpad 단독 activate → borrow redirect. `WorkspaceDetailFeature` `kindChanged` + `WorkspaceDetailView` picker. switching-while-composed: 다른 ws activate 시 composition 정리(peek)/유지(combine).

### M4 — #16 UI 표식
- borrowed 마커 카테고리: `markerTargets`/`refreshMarkers`(`+Presentation.swift`) — borrowed 윈도우 색 구분, 새 `cfg.borrowedColorHex`.
- borrow/dismiss HUD(`hudEffect`).
- 워크스페이스 목록(`WorkspaceListView.swift`) borrowed/scratchpad badge.

### #17 핫키 확장
- `borrowRecent` 4방향(left/up/down) — `borrowRecentRight` 패턴 복제(HotKeysClient/AppSettings/AppConfig/AppFeature/SettingsView recorder).
- `Workspace.borrowShortcut`(특정 ws borrow) + `hotKeyBindings`.
- boundary resize 핫키: `slot.fraction` ± → `applyComposition`.

### #18 엣지 케이스
멀티 디스플레이, borrowed `displayHint` 무시, fullscreen-zoom 블록 내, floating/unmanaged 미러 스코프, prune→borrowed 비면 composition collapse, target==host 가드.

### #19 문서 + 1.5.0 릴리즈
`CONFIGURATION.md`(kind/borrow), CHANGELOG 1.5.0, What's New(`WhatsNewClient.swift`), `Project.swift` `appVersion` bump, `vX` 태그 push(release CI가 태그=appVersion 검증).

## 다음 진입점
1. `git checkout feature/borrow-composition`
2. **applyBSPOp 라우팅부터** (#10 마무리): `WorkspaceActivationFeature.swift`에서 `func applyBSPOp` 찾아 위 패턴 적용. 그 다음 #13(sync/prune/drag) → #14(flush) → M3 → M4 → #17/#18/#19.
3. 각 단계 빌드 후, 의미 있는 묶음마다 커밋.

## 빌드 / 테스트
- 로직 빌드: `xcodebuild -workspace Tatami.xcworkspace -scheme TatamiKit -destination 'platform=macOS' build`
- 전체 빌드: `-scheme Tatami`
- 실행: `killall Tatami; open /Users/pangmo5/Library/Developer/Xcode/DerivedData/Tatami-abzoohblcyzqwbfbfgakdjqklexa/Build/Products/Debug/Tatami.app`
- borrow 단축키: Settings → Shortcuts → Windows & Workspaces (Borrow recent workspace (right) / Dismiss borrow). 테스트: ws A→B 전환 후 borrow 핫키 → A가 우측에 나란히, dismiss로 복원.
- 디버그 로그: Settings → Debug logging ON → `~/.config/tatami/tatami.log` (`[Borrow]`/`[BSP]`/`[Sync]` 태그).

## 주의 (Tuist 프로젝트)
- `Tatami.xcodeproj`는 gitignored 생성물. 버전은 `Project.swift` `appVersion`이 단일 소스. **새 .swift 파일은 pbxproj 멤버십 문제** → 기존 파일에 타입 추가하거나 `tuist generate` 필요(지금까지 신규 타입은 기존 파일에 넣어 회피).
- main(1.4.2)은 borrow와 무관하게 clean. borrow는 feature 브랜치에만.
