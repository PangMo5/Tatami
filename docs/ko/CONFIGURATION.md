<!-- LANGUAGE-LINKS:START -->
[English](../CONFIGURATION.md) · [한국어](CONFIGURATION.md) · [日本語](../ja/CONFIGURATION.md) · [简体中文](../zh-Hans/CONFIGURATION.md) · [繁體中文](../zh-Hant/CONFIGURATION.md)
<!-- LANGUAGE-LINKS:END -->

<a id="configuration"></a>
# 설정 안내

Tatami는 다음 경로에서 설정을 읽어요.

```
~/.config/tatami/config.toml
```

XDG 경로를 지원해요. `$XDG_CONFIG_HOME`이 있으면 `$XDG_CONFIG_HOME/tatami/config.toml`을 사용해요. 처음 실행할 때 파일을 만들고 앱에서 설정을 바꾸면 다시 저장해요. 직접 수정해도 바로 반영되므로 dotfiles에 두고 편집기에서 관리할 수 있어요.

외부 프로그램은 `NSFileCoordinator`에 참여하거나 임시 파일을 쓴 뒤 `config.toml`을 원자적으로 교체해야 해요. Tatami의 설정 트랜잭션과 충돌하는 교체는 감지해서 거부해요. `config.toml`를 연 채 다른 프로세스가 이름을 바꾼 뒤에도 같은 파일 디스크립터에 계속 쓰는 방식은 지원하지 않아요. POSIX rename은 이미 열린 디스크립터를 새 파일로 연결하지 못해요. 임시 파일 저장 후 원자적으로 바꾸는 편집기를 사용하세요.

안내를 따라 시작하고 싶다면 처음 실행할 때 열리는 **가이드 설정**을 사용하세요. 앱 정보와 화면으로 초안을 만들고 안전한 가상 화면에서 기능을 익혀요. **설정 적용**을 눌러야 파일에 저장해요. **설정 → 일반 → 가이드 설정 실행**에서 다시 열 수 있어요.

파일은 네 가지 최상위 부분으로 나뉘어요.

- **`[settings.*]`:** 아래에서 설명하는 전체 설정
- **`[[sharedApps]]`:** 모든 작업 공간에서 타일링하거나 항상 위에 둘 앱
- **`[[profiles]]`:** 작업 공간과 앱 배정
- **`[[hooks]]`:** 수명 주기·화면 알림 이벤트가 실행하는 프로그램

<a id="shortcut-syntax"></a>
## 단축키 문법

skhd 형식 문자열을 써요. 보조키를 0개 이상 `+`로 연결하고 ` - ` 뒤에 키를 적어요.

```
ctrl + alt - h
alt + shift - tab
ctrl + alt + shift + cmd - z
```

보조키는 `ctrl`, `alt`(option), `shift`, `cmd`이에요. 문자, 숫자, `tab`, `return`, 화살표(`left`/`right`/`up`/`down`), 문장부호 등을 키로 쓸 수 있어요.

<a id="settingsgeneral"></a>
## `[settings.general]`

|키|타입|기본값|설명|
| --- | --- | --- | --- |
|`launchAtLogin`|bool|`false`|로그인할 때 시작하도록 Tatami를 로그인 항목에 등록해요.|
|`checkForUpdatesAutomatically`|bool|`true`|새 릴리스를 주기적으로 확인해요.|
|`checkInterval`|string|`"daily"`|백그라운드 업데이트 확인 주기: `hourly`, `daily`, `weekly`.|
|`debugLogging`|bool|`false`|진단 이벤트를 `~/.config/tatami/tatami.log`에 추가해요. 처음 켤 때 기존 내용은 비워요.|

<a id="settingsconfirmations"></a>
## `[settings.confirmations]`

동작별로 확인 여부를 고를 수 있어요. 기본으로 모두 켜져 있어요. ‘다시 보지 않기’를 선택하고 실행하면 해당 동작의 확인만 꺼져요. 취소하면 설정을 유지해요. 기존 전체 확인 설정은 각 항목으로 이전하며, 직접 지정한 항목이 우선해요.

|키|기본값|동작|
| --- | --- | --- |
|`addWorkspaceApp`|`true`|작업 공간에 앱 지정|
|`moveWorkspaceApp`|`true`|작업 공간 사이에서 앱 이동|
|`removeWorkspaceApp`|`true`|작업 공간에서 앱 제거|
|`floatWorkspaceApp`|`true`|작업 공간 앱을 항상 위로 변경|
|`tileWorkspaceApp`|`true`|작업 공간 앱을 타일링으로 변경|
|`unmanageWorkspaceApp`|`true`|작업 공간 앱을 그대로 두기로 변경|
|`addSharedApp`|`true`|공용 앱 추가|
|`removeSharedApp`|`true`|공용 앱 제거|
|`floatSharedApp`|`true`|공용 앱을 항상 위로 변경|
|`tileSharedApp`|`true`|공용 앱을 타일링으로 변경|
|`unmanageSharedApp`|`true`|공용 앱을 그대로 두기로 변경|
|`deleteWorkspace`|`true`|작업 공간 삭제|
|`deleteProfile`|`true`|프로필 삭제|
|`deleteWorkspaceChain`|`true`|작업 공간 체인 삭제|
|`deleteHook`|`true`|훅 삭제|
|`removeOverlayException`|`true`|창 표시 예외 제거|
|`copyWorkspace`|`true`|작업 공간 설정 복사|
|`copyProfile`|`true`|프로필 설정 복사|
|`resetSetup`|`true`|설정 안내 처음부터 다시 시작|
|`reloadSetup`|`true`|설정 안내 초안 다시 불러오기|
|`applySetup`|`true`|설정 안내 초안 적용|
|`applySetupRecommendation`|`true`|설정 추천 적용|
|`deleteSetupWorkspace`|`true`|설정 초안에서 작업 공간 삭제|
|`deleteSetupProfile`|`true`|설정 초안에서 프로필 삭제|
|`uninstallCLI`|`true`|명령줄 도구 제거|

<a id="settingsvisibility"></a>
## `[settings.visibility]`

|키|타입|기본값|설명|
| --- | --- | --- | --- |
|`overlayAwareApps`|string[]|`[]`|계속 떠 있는 컨트롤을 가진 앱의 번들 ID예요. 등록한 프로세스가 일반 레이어 밖에 보이는 최상위 AX 창을 소유하면 숨기지 않되, 일반 창은 포커스·전환·배치·드래그·배정에서 제외해요. Mission Control에는 보일 수 있어요.|

앱별로 명시한 예외이며, 모든 떠 있는 창에 적용하는 규칙은 아니에요. 조건에 맞는 최상위 창이 없으면 일반 숨기기를 적용하고, 작업 공간·빌려오기 표시를 바꿀 때마다 다시 확인해요.

```toml
[settings.visibility]
overlayAwareApps = ["notion.id"]
```

증상과 앱 예시, 설정 화면의 조작 순서는 [문제 해결](https://github.com/PangMo5/Tatami/blob/main/docs/TROUBLESHOOTING.md#a-floating-control-disappears-or-brings-its-app-back)에서 확인해요.

<a id="settingsmenubar"></a>
## `[settings.menuBar]`

|키|타입|기본값|설명|
| --- | --- | --- | --- |
|`showWorkspaceIcon`|bool|`true`|메뉴 막대에 활성 작업 공간 아이콘을 보여줘요.|
|`showWorkspaceName`|bool|`true`|메뉴 막대에 활성 작업 공간 이름을 보여줘요.|
|`showProfileIcon`|bool|`true`|프로필이 여러 개일 때 활성 프로필 아이콘을 보여줘요.|
|`showProfileName`|bool|`false`|프로필이 여러 개일 때 활성 프로필 이름을 보여줘요.|

<a id="settingshud"></a>
## `[settings.hud]`

동작 결과를 짧게 알려주는 화면 알림이에요. 호환성을 위해 설정 표의 예전 이름 `hud`을 유지하지만 앱에서는 **화면 알림**이라고 불러요. `enabled`이 전체 스위치이고 나머지 키는 알림을 표시할 동작을 정해요.

|키|타입|기본값|설명|
| --- | --- | --- | --- |
|`enabled`|bool|`true`|모든 화면 알림의 전체 스위치예요.|
|`workspaceSwitch`|bool|`true`|전환할 때 작업 공간 이름을 보여줘요.|
|`windowCycle`|bool|`true`|창 전환 보조키를 누르고 있으면 앱·창 목록이 나타나요. 단축키나 화살표로 이동하고 Return·보조키 해제·클릭으로 선택해요. Escape로 취소하며 짧게 누를 때는 목록을 띄우지 않아요.|
|`profileSwitch`|bool|`true`|수동·자동으로 프로필을 바꿀 때 이름을 보여줘요.|
|`floating`|bool|`true`|작업 공간 앱과 공용 앱의 항상 위 상태 변경을 알려줘요. 키 이름은 호환성을 위해 유지해요.|
|`appMembership`|bool|`true`|앱을 작업 공간이나 공용 앱에 추가·제거했음을 알려줘요.|
|`tilingPaused`|bool|`true`|타일링을 멈추거나 다시 시작할 때 보여줘요.|
|`fullscreen`|bool|`true`|창 확대를 시작하거나 끝냈음을 알려줘요.|
|`borrow`|bool|`true`|빌려오기·돌려보내기와 방향 선택 안내를 보여줘요.|
|`layout`|bool|`true`|균등 배치처럼 자체 시각 효과가 없는 명령 결과를 알려줘요.|
|`position`|string|`"top"`|짧은 화면 알림의 위치예요. `topLeading`, `top`, `topTrailing`, `leading`, `center`, `trailing`, `bottomLeading`, `bottom`, `bottomTrailing` 중에서 골라요. 앱·창 선택 목록은 별도로 가운데에 나타나요.|
|`size`|string|`"default"`|짧은 화면 알림의 전체 크기예요. `small`, `default`, `large` 중에서 골라요. 앱·창 선택 목록은 고정 크기를 유지해요.|
|`durationMs`|int|`900`|나타나고 사라지는 애니메이션 사이에 완전히 보이는 시간(ms)이에요. 후속 안내가 있으면 두 배 오래 보여줘요.|

<a id="settingslayout"></a>
## `[settings.layout]`

|키|타입|기본값|설명|
| --- | --- | --- | --- |
|`gapInner`|int|`8`|이웃한 타일링 창 사이의 픽셀 간격이에요.|
|`gapOuter`|int|`8`|타일과 화면 가장자리 사이의 픽셀 간격이에요.|
|`autoBalance`|string|`"none"`|창을 넣거나 뺄 때 비율을 다시 맞춰요. `none`, `horizontal`, `vertical`, `both` 중에서 골라요. 예전 bool 값도 `true` → `both`, `false` → `none`로 읽을 수 있어요.|
|`splitType`|string|`"auto"`|새 창이 들어올 때 기본으로 나누는 방향이에요. `auto`(화면 비율 기준), `horizontal`, `vertical`를 사용할 수 있어요.|
|`windowPlacement`|string|`"second"`|새 창을 새 분할의 어느 쪽에 놓을지 정해요. `first`은 위·왼쪽, `second`은 아래·오른쪽이에요.|

<a id="window-and-layout-restoration"></a>
### 창과 레이아웃 복원

Tatami는 작업 공간마다 분할 방향, 비율, 전체 화면 상태를 기억해요. 창이 닫히거나 하나씩 열리는 동안에는 현재 창으로 화면을 채우고, 아직 없는 창의 자리를 보관해요. 다시 열린 창은 보관된 자리로 돌아갈 수 있어요. 크기 조절, 재배치, 전체 화면 전환처럼 직접 레이아웃을 바꾸면 현재 창을 기준으로 새로 기억해요.

어떤 창을 다시 열지는 macOS와 각 앱이 결정해요. Tatami는 열린 창에 기억한 레이아웃을 적용하며, 문서를 직접 다시 열지는 않아요. 다음 macOS 설정은 각각 다른 상황에 적용돼요.

- **시스템 설정 → 데스크탑 및 Dock**의 **응용 프로그램을 종료하면 윈도우 닫기**: 끄면 이 기능을 지원하는 앱이 다음 실행 때 창을 다시 열 수 있어요. 켜면 앱이 새 창을 열 수 있어요.
- 로그아웃·재시동·시스템 종료 대화상자의 **다시 로그인하면 윈도우 다시 열기**: 선택하면 macOS가 다음 로그인 때 앱과 창을 다시 열어요. Tatami의 **로그인 시 실행**을 켜거나 로그인 후 Tatami를 열면 저장한 레이아웃을 적용할 수 있어요.

Tatami는 문서 이름 대신 앱과 창 순서로 자리를 연결해요. 앱이 창을 다시 만드는 순서를 바꾸면 다른 문서가 같은 자리에 놓일 수 있어요. 새 창도 이전 자리를 사용할 수 있어요. 작업 공간의 **자동 열기**는 macOS의 문서 복원과 별개로 앱을 실행하는 설정이에요.

<a id="settingsfocus"></a>
## `[settings.focus]`

|키|타입|기본값|설명|
| --- | --- | --- | --- |
|`mouseFollowsFocus`|bool|`false`|Tatami가 포커스한 창으로 커서를 옮겨요. 방향 포커스, 앱·창 전환, 작업 공간 변경, 창 닫기 뒤 포커스, 교체, 분할 방향 변경, 확대·복귀에서 새 위치로 따라가요. 항상 위·그대로 두기 창은 실제 창 영역을 사용해요. Dock이나 Spotlight에서 앱을 켰다면 최근 창이 아니라 시스템이 실제로 올린 창을 따라가요. 클릭이나 드래그 놓기, 드래그 교체·삽입·원위치 복귀처럼 포인터가 시작한 변경에서는 포인터를 그대로 둬요. 늘리기·줄이기·균등 배치에서도 움직이지 않아 키를 누르고 있을 때마다 중앙으로 돌아가지 않아요.|
|`mouseHidesOnFocus`|bool|`false`|작업 공간을 바꾸면 마우스를 움직일 때까지 커서를 숨겨요.|
|`focusFollowsMouse`|bool|`false`|커서가 움직이면 그 아래 창으로 포커스를 옮겨요.|
|`refocusOnClose`|bool|`true`|포커스한 창을 닫아 앱에 창이 남지 않으면 같은 작업 공간에서 최근에 쓴 남은 창을 순서대로 찾아 포커스를 옮겨요.|
|`focusFollowsMouseIgnoreFullscreen`|bool|`true`|마우스에 따라 포커스를 옮길 때 화면 전체를 채운 창에는 전환하지 않아요.|
|`focusFollowsMouseDisableHotkey`|string|`"Alt"`|마우스에 따른 포커스 이동을 잠시 멈출 보조키예요. `None`, `Alt`, `Cmd`, `Ctrl`, `Shift` 중에서 골라요.|

<a id="settingsswitching"></a>
## `[settings.switching]`

|키|타입|기본값|설명|
| --- | --- | --- | --- |
|`loop`|bool|`true`|마지막 작업 공간 다음에는 처음으로, 처음 이전에는 마지막으로 이어져요.|
|`skipEmpty`|bool|`false`|다음·이전 이동에서 실행 중인 앱이 없는 작업 공간을 건너뛰어요.|
|`followAppFocus`|bool|`true`|앱을 활성화하면 소속 작업 공간으로 전환해요.|
|`cycleAcrossDisplays`|bool|`false`|다음·이전 작업 공간을 포인터가 있는 화면뿐 아니라 모든 화면에서 찾아요. 키 이름은 호환성을 위해 유지해요.|
|`recentAcrossDisplays`|bool|`true`|모든 화면이 하나의 최근 작업 공간 기록을 써요. 대상이 다른 화면에 이미 보이면 옮기지 않고 그 화면에서 포커스해요. 화면마다 기록을 나누려면 `false`로 설정하세요.|
|`switchToRecentWhenEmpty`|bool|`false`|활성 공간의 마지막 창이 닫히고 타일링 창과 전용 항상 위 창이 없으면 최근 공간으로 이동해요. 공용 앱은 모든 공간에 있으므로 계산에서 제외해요.|
|`cycleSameAppWindows`|bool|`false`|창 전환 단위를 정해요. 기본값 `false`은 앱별로 전환하며 각 앱의 최근 창을 불러와요. `true`는 같은 앱의 여러 창까지 하나씩 방문해요. 활성 공간의 타일링·항상 위·그대로 두기 창이 참여하고, 빌려오는 동안 두 타일링 영역을 함께 전환해요. 키 이름은 호환성을 위해 유지해요.|
|`includeSharedAppsInWindowSwitcher`|bool|`true`|앱·창 전환에 공용 앱을 포함해요. 빌려오기 중에는 타일링하지 않은 공용 창도 두 타일링 영역과 함께 참여해요. `false`면 어디서나 공용 앱을 전환 목록에서 제외해요.|
|`toggleBorrowOnRepeat`|bool|`true`|이미 옆에 있는 작업 공간을 다시 빌리면 돌려보내고 원래 공간을 복원해요. `false`면 빌려온 공간을 옮겨요.|
|`borrowDefaultEdge`|string?|_(설정 안 함)_|기본 빌려오기 위치예요. `top`, `bottom`, `left`, `right`을 사용할 수 있어요. 설정하지 않으면 키 조합 뒤에 h/j/k/l 또는 화살표를 기다려요. 작업 공간의 `borrowEdge`가 이 값보다 우선해요.|
|`borrowFraction`|double|`0.4`|분할 방향에서 빌려온 영역이 차지하는 비율(0.1~0.9)이에요. 작업 공간의 `borrowFraction`가 우선해요.|

키보드 창 전환은 Tatami가 실행 중인 동안 작업 공간마다 최근 포커스 순서를 따로 기억해요. 다음 창 단축키를 짧게 눌렀다 놓으면 마지막으로 사용한 앱이나 창으로 돌아가요. 보조 키를 누른 채 목록을 고를 수 있고, 키를 놓거나 취소할 때까지 목록 순서는 바뀌지 않아요. 다른 작업 공간으로 이동하거나 창 배치를 바꿔도 각 공간의 기록은 유지돼요. 창 전환 제스처는 배치 순서대로 이동해요.

<a id="settingsgestures"></a>
## `[settings.gestures]`

|키|타입|기본값|설명|
| --- | --- | --- | --- |
|`enabled`|bool|`false`|설정한 세 손가락·네 손가락 쓸기를 인식해요.|
|`threshold`|double|`0.3`|동작을 실행하기까지 필요한 쓸기 거리예요. 작을수록 민감하고 소수 둘째 자리까지 저장해요.|
|`threeFinger`|table|왼쪽 → `nextWorkspace`, 오른쪽 → `previousWorkspace`|세 손가락 `left`, `right`, `up`, `down` 쓸기의 동작이에요. 빠진 방향은 `none`로 처리해요.|
|`fourFinger`|table|모든 방향 → `none`|네 손가락 `left`, `right`, `up`, `down` 쓸기의 동작이에요.|

방향마다 동작 문자열 하나를 저장해요. 앱의 하위 메뉴를 쓰면 프로필·작업 공간의 안정적인 UUID를 자동으로 써줘서 쉽게 설정할 수 있어요.

```toml
[settings.gestures]
enabled = true
threshold = 0.3

[settings.gestures.threeFinger]
left = "nextWorkspace"
right = "previousWorkspace"
up = "toggleFullscreen"
down = "none"

[settings.gestures.fourFinger]
left = "focusPreviousDisplay"
right = "focusNextDisplay"
up = "activateProfile:00000000-0000-0000-0000-000000000001"
down = "activateWorkspace:00000000-0000-0000-0000-000000000010"
```

사용할 수 있는 고정 동작 문자열이에요.

- **작업 공간:** `nextWorkspace`, `previousWorkspace`, `recentWorkspace`, `moveAppToNextWorkspace`, `moveAppToPreviousWorkspace`, `assignAppToRecentWorkspace`, `assignAppToNextWorkspace`, `assignAppToPreviousWorkspace`
- **포커스와 화면:** `focusNextDisplay`, `focusPreviousDisplay`, `focusLeft`, `focusRight`, `focusUp`, `focusDown`
- **창 전환:** `cycleNextWindow`, `cyclePreviousWindow`
- **배치:** `growWindow`, `shrinkWindow`, `swapLeft`, `swapRight`, `swapUp`, `swapDown`, `toggleOrientation`, `toggleFullscreen`, `balanceLayout`
- **앱과 타일링:** `toggleFloating`, `toggleSharedFloating`, `toggleTiling`, `toggleAppInWorkspace`, `toggleAppInSharedApps`. **항상 위**의 설정 식별자는 호환성을 위해 `floating`를 유지해요.
- **빌려오기:** `borrowRecentWorkspace`, `borrowNextWorkspace`, `borrowPreviousWorkspace`, `dismissBorrow`
- **연결 안 함:** `none`

특정 대상을 지정할 땐 안정적인 식별자를 붙여요. `activateWorkspace:<workspace UUID>`, `assignAppToWorkspace:<workspace UUID>`, `borrowWorkspace:<workspace UUID>`, `activateProfile:<profile UUID>`을 사용할 수 있어요. 특정 작업 공간은 소속 프로필이 활성 상태일 때 빌릴 수 있어요. 활성화나 배정은 먼저 소속 프로필로 전환할 수 있어요.

예전 `fingerCount = 3`, `4` 설정은 자동으로 옮겨져요. 해당 손가락 수의 좌우는 기존 다음·이전 작업 공간 동작을 유지하고, 나머지 방향과 손가락 수는 연결하지 않아요.

<a id="settingsmarker"></a>
## `[settings.marker]`

확대·항상 위·빌려온 창을 구분하는 작은 모서리 표시예요.

|키|타입|기본값|설명|
| --- | --- | --- | --- |
|`fullscreenEnabled`|bool|`true`|작업 공간 크기로 확대한 창에 포커스가 있을 때 점을 표시해요.|
|`fullscreenColorHex`|string|`"#007AFF"`|확대 표시의 색상(`#RRGGBB`)이에요.|
|`floatingEnabled`|bool|`true`|항상 위 창에는 상태를 바로 알 수 있도록 점을 계속 표시해요.|
|`floatingColorHex`|string|`"#FF9500"`|항상 위 표시의 색상(`#RRGGBB`)이에요.|
|`borrowEnabled`|bool|`true`|빌려온 창에 소속 작업 공간 아이콘을 표시해요.|
|`borrowColorHex`|string|`"#AF52DE"`|빌려오기 표시의 색상(`#RRGGBB`)이에요.|
|`size`|double|`14`|점의 지름을 포인트로 정해요. 빌려오기 표시는 아이콘이 잘 보이도록 더 크게 그려요.|
|`corner`|string|`"bottomTrailing"`|점을 놓을 창 모서리예요. `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing` 중에서 골라요.|
|`hideOnHover`|bool|`true`|커서가 점 위에 있으면 흐리게 보여줘요.|

<a id="settingsshortcuts"></a>
## `[settings.shortcuts]`

대부분 skhd 형식 단축키 문자열이에요. 키를 생략하면 동작에 연결하지 않아요. `config.toml`이 없는 새 설정에는 [권장 기본값](#recommended-defaults)을 넣어요. 모든 단축키는 다시 기록하거나 지울 수 있어요. 아래 세 `*Modifiers` 배열은 작업 공간 **키**를 정하는 별도 모델이에요.

<a id="workspace-keys-switch--assign--borrow"></a>
### 작업 공간 키: 전환·배정·빌려오기

작업 공간마다 단축키 세 개를 만들 필요 없이 한 글자 **키**(`keyEquivalent`)를 정해요. 세 가지 공용 보조키 조합 중 하나와 함께 눌러 동작을 골라요.

|키|타입|기본값|동작|
| --- | --- | --- | --- |
|`keyEquivalentModifiers`|string[]|`["ctrl", "alt"]`|+ 작업 공간 키 → 해당 공간으로 **전환**|
|`assignModifiers`|string[]|`["ctrl", "alt", "shift"]`|+ 작업 공간 키 → 포커스한 앱을 **배정**하고 이동|
|`borrowModifiers`|string[]|`["ctrl", "alt", "cmd"]`|+ 작업 공간 키 → 현재 화면으로 **빌려오기**|

보조키 토큰은 `ctrl`, `alt`, `shift`, `cmd`이에요. 빈 배열이면 해당 조합을 꺼서 일반 글자 키가 입력을 가로채지 않아요.

위 **기본값**은 *기존* 설정에 키가 없을 때 쓰는 값이에요. 새로 설치하면 `keyEquivalentModifiers = ["ctrl", "alt", "shift"]`, `assignModifiers = ["alt", "shift", "cmd"]` 권장 조합을 넣어요. [권장 기본값](#recommended-defaults)을 확인하세요.

같은 세 보조키는 각각 별도 키가 있는 **최근·다음·이전** 이동에도 사용돼요.

|키|타입|설명|
| --- | --- | --- |
|`recentWorkspaceKey`|string?|최근 작업 공간 키예요. 전환·배정·빌려오기 보조키와 함께 눌러요.|
|`nextWorkspaceKey`|string?|다음 작업 공간 키예요.|
|`previousWorkspaceKey`|string?|이전 작업 공간 키예요.|

각 동작에 **별도 단축키**를 지정할 수 있어요. 보조키와 작업 공간 키 조합보다 우선해요.

- 작업 공간별로 `activateShortcut`, `assignAppShortcut`, `borrowShortcut`를 지정할 수 있어요. 아래 작업 공간 항목을 확인하세요.
- **이동 대상별:** `switchTo{Recent,Next,Previous}Workspace`, `assign{Recent,Next,Previous}Workspace`, `borrow{Recent,Next,Previous}Workspace`. 모두 skhd 문자열을 사용해요.

작업 공간 키와 별도 단축키는 소속 프로필에서만 활성화돼요. 다른 프로필은 같은 키를 쓸 수 있어요. 전역 단축키는 모든 프로필과 충돌 여부를 확인해요. 복사·복제도 대상 프로필에 저장하기 전에 선택한 키 변경을 검증해요.

기본 위치(`settings.switching.borrowDefaultEdge` 또는 작업 공간의 `borrowEdge`)가 없으면 빌려오기 뒤에 방향키 h/j/k/l 또는 화살표를 기다려요. `dismissBorrow`로 돌려보내면 원래 작업 공간을 화면 전체에 복원해요.

<a id="action-shortcuts"></a>
### 동작 단축키

|키|동작|
| --- | --- |
|`focusLeft` / `focusRight` / `focusUp` / `focusDown`|해당 방향의 타일로 포커스를 옮겨요. 가장자리에서는 빌려온 영역으로 넘어가요.|
|`swapLeft` / `swapRight` / `swapUp` / `swapDown`|포커스한 타일을 해당 방향으로 교체해요.|
|`resizeGrow` / `resizeShrink`|선택한 창의 상위 분할 방향에 따라 좌우 또는 위아래로 영역을 늘이거나 줄임|
|`toggleOrientation`|포커스한 분할의 방향을 전환해요.|
|`toggleFullscreen`|포커스한 창을 작업 공간 크기로 확대해요.|
|`balance`|설정한 `autoBalance` 축을 적용해요. 자동 균등 배치가 꺼져 있으면 현재 창 순서로 표준 BSP 구조와 비율을 다시 만들어요.|
|`cycleNextWindow` / `cyclePreviousWindow`|현재 Tatami 작업 공간 안에서 앱이나 창을 전환해요. Command-Tab처럼 관련 없는 앱을 포함하지 않고, Command-backtick처럼 한 앱에만 머물지도 않아요.|
|`moveToNextWorkspace` / `moveToPreviousWorkspace`|포커스한 앱을 다음·이전 작업 공간으로 옮기고 따라가요.|
|`dismissBorrow`|빌려온 작업 공간을 돌려보내고 원래 공간을 화면 전체로 복원해요.|
|`focusNextDisplay` / `focusPreviousDisplay`|다음·이전 화면의 활성 작업 공간으로 포커스를 옮겨요. 끝에서는 처음으로 돌아가요.|
|`toggleFloating`|포커스한 앱을 현재 공간에서 항상 위에 둬요. 필요하면 공간에 추가해요. 다시 실행하면 타일링으로 돌아가요.|
|`toggleSharedFloating`|포커스한 앱을 어디서나 항상 위에 둬요. 필요하면 공용 앱으로 추가해요. 끄면 공용 *타일링*으로 바뀌며, 소속을 제거하려면 `toggleAppInSharedApps`을 사용해요.|
|`toggleFocusedAppInActiveWorkspace`|현재 창의 앱을 활성 작업 공간에 추가해요. 이미 속해 있으면 제거해요.|
|`toggleAppInSharedApps`|포커스한 앱을 공용 앱으로 추가해 모든 공간에 타일링해요. 이미 공용이면 제거해요.|
|`toggleSpaceActivated`|타일링 일시 정지·재개|

<a id="recommended-defaults"></a>
### 권장 기본값

`config.toml`이 없는 새 설정에는 바로 쓸 수 있는 기본 단축키를 넣어요. 창·타일 조작은 `⌃⌥`, 작업 공간 **전환**은 `⌃⌥⇧`, **배정**은 `⌥⇧⌘`을 써요. 작업 공간 키와 `⌃⌥` 포커스 키가 겹치지 않도록 나눴어요. 모두 다시 기록하거나 지울 수 있어요.

|동작|단축키|
| --- | --- |
|왼쪽·아래·위·오른쪽으로 포커스|`⌃⌥H` · `⌃⌥J` · `⌃⌥K` · `⌃⌥L`|
|왼쪽·아래·위·오른쪽과 교체|`⌃⌥←` · `⌃⌥↓` · `⌃⌥↑` · `⌃⌥→`|
|늘리기·줄이기|`⌃⌥=` · `⌃⌥-`|
|방향 전환|`⌃⌥S`|
|전체 화면 전환|`⌃⌥⏎`|
|균등 배치|`⌃⌥E`|
|다음·이전 창으로 전환|`⌥⇥` · `⌥⇧⇥`|
|항상 위 전환|`⌥⌘⏎`|
|공용 앱 항상 위 전환|`⌥⇧⌘⏎`|
|타일링 일시 정지/재개|`⌃⌥⇧⌘Z`|
|작업 공간 앱 소속 전환|`⌃⌥/`|
|공용 앱 소속 전환|`⌃⌥⇧/`|
|앱을 이전·다음 작업 공간으로 이동|`⌃⌥⇧[` · `⌃⌥⇧]`|
|이전·다음 화면으로 포커스|`⌃⌥⇧←` · `⌃⌥⇧→`|
|빌려온 작업 공간 돌려보내기|`⌃⌥⌘/`|
|최근·다음·이전 작업 공간 키|`\` · `.` · `,`|

작업 공간 **전환·배정·빌려오기**는 위 보조키와 각 작업 공간 키, 최근·다음·이전 키를 조합해요.

<a id="sharedapps"></a>
## `[[sharedApps]]`

여기에 있는 앱은 **모든** 작업 공간에 속해요. `layout`은 `tiled`(기본 타일링), `floating`(**항상 위**, 미러로 모든 공간 위에 표시), `unmanaged`(**그대로 두기**, 소속만 유지하고 위치·크기는 건드리지 않음)이에요. 화면에 창이 없을 때 열어주는 `autoOpen`(bool, 기본 `false`)도 설정할 수 있어요. `iconPath`은 자동으로 기록되는 관리용 문자열이므로 직접 정하지 않아요.

```toml
[[sharedApps]]
bundleIdentifier = "com.apple.iphonesimulator"
name = "Simulator"
layout = "floating"      # untiled, always on top, available in every workspace

[[sharedApps]]
bundleIdentifier = "com.apple.Music"
name = "Music"
layout = "tiled"         # tiled into every workspace's layout (default)

[[sharedApps]]
bundleIdentifier = "com.colliderli.iina"
name = "IINA"
layout = "unmanaged"     # left alone as a member, but never tiled or mirrored
```

SIP를 끄지 않아도 창을 항상 위에 둘 수 있어요. ScreenCaptureKit 미러를 별도 패널에 표시하므로 **화면 기록** 권한이 필요해요(설정 → 일반 → 권한). 앱 자체에 포커스가 있으면 미러를 숨기고 캡처를 멈춰요. `unmanaged` 앱은 실제 창을 건드리지 않아 이 권한이 필요하지 않아요.

앱의 **작업 공간 → 공용 앱**에서 타일링·항상 위·그대로 두기를 편집할 수 있어요.

예전 `[[floatingApps]]` 설정은 처음 읽을 때 `layout = "floating"`을 가진 공용 앱으로 자동 변환해요. 1.4 이전의 `floating` bool도 `true` → `floating`, 그 외 → `tiled`로 옮겨져요.

<a id="hooks"></a>
## `[[hooks]]`

Tatami가 다음 이벤트를 알리면 훅이 프로그램을 실행해요.

- `tatamiLaunched`: 시작 시 활성 프로필을 정한 뒤 프로세스마다 한 번 발생해요. 해당 프로필을 전달하고 `previousProfile`, `workspace`, `display`은 없어요. 같은 프로세스에서 나중에 추가한 훅에는 다시 보내지 않아요.
- `profileChanged`: 활성 프로필 선택이 바뀌었어요. 시작 시에는 `previousProfile`이 없어요.
- `workspaceActivated`: 작업 공간이 화면에 표시 상태를 반영했어요. 활성화가 실패하거나 시간이 초과되면 보내지 않아요.
- `hud`: 짧은 화면 알림을 보냈어요. Tatami에 전달한 것과 같은 다국어 제목, SF Symbol, 선택 부제, 시간, 위치, 크기와 대상 화면을 담아요. SketchyBar 같은 도구도 같은 알림을 보여줄 수 있어요.

시작 시의 `tatamiLaunched`과 `profileChanged`은 별도 이벤트예요. 프로세스 시작이 필요한지, 프로필 변경이 필요한지에 따라 하나나 모두 설정하세요.

**설정 → 훅**에서 훅을 추가·편집·삭제하거나 켜고 끌 수 있어요. 실행 파일, 각 인자, 작업 폴더, 제한 시간, 환경 변수를 따로 입력해요. 아래의 `[[hooks]]`과 같은 항목을 저장하므로 `config.toml`을 직접 수정해도 바로 반영돼요.

**테스트 실행**은 현재 초안을 검증하고 예시 이벤트로 한 번 실행해요. 훅을 추가·수정하거나 `config.toml`에 쓰지는 않아요. 초안을 남기려면 별도로 **저장**하세요.

```toml
[[hooks]]
id = "notify-context"
event = "workspaceActivated"
enabled = true
command = ["/Users/me/.config/tatami/hooks/notify-context", "--compact"]
timeoutMs = 5000
workingDirectory = "/Users/me"
environment = { MODE = "desktop" }
```

|키|타입|기본값|설명|
| --- | --- | --- | --- |
|`id`|string|_(필수)_|ASCII 문자, 숫자, `.`, `_`, `-`를 쓰는 고유 진단 ID예요. 최대 64자예요.|
|`event`|string|_(필수)_|`tatamiLaunched`, `profileChanged`, `workspaceActivated`, `hud` 중 하나예요.|
|`enabled`|bool|`true`|훅 실행 여부예요. 꺼져 있어도 `tatami hook list`에서 볼 수 있어요.|
|`command`|string[]|_(필수)_|실행 파일 뒤에 인자를 적어요. 각 요소는 argv 값 하나예요.|
|`timeoutMs`|int|`5000`|실행 제한 시간은 100~300000ms예요.|
|`workingDirectory`|string?|Tatami 설정 폴더|절대 경로나 `~/`로 시작하는 경로예요.|
|`environment`|table|`{}`|앱이 물려받은 환경에 추가할 값이에요. 아래 Tatami 맥락 값이 우선해요.|

Tatami는 `command`을 직접 실행해요. 셸을 열거나 단어·따옴표·변수를 해석하지 않아요. 편집기에서도 `command[0]`이 실행 파일이고 각 인자 행이 argv 하나가 돼요. 셸 문법이 필요하면 `command = ["/bin/zsh", "-lc", "your pipeline"]`처럼 명시하세요. fish는 `which fish`의 경로를 쓰고 `command = ["/opt/homebrew/bin/fish", "-c", "command ls"]`처럼 옵션과 명령을 나눠요. 표준 입력에는 이벤트 JSON을 보내요. 실행 파일에 `/`가 있으면 경로로 처리하고 앞의 `~/`를 확장해요. 이름만 있으면 앱의 `PATH`에서 찾아요. Finder에서 연 앱에는 절대 실행 경로가 가장 예측하기 쉬워요.

각 훅은 표준 입력으로 버전이 있는 JSON 객체 하나를 받아요. `schemaVersion`, `event`, `occurredAt`, `profile`과 해당하는 경우 `previousProfile`, `workspace`, `display`, `hud`을 담아요. `hud` 객체에는 `title`, `symbolIconName`, `subtitle`, 선택적인 `subtitleSymbolIconName`, `durationMs`, `position`, `size`가 있어요. 화면을 알 수 있으면 `display`도 전달해요. 체인 전환에서는 영향을 받은 화면마다 그 공간의 알림을 보내요. `durationMs`은 완전히 표시하는 시간이고 외부 도구는 앞뒤 애니메이션을 따로 더해요. 아래 환경 변수도 설정해요.

- `TATAMI_HOOK_ID`, `TATAMI_HOOK_EVENT`
- `TATAMI_PROFILE_ID`, `TATAMI_PROFILE_NAME`
- 작업 공간 이벤트에는 `TATAMI_WORKSPACE_ID`, `TATAMI_WORKSPACE_NAME`, `TATAMI_WORKSPACE_KIND`가 있어요.
- 화면을 알 수 있으면 `TATAMI_DISPLAY_UUID`, `TATAMI_DISPLAY_NAME`을 전달해요.
- `hud` 이벤트에는 `TATAMI_HUD_TITLE`, `TATAMI_HUD_SYMBOL_ICON_NAME`, `TATAMI_HUD_SUBTITLE`, `TATAMI_HUD_SUBTITLE_SYMBOL_ICON_NAME`, `TATAMI_HUD_DURATION_MS`, `TATAMI_HUD_POSITION`, `TATAMI_HUD_SIZE`가 있어요. 선택값이 없으면 빈 문자열 대신 항목 자체를 빼요.

예를 들어 SketchyBar 연결은 `event = "hud"`을 구독하고 `command`에 `TATAMI_HUD_*` 변수를 맞춤 이벤트로 넘기는 스크립트를 지정할 수 있어요. stdin의 JSON도 쓸 수 있어 선택 필드가 필요한 도구는 환경 변수 규칙을 따로 해석하지 않아도 돼요. 훅 자체의 실패·복구 알림은 `hud`으로 다시 보내지 않아 실패한 훅이 자신을 반복 실행하는 것을 막아요.

표준 출력과 오류는 각각 64KiB까지예요. 비정상 종료·신호·실행 실패·출력 초과·시간 초과는 문제 목록과 켜져 있는 디버그 로그에 남아요. 훅 실패로 프로필·작업 공간 변경을 막거나 되돌리지 않아요. 별도 프로세스 세션에서 실행하며 종료·시간 초과 시 정상 종료를 요청한 뒤 셸 백그라운드 그룹을 포함한 남은 자식을 강제 종료해요. 훅은 새 세션으로 분리되면 안 돼요. 같은 `id`이 실행 중이어도 새 이벤트는 독립 실행하고 최신 호출만 현재 문제를 갱신해요. 변경·끄기·삭제하면 이전 실행을 취소하고 문제를 지워요.

<a id="profiles-and-workspaces"></a>
## `[[profiles]]`과 작업 공간

프로필은 이름이 있는 작업 공간 묶음이에요. 여러 개를 전환하면 각 화면을 다시 정리하고, 연결된 화면에 따라 **자동 활성화**할 수도 있어요. 활성 프로필, 화면별 기록, 전체 최근 순서는 `config.toml` 옆의 `profile-session.json`에 저장하며 `config.toml`에는 쓰지 않아요. 시작할 때 마지막 수동 프로필은 항상 복원해요. 화면 조건이 있으면 조건이 여전히 맞을 때만 복원하고, 아니면 가장 알맞은 자동 프로필을 찾아요.

프로필마다 앱과 설정이 독립적이라 서로 달라질 수 있어요. 상세 화면의 **다른 구성에서 복사** 기능으로 차이를 검토하고, 선택한 앱·설정 변경만 가져올 수 있어요.

```toml
[[profiles]]
id = "00000000-0000-0000-0000-000000000001"
name = "Default"
symbolIconName = "rectangle.stack"     # optional: SF Symbol (sidebar / menu bar / switch feedback)
shortcut = "ctrl + alt + cmd - 1"      # optional: hotkey to switch to this profile

# Optional: auto-activate this profile when the connected displays match. All
# set conditions apply together (AND). Omit the table for manual switching only.
[profiles.autoActivation]
displayCount = ">=2"                        # "==N" | ">=N" | "<=N"
whenConnectedMatch = "contains"             # "contains" (present) | "exactly" (set ==)
whenConnected = ["37D8832A-…::IP1640"]      # these must be connected
whenDisconnected = ["0E769C72-…::Projector"] # these must be unplugged

[[profiles.workspaces]]
id = "00000000-0000-0000-0000-000000000010"
name = "Browser"
symbolIconName = "safari.fill"        # any SF Symbol name
kind = "normal"                        # "normal" | "scratchpad" (borrow-only)
keyEquivalent = "b"                    # switch/assign/borrow modifier + this key
borrowEdge = "right"                   # optional: dock to this edge when borrowed
displayHint = "Built-in Retina Display"           # optional: pin to a display ("<uuid>::<name>" or "<name>")
appToFocusBundleId = "app.zen-browser.zen"        # optional: focus this app on activation

[[profiles.workspaces.apps]]
bundleIdentifier = "app.zen-browser.zen"
name = "Zen Browser"
autoOpen = false                       # launch on activation if not running
layout = "tiled"                       # "tiled" | "floating" | "unmanaged"

[[profiles.workspaces]]
id = "00000000-0000-0000-0000-000000000011"
name = "Code"
kind = "normal"
displayHint = "37D8832A-…::Studio Display"

# Optional symmetric workspace chain. It stores workspace identity only;
# destinations come from each workspace's pin and the pointer at switch time.
[[profiles.workspaceChains]]
id = "00000000-0000-0000-0000-000000000100"
name = "Coding"                        # optional, for the Settings UI
workspaceIds = [
  "00000000-0000-0000-0000-000000000010",
  "00000000-0000-0000-0000-000000000011",
]
# Optional: ignore this pinned workspace's pin when it is placed as a
# companion by this chain. The workspace's ordinary activation is unchanged.
dynamicWorkspaceIds = ["00000000-0000-0000-0000-000000000011"]
```

프로필 항목:

|키|타입|설명|
| --- | --- | --- |
|`id`|UUID|안정적인 식별자예요.|
|`name`|string|표시할 이름이에요.|
|`symbolIconName`|string?|프로필의 사이드바·메뉴 막대·전환 알림에 표시할 SF Symbol이에요. 생략하면 `rectangle.stack`을 써요.|
|`shortcut`|string?|이 프로필로 전환할 skhd 형식 단축키예요.|
|`autoActivation`|table?|아래 화면 조건이 맞으면 자동 활성화해요. 생략하면 수동으로만 선택해요. 표는 있지만 조건이 없으면 모든 구성을 만족해요.|
|`workspaceChains`|table[]|여러 화면에서 함께 전환하는 대칭 작업 공간 그룹이에요. 화면 위치는 체인에 저장하지 않고 활성화할 때 정해요. 쓰지 않으면 생략해요.|

**`[profiles.autoActivation]`:** 모든 키는 선택 사항이고 AND로 묶여요. 여러 프로필이 맞으면 더 구체적인 것을 선택해요. `exactly`이 `contains`보다 우선하고, 조건이 많을수록 우선해요. 같으면 앞에 있는 프로필을 써요.

|키|타입|설명|
| --- | --- | --- |
|`displayCount`|string?|연결한 화면 수: `"==1"`, `">=2"`, `"<=1"`.|
|`whenConnected`|string[]?|반드시 연결되어야 하는 화면(`"<uuid>::<name>"` 또는 `"<name>"`)이에요.|
|`whenConnectedMatch`|string|기본값 `"contains"`은 목록의 화면이 모두 있으면 추가 화면을 허용해요. `"exactly"`은 연결된 화면이 목록과 정확히 같아야 해요.|
|`whenDisconnected`|string[]?|연결되어 있으면 안 되는 화면이에요.|

**`[[profiles.workspaceChains]]`:** 체인은 기준이나 부모가 없는 대칭 그룹이에요. 화면 칸 대신 안정적인 작업 공간 UUID를 순서대로 저장해요. 한 공간은 프로필 안에서 하나의 체인에만 속하고, 체인은 같은 프로필의 서로 다른 일반 공간을 두 개 이상 가져야 해요. 작업 공간 이름은 바꿔도 안전해요.

사용자가 직접 전환한 작업 공간만 체인을 시작해요. 체인이 복원한 공간은 다시 체인을 시작하지 않아요. 선택한 공간은 반드시 배치하며 단독 활성화와 같은 화면 고정·포인터·전체 최근 기록 규칙을 써요. 동료 공간을 먼저 복원하고 선택한 공간을 마지막에 복원해서 포커스를 유지해요.

화면 배치는 고정 설정 검사에 넣지 않고 현재 연결된 화면으로 정해요. 선택한 공간을 예약한 뒤 나머지를 `workspaceIds` 순서로 살펴봐요. 고정 화면이 연결되어 있고 비어 있으면 쓰고, 끊겨 있으면 다른 화면으로 보내지 않고 건너뛰어요. 동적 공간은 포인터 화면부터 다음 빈 화면을 사용해요. `dynamicWorkspaceIds`은 일반 고정을 유지한 채 체인 동료일 때만 같은 방식으로 배치해요. 우선순위가 높은 공간과 겹치거나 남은 화면이 없으면 건너뛰고 계속해요. 따라서 멤버마다 화면이 필요하지 않고 `workspaceIds`가 확정적인 우선순위가 돼요.

체인 동적 동료가 일반 복원보다 먼저 빈 화면을 차지해요. 체인 밖 화면은 유효한 최근 기록, 해당 화면 고정 공간, 사용하지 않는 동적 공간 순으로 복원해요. 잘못된 참조나 체인 간 중복은 문제로 남겨 고칠 수 있게 하고 해당 체인은 실행하지 않아요.

작업 공간 체인 항목:

|키|타입|설명|
| --- | --- | --- |
|`id`|UUID|프로필 안에서 고유한 안정적인 체인 식별자예요.|
|`name`|string?|설정에 보여줄 선택 이름이에요. 활성화에는 영향을 주지 않아요.|
|`workspaceIds`|UUID[]|충돌을 해결할 순서대로 놓은 서로 다른 일반 작업 공간 ID 두 개 이상이에요.|
|`dynamicWorkspaceIds`|UUID[]?|체인 동료로 배치할 때 다음 빈 화면을 쓸 고정 공간이에요. `workspaceIds`의 부분집합이며 사용하지 않으면 생략해요.|

작업 공간 항목:

|키|타입|설명|
| --- | --- | --- |
|`id`|UUID|안정적인 식별자예요.|
|`name`|string|표시할 이름이에요.|
|`symbolIconName`|string?|메뉴 막대와 사이드바에 표시할 SF Symbol이에요.|
|`kind`|string|`normal`(기본값) 또는 `scratchpad`이에요. 임시 공간은 **빌려오기 전용**이라 일반 전환에서 제외되고 단독으로 활성화하지 않아요. 옆으로 빌려올 때 앱을 자동으로 열어요.|
|`keyEquivalent`|string?|전환·배정·빌려오기 보조키와 함께 누를 한 글자 키예요. `[settings.shortcuts]`을 확인하세요. 생략하면 이 공간의 키 조합을 꺼요.|
|`activateShortcut`|string?|전환 조합 대신 사용할 별도 단축키예요.|
|`assignAppShortcut`|string?|기존 소속을 유지해 앱을 추가하고 이곳으로 전환하는 배정 조합의 별도 단축키예요.|
|`borrowShortcut`|string?|빌려오기 조합 대신 사용할 별도 단축키예요.|
|`borrowEdge`|string?|이 공간의 기본 빌려오기 위치를 `top`, `bottom`, `left`, `right`으로 덮어써요. 생략하면 `settings.switching.borrowDefaultEdge`를 쓰고, 그 값도 없으면 방향을 선택해요.|
|`borrowFraction`|double?|이 공간의 빌려올 크기 비율(0.1~0.9)을 덮어써요. 생략하면 `settings.switching.borrowFraction`을 써요.|
|`appToFocusBundleId`|string?|활성화할 때 포커스할 배정 앱의 번들 ID예요. 생략하면 최근에 쓴 앱을 선택해요.|
|`displayHint`|string?|`"<uuid>::<name>"`이나 `"<name>"`로 화면에 고정해요. 생략하면 마우스가 있는 화면에 열고, 고정 화면이 없으면 주 화면을 써요. 동적 공간이 떠난 화면은 그 화면의 기록에서 다시 채우되, 해당 화면 고정 공간이나 다른 화면이 쓰지 않는 동적 공간만 골라요. 연결이 끊긴 화면에 고정된 공간은 가져오지 않아요. 맞는 공간이 없으면 화면을 비워둬요.|

앱 배정 항목:

|키|타입|설명|
| --- | --- | --- |
|`bundleIdentifier`|string|앱의 번들 ID예요.|
|`name`|string|표시할 이름이에요.|
|`autoOpen`|bool|작업 공간을 활성화하면 앱을 열어요. 창을 닫았더라도 다시 들어가면 열어줘요.|
|`layout`|string|`tiled`(**타일링**), `floating`(**항상 위**, 타일링하지 않고 미러로 위에 표시), `unmanaged`(**그대로 두기**, 소속과 위치를 유지하며 타일링·미러·화면 기록을 사용하지 않음)예요. 1.4 이전 `floating` bool에서 자동으로 옮겨져요.|
|`iconPath`|string?|자동으로 저장한 앱 아이콘 경로예요. 직접 설정하지 않아요.|
