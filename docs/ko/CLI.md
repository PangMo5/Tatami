<!-- LANGUAGE-LINKS:START -->
[English](../CLI.md) · [한국어](CLI.md) · [日本語](../ja/CLI.md) · [简体中文](../zh-Hans/CLI.md) · [繁體中文](../zh-Hant/CLI.md)
<!-- LANGUAGE-LINKS:END -->

<a id="tatami-command-line-reference"></a>
# Tatami 명령줄 안내

앱 번들에 `tatami` 실행 파일이 들어 있어요. CLI는 실행 중인 앱과 통신하므로 명령을 보내기 전에 Tatami를 켜주세요.

<a id="install"></a>
## 설치

**설정 → 일반 → 명령줄 → 설치**를 열어요. `/usr/local/bin/tatami`에 심볼릭 링크를 만들며, 설치하거나 제거할 때 macOS가 관리자 암호를 요청해요. 링크가 앱 번들을 가리키므로 같은 경로에서 앱을 교체하면 CLI도 함께 갱신돼요. 앱을 옮기거나 이름을 바꾸면 링크를 다시 설치해주세요.

실행 파일과 실행 중인 앱을 모두 확인해요.

```sh
tatami --version     # bundled CLI version, no app connection required
tatami version       # version reported by the running Tatami app
```

<a id="command-overview"></a>
## 명령 개요

```text
tatami version [--json]

tatami profile list [--json]
tatami profile activate <profile> [--json]
tatami profile rename <profile> <new-name> [--json]
tatami profile duplicate <profile> [--name <new-name>] [--json]

tatami workspace list [--profile <profile>] [--json]
tatami workspace apps <workspace> [--profile <profile>] [--json]
tatami workspace activate <workspace> [--profile <profile>] [--json]
tatami workspace rename <workspace> <new-name> [--profile <profile>] [--json]
tatami workspace duplicate <workspace> [--profile <profile>] [--name <new-name>] [--json]
tatami workspace next|previous|recent [--json]
tatami workspace move-app next|previous [--json]
tatami workspace assign-app to <workspace> [--profile <profile>] [--json]
tatami workspace assign-app next|previous|recent [--json]
tatami workspace borrow from <workspace> [--json]
tatami workspace borrow next|previous|recent [--json]
tatami workspace dismiss-borrow [--json]

tatami window focus left|right|up|down [--json]
tatami window cycle next|previous [--json]
tatami window resize grow|shrink [--json]
tatami window swap left|right|up|down [--json]
tatami window toggle-fullscreen|toggle-floating|toggle-shared-floating [--json]
tatami display focus next|previous [--json]

tatami layout toggle-orientation|balance|toggle-tiling [--json]

tatami app toggle-workspace|toggle-shared [--json]

tatami hook list [--json]
```

`tatami help`, `tatami help <command>`을 실행하거나 명령 뒤에 `--help`를 붙이면 ArgumentParser의 현재 사용법을 볼 수 있어요.

<a id="select-profiles-and-workspaces"></a>
## 프로필과 작업 공간 선택

`<profile>`과 `<workspace>`에는 현재 이름이나 UUID를 쓸 수 있어요. 작업 공간 이름은 `--profile`가 없으면 활성 프로필 안에서 찾아요. UUID는 전체에서 고유해서 `--profile` 없이 비활성 프로필도 선택할 수 있어요. 다만 `workspace borrow from`는 현재 프로필의 작업 공간만 빌릴 수 있으니 필요하면 프로필부터 바꿔주세요.

검색 범위 안에서 이름이 겹치면 아무것도 바꾸지 않고 실패하며 후보 UUID를 모두 보여줘요. 그중 하나로 다시 실행해주세요.

기존 스크립트를 위해 예전 명령도 호환 별칭으로 남겨뒀어요. 새 사용법은 분야별로 익힐 수 있도록 최상위 도움말에서는 숨겨요.

- `tatami list-workspaces`은 활성 프로필에 대한 `tatami workspace list`과 같아요.
- `tatami list-apps <workspace>`은 활성 프로필에 대한 `tatami workspace apps <workspace>`과 같아요.
- `tatami activate <workspace>`은 활성 프로필에 대한 `tatami workspace activate <workspace>`과 같아요.

이름 변경과 복제는 `config.toml`을 트랜잭션으로 갱신해요. 복제할 때는 새 설정을 공개하기 전에 저장한 배치도 복사해요. 배치 복사가 실패하면 설정은 바뀌지 않아요.

CLI 복제는 선택 창 없이 항목 전체를 복사해요. `workspace duplicate`은 같은 프로필 안에 생기므로 새 작업 공간의 키와 활성화·배정·빌려오기 단축키를 비워요. `profile duplicate`은 새 프로필의 전환 키와 자동 활성화 규칙을 비우지만, 프로필별로 분리된 작업 공간 키는 유지해요. 일부 공간·앱·설정·배치만 고르려면 앱의 복제를 사용하세요.

<a id="run-dispatcher-commands-by-domain"></a>
## 분야별 동작 명령 실행

`profile`, `workspace`, `window`, `display`, `layout`, `app`는 세 손가락·네 손가락 제스처에 연결할 수 있는 모든 동작을 제공해요. 활성화 외 동작은 `GestureAction`을 통해 제스처·전역 단축키와 같은 `HotKeyAction` 디스패처로 전달해요. 범용 `action` 우회 명령은 없어요.

대부분의 동작은 `accepted` 상태를 반환해요. 앱이 명령을 검증해서 공용 리듀서에 전달했다는 뜻이며, 이후 창 조작까지 성공했다는 뜻은 아니에요. 예를 들어 `window focus left`은 이웃 창이 없을 수 있고, 포커스한 앱 없이 배정 명령이 도착할 수도 있어요.

`profile activate`과 `workspace activate`은 전체 활성화 과정이 끝날 때까지 기다려 `completed`를 반환하거나 최종 실패를 알려줘요. 임시 공간에는 빌려오기 전용 명령 `workspace borrow from <workspace>`을 사용하세요.

켜기·끄기 전환 명령은 반복하면 결과가 달라져요. 중단되거나 결과가 불명확하면 먼저 상태를 확인하세요. 바로 재시도하면 첫 동작을 되돌릴 수 있어요.

<a id="profiles-and-workspaces"></a>
### 프로필과 작업 공간

|명령|동작|
| --- | --- |
|`profile activate <profile>`|프로필을 활성화하고 최종 완료까지 기다려요.|
|`workspace activate <workspace> [--profile …]`|작업 공간과 필요하면 소속 프로필을 활성화한 뒤 완료까지 기다려요.|
|`workspace next` / `previous` / `recent`|작업 공간의 기록이나 순서에 따라 이동해요.|
|`workspace move-app next` / `previous`|포커스한 앱을 옆 작업 공간으로 옮기고 전환해요.|
|`workspace assign-app to <workspace> [--profile …]`|기존 소속을 유지한 채 포커스한 앱을 추가해요. 필요하면 프로필을 바꾸고 대상 공간을 활성화해요.|
|`workspace assign-app next` / `previous` / `recent`|기존 소속을 유지한 채 앱을 추가하고 상대 위치의 작업 공간으로 이동해요.|
|`workspace borrow from <workspace>`|활성 프로필의 작업 공간에 대해 빌려올 방향을 고르는 화면을 열어요.|
|`workspace borrow next` / `previous` / `recent`|상대 위치의 작업 공간을 빌려와요.|
|`workspace dismiss-borrow`|포인터가 있는 화면의 빌려오기를 끝내요.|

앱 소속과 배치 방식을 저장하는 명령은 기본으로 확인 화면을 열어요. 확인한 뒤에 설정을 바꾸고 같은 화면에 결과를 보여줘요. 설정 → 일반 → 확인에서 동작별로 고를 수 있어요. ‘다시 보지 않기’는 실행한 동작의 확인만 끄며, 취소하면 유지해요.

<a id="windows-and-displays"></a>
### 창과 화면

|명령|동작|
| --- | --- |
|`window focus left` / `right` / `up` / `down`|이웃한 타일링 창으로 포커스를 옮겨요.|
|`window cycle next` / `previous`|현재 보이는 Tatami 작업 공간 안에서 창을 전환해요.|
|`window resize grow` / `shrink`|포커스한 BSP 분할 비율을 한 단계 조절해요.|
|`window swap left` / `right` / `up` / `down`|포커스한 타일링 창을 해당 방향의 창과 바꿔요.|
|`window toggle-fullscreen`|포커스한 창의 작업 공간 확대를 켜거나 꺼요.|
|`window toggle-floating` / `toggle-shared-floating`|작업 공간 또는 공용 앱에서 포커스한 앱의 타일링·항상 위 표시를 전환해요.|
|`display focus next` / `previous`|이웃 화면의 작업 공간으로 포커스를 옮겨요.|

CLI와 제스처의 창 전환은 즉시 실행돼요. 보조키를 길게 눌러 목록을 여는 동작은 실제 전역 단축키에서만 동작해요.

<a id="layout-and-tiling"></a>
### 배치와 타일링

|명령|동작|
| --- | --- |
|`layout toggle-orientation`|포커스한 분할의 방향을 바꿔요.|
|`layout balance`|활성 배치를 균등하게 맞춰요.|
|`layout toggle-tiling`|Tatami 타일링을 전체적으로 잠시 멈추거나 다시 시작해요.|

<a id="focused-app"></a>
### 포커스한 앱

|명령|동작|
| --- | --- |
|`app toggle-workspace`|이미 활성 공간에 속해 있으면 제거해요. 아니면 같은 프로필의 다른 공간에서 현재 공간으로 옮기고 타일링해요.|
|`app toggle-shared`|포커스한 앱을 타일링 공용 앱으로 추가하거나, 이미 공용이면 제거해요.|

<a id="hooks"></a>
### 훅

`tatami hook list`은 꺼져 있거나 유효하지 않은 항목까지 모든 훅을 보여줘요. **설정 → 훅**에서 추가·편집·삭제·켜기·끄기를 하거나 `config.toml`의 `[[hooks]]`을 직접 수정하세요. 파일 수정도 바로 반영돼요.

지원 이벤트는 `tatamiLaunched`, `profileChanged`, `workspaceActivated`, `hud`이에요. `tatamiLaunched`는 시작 시 활성 프로필을 정한 뒤 프로세스마다 한 번 발생해요. 해당 프로필을 포함하고 `previousProfile`, `workspace`, `display`, `hud`은 제외해요. 시작 시의 `profileChanged`와 별개라 둘 중 하나나 모두 구독할 수 있어요. `hud`은 SketchyBar 같은 도구에 짧은 화면 알림을 전달해요.

설정 편집기는 실행 파일과 각 인자를 별도 입력칸에 보관해요. 첫 값은 `command[0]`, 나머지는 argv가 돼요. 셸 명령으로 합치거나 공백·따옴표·변수를 해석하지 않아요. 셸 문법이 필요하면 `/bin/zsh` 실행 파일에 `-lc`와 스크립트를 따로 넘기세요. fish는 `which fish`이 알려준 경로에 `-c`와 명령을 별도 인자로 추가해요. 예를 들어 `command ls`는 사용자 정의 `ls` 함수를 건너뛰어요. 표준 입력으로 훅의 JSON 이벤트를 전달하므로 stdin을 읽는 명령은 그 이벤트를 받아요.

이벤트, 표준 입력, 환경 변수, 작업 폴더, 제한 시간의 전체 규칙은 [설정 안내](https://pangmo5.dev/Tatami/ko/configuration.html#hooks)에서 확인해요.

<a id="json-output-and-exit-status"></a>
## JSON 출력과 종료 상태

최종 명령 뒤에 `--json`을 붙이세요. `tatami --json profile list` 같은 상위 위치에는 쓸 수 없어요.

예시:

```sh
tatami profile list --json
tatami workspace apps "Coding" --profile "Dual" --json
tatami window focus left --json
```

성공한 JSON은 표준 출력으로 나와요. 디스패처 결과는 다음 형태예요.

```json
{
  "command": "window.focus.left",
  "title": "Focus left",
  "status": "accepted"
}
```

`command`과 `status`은 스크립트용으로 안정적으로 유지해요. `title`는 앱 언어에 따른 표시 문구예요. 프로필·작업 공간·앱·훅·변경 명령은 일반 문장을 감싸지 않고 식별자와 관련 정보가 있는 구조화된 객체를 반환해요.

인자를 해석한 뒤 실패하면 표준 오류에 `{"error":"…"}`을 쓰고 0이 아닌 코드로 끝나요. ArgumentParser의 사용법·도움말은 일반 텍스트예요. `--json`을 요청했는데 이전 앱이 일반 문장을 반환하면 새 CLI는 기계 판독 데이터로 취급하지 않고 거부해요.

<a id="socket-and-development-isolation"></a>
## 소켓과 개발 환경 분리

기본적으로 두 프로세스는 현재 사용자의 Darwin 임시 폴더 안에 있는 `tatami.socket`을 사용해요. 개발용 앱과 CLI를 분리하려면 `TATAMI_SOCKET_PATH`을 절대 경로로 정하고 두 프로세스에 정확히 같은 값을 전달하세요.

```sh
socket="${TMPDIR%/}/tatami-example.socket"
TATAMI_SOCKET_PATH="$socket" /path/to/Tatami.app/Contents/MacOS/Tatami &
TATAMI_SOCKET_PATH="$socket" /path/to/tatami workspace list
```

소켓은 앱이 소유해요. 앱이 꺼져 있으면 CLI는 실패 코드로 끝나고 Tatami 실행 여부를 확인하라고 알려줘요.

<a id="scripting-examples"></a>
## 스크립트 예시

UUID로 선택하고 `jq`으로 JSON 규칙을 확인해요.

```sh
profile_id="$(tatami profile list --json | jq -r '.[] | select(.isActive).id')"
tatami workspace list --profile "$profile_id" --json \
  | jq -r '.[] | [.id, .name, .kind] | @tsv'
```

명령을 전달하지 못하면 즉시 실패하도록 해요.

```sh
if ! result="$(tatami layout balance --json)"; then
  printf 'Tatami layout command failed\n' >&2
  exit 1
fi
printf '%s\n' "$result" | jq -e '.status == "accepted"' >/dev/null
```
