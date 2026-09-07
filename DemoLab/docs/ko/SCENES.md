<!-- LANGUAGE-LINKS:START -->
[English](../SCENES.md) · [한국어](SCENES.md) · [日本語](../ja/SCENES.md) · [简体中文](../zh-Hans/SCENES.md) · [繁體中文](../zh-Hant/SCENES.md)
<!-- LANGUAGE-LINKS:END -->

<a id="scenes-and-acceptance"></a>
# 장면과 통과 기준

장면에는 `name`, `title`, `steps`가 필요해요. `summary`, `requires`, `setup`, `openingApps`, `captureSecondary`은 선택 필드예요. `setup`은 녹화 전에 실행되고, `steps`는 영상에 보이는 과정을 담아요. 각 동작은 설치된 Tatami와 네이티브 데모 앱을 직접 조작해요.

주 화면을 계속 녹화하면서 두 번째 화면은 연결된 동안만 촬영하는 핫플러그 장면에서는 `captureSecondary`을 `true`로 설정해요.

```sh
.build/DemoLab/bin/democtl scene tour --dry-run
.build/DemoLab/bin/democtl take tour --output recordings/iteration/tour.mov
```

<a id="preparation"></a>
## 준비

첫 프레임에 보여야 할 앱을 `openingApps`에 적어요. 의도한 중복 창까지 실제 일반 창 목록과 같아야 해요. `autoopen`은 처음에 앱을 여는 기능이라 빈 배열을 써요. 배치가 400ms 동안 안정된 뒤 확인해요.

촬영 전에 Tatami로 작업 공간을 준비해요. 자동 열기가 진행 중일 때 같은 앱을 수동으로 다시 열면 같은 번들 ID의 프로세스와 창이 두 개 생길 수 있어요. 첫 화면 검사가 실패하면 나중에 잘라내지 말고 준비 과정을 고쳐요.

<a id="real-actions"></a>
## 실제 동작

|유형|필드|효과|
| --- | --- | --- |
|`click`|`app`, `identifier`|네이티브 AX 컨트롤을 찾고 포인터를 옮겨 클릭해요.|
|`typeText`|`app`, `text`, `ms?`|포커스가 맞는 앱에 한 글자씩 입력해요.|
|`hover`|`app`, `identifier`|스크롤 영역 안으로 컨트롤을 보여주고 포인터를 옮겨요.|
|`scroll`|`app`, `identifier`, `pixels`|네이티브 컨트롤로 이동해서 스크롤해요.|
|`key`|`chord`, `repeats?`, `holdMs?`|실제 단축키를 누르고 그 입력을 표시해요.|
|`hold`|`modifiers`, `keys`, `gapMs?`, `releaseAfterMs?`|창 전환 중 실제 보조키를 계속 눌러요.|
|`activateApp`|`app`|보이는 제목 막대를 누르고 AX로 포커스를 확인해요. 가려진 창은 실제 전환 동작으로 선택해야 해요.|
|`activateWorkspace`|`workspace`, `profile?`|완료를 기다리는 Tatami 활성화 명령을 실행해요.|
|`activateProfile`|`profile`|완료를 기다리는 프로필 명령을 실행해요.|
|`cli`|`args`, `expect?`|다른 Tatami 명령을 실행해요. `accepted`은 대기열에 넣었다는 뜻일 뿐이에요.|
|`borrow`|`workspace`, `expectApps?`, `timeoutMs?`|전문 연습용 CLI 빌려오기예요. 공개 영상은 실제 키를 써요.|
|`dismissBorrow`|`settleMs?`|전문 연습용 CLI 돌려보내기예요.|
|`pointer`|`display`, `x`, `y`|정규화한 화면 좌표에 포인터를 놓아요.|
|`launch`|`apps`, `windows?`|주로 촬영 전에 데모 앱을 명시적으로 실행해요.|
|`quitApps`|`apps?`|지정한 앱이나 데모 앱 전체를 종료해요.|
|`dragWindow`|`app`, `target`, `x`, `y`|제목 막대를 대상 창의 정규화 좌표로 드래그해요.|
|`restoreWindow`|`app`|실제 드래그로 저장한 창의 크기와 위치를 되돌린 뒤 원래 영역인지 확인해요.|
|`rightClick`|`app`, `identifier`|컨트롤의 기본 컨텍스트 메뉴를 열어요.|
|`resizeWindow`|`app`, `x`, `y?`|네이티브 창의 가장자리를 드래그해요.|
|`virtualDisplay`|`connected`|게스트의 실제 가상 화면 도구를 연결하거나 해제해요.|
|`configure`|`field`, `value`|실험용 TOML의 허용한 설정을 원자적으로 바꿔요.|
|`clipboard`|`text`|클립보드의 모든 데이터 형식을 백업·복원하며 예시 텍스트를 제공해요.|
|`closeSettings`|—|편집 뒤 네이티브 설정 창을 닫아요.|
|`prepareSettings`|—|컨트롤을 조작하기 전에 Tatami 설정 창의 크기와 위치를 맞춰요.|
|`appWindows`|`app`, `count`|주로 준비 단계에서 실제 창 수를 정해요.|

`appState` 명령은 없어요. 미리 만든 성공 화면으로 이동하지 않고 일반 컨트롤과 `StoryRepository`로 저장한 작업을 공유해요. 문구·검토·검사·할 일·메시지는 같은 제어 폴더에 저장해요. `seed`만 이야기를 초기화하고 공간 전환은 초기화하지 않아요. 대화는 네트워크 없는 로컬 데모예요.

<a id="assertions-and-pacing"></a>
## 검증과 속도

|유형|필드|통과 기준|
| --- | --- | --- |
|`expectPlacement`|`app`, `target`, `value`|모든 대상 앱 창이 비교할 창들의 왼쪽·오른쪽·위·아래 중 지정한 위치에 있는지 확인해요.|
|`expectProfileCount`|`count`|실제 CLI로 프로필 개수를 확인해요.|
|`expectAssignment`|`app`, `workspace`, `profile`|복사한 앱이 대상 작업 공간에 포함됐는지 확인해요.|
|`expectValue`|`app`, `identifier`, `value`|네이티브 입력값을 다시 읽어요.|
|`expectStory`|`field`, `value`|저장한 제목·승인·의견·마지막 할 일과 메시지·검사·완료 수를 확인해요.|
|`expectFront`|`app`|접근성 API로 실제 포커스 앱을 확인해요.|
|`expectPointer`|`app`|포인터가 대상 창 안에 있어야 해요.|
|`expectCommand`|`text`, `code`|Terminal의 실제 프로세스 실행 결과를 확인해요.|
|`expectHook`|`field`, `value`|실제 Tatami 훅이 기록한 값을 읽어요.|
|`saveWindow` / `assertWindow`|`app`|소속이 바뀌어도 같은 창의 위치를 저장하고 비교해요.|
|`saveControlFrame` / `expectControlMoved`|`app`, `identifier`, `text`|배치 편집기 동작이 실제 미리보기를 바꿨는지 확인해요.|
|`waitWindows`|`apps`, `timeoutMs?`|보이는 창과 안정된 배치를 기다려요.|
|`waitWorkspace`|`workspace`, `timeoutMs?`|바로 앞 동작에서 나온 활성화 훅을 확인해요.|
|`waitProfile`|`profile`, `timeoutMs?`|프로필 훅을 확인해요.|
|`saveLayout`|`text`|보이는 데모 창 ID와 영역을 이름 있는 체크포인트로 저장해요.|
|`expectLayoutChanged`|`text`|현재 보이는 배치가 이름으로 지정한 저장 지점과 달라졌는지 확인해요.|
|`assertLayout`|`text`|같은 창 목록과 영역으로 4포인트 이내에 돌아와야 해요.|
|`beat`|`ms`, `note?`|명시한 읽기 시간이에요. 숨겨진 시작 대기는 없어요.|
|`note`|`text`|로그에만 남기는 설명이에요.|

동작 전후에 권한·설정 창을 검사해요. 실패하면 촬영을 중단하고 실패 메타데이터를 남겨요. 내보내기는 실패본을 거부해요.

<a id="narration"></a>
## 설명과 자막

`chapter`, `caption`은 `text`를 담고 자막에는 `headline | explanation`을 쓸 수 있어요. 빈 문자열은 해당 줄을 지우고 `clearOverlay`는 모든 설명을 지워요. `key`, `hold`은 실제 키 표시를 만들어요. 별도 `keys`은 수동 연습에만 허용해요. 공개 영상에 쓰면 없던 키 입력처럼 보일 수 있어요.

`take`의 기본값은 `--overlay off`이며, 텍스트는 편집 가능한 ASS와 JSON 부가 파일에 기록해요. 내보낸 영상은 화면 아래쪽에 자막을, 왼쪽 위에 챕터를, 오른쪽 위에 실제 키 입력을 겹쳐 보여줘요. 반투명 배경으로 가독성을 높이지만 앱 내용을 가릴 수 있으므로 중요한 컨트롤은 해당 영역을 피해서 배치해요. `scene`는 실시간 리허설 패널을 사용하며, 최종 영상의 표시 방식과는 달라요.

배치 위치와 시간·용량 예산은 [publication.json](../../publication.json), 촬영·출력·검수 명령은 [README.md](../../ko/README.md)를 참고하세요.
