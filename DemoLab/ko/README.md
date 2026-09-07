<!-- LANGUAGE-LINKS:START -->
[English](../README.md) · [한국어](README.md) · [日本語](../ja/README.md) · [简体中文](../zh-Hans/README.md) · [繁體中文](../zh-Hant/README.md)
<!-- LANGUAGE-LINKS:END -->

<a id="tatami-demo-lab"></a>
# Tatami Demo Lab

실제 Tatami를 녹화해 일관된 제품 영상을 만들고 해당 기능 설명 옆에 배치해요. 앱과 내용은 데모용이며 전환·타일링·빌려오기·포커스는 설치한 Tatami가 실제로 수행해요.

<a id="publication-contract"></a>
## 공개용 영상 규칙

[`publication.json`](../publication.json)에 영상 목록과 편집 예산을 정해요. 각 장면을 웹 섹션에 연결하고 길이와 파일 크기를 제한해요.

종합 영상은 디자인 → 글쓰기 → 검토 → 빌려오기 → 자동화에 이어 실제 화면 구성 변경으로 끝나요. 기능별 모음은 작업 공간, 프로필·화면, 타일링·포커스, 빌려오기, 창 표시, CLI·훅, 가이드 설정을 다뤄요. 목록은 `publication.json`에서 만들므로 별도로 중복 관리하지 않아요.

종합 영상은 **작업을 바꿔도 하던 자리를 유지한다**는 약속을 보여줘요. 기능별 영상은 다른 활동을 보여주며 종합 영상을 반복하지 않아요. 전체 범위는 [기능과 검증 범위](../docs/ko/COVERAGE.md)에서 확인해요.

<a id="capture--export--review--install-locally"></a>
## 촬영 → 내보내기 → 검수 → 로컬 반영

평소 쓰는 데스크톱 대신 전용 Tart VM을 사용해요. `reset`과 `seed`은 실행한 컴퓨터의 Tatami를 종료하고 환경설정을 바꿔요. 설정·배치 파일은 `.build/lab/`에 격리하고 환경설정 도메인은 별도 백업해서 `democtl restore`으로 복구할 수 있어요.

```sh
# Host: run from the repository root.
swift build --package-path Tools -c release
TOOL=Tools/.build/release/tatami-tools
"$TOOL" vm-sync

# Guest: a fresh seed for every scene. Existing takes are never overwritten.
tart exec tatami-demo /Users/admin/DemoLab/.build/tools/tatami-tools capture \
  --root /Users/admin/DemoLab --output /Users/admin/DemoLab/recordings/publish

# Host: fetch that exact batch, including originals, metadata and scene snapshots.
GUEST_DIR=DemoLab/recordings/publish "$TOOL" vm-fetch-recordings DemoLab/recordings/publish

# Host: new output directory; no ambiguous “latest take” selection.
"$TOOL" export --takes DemoLab/recordings/publish --output ~/Downloads/TatamiDemoLab-review

# Open index.html and inspect playback, opening frames, actions and every feature.
# Install the verified bundle into this checkout only; this does not push or deploy.
"$TOOL" install-assets ~/Downloads/TatamiDemoLab-review
```

호스트에는 Swift 6.2 이상, `tart`, libass/libx264를 지원하는 `mpv`, `ffmpeg`, `ffprobe`이 필요해요. 호스트 명령은 저장소 루트에서 실행해요. 게스트에는 Xcode Command Line Tools가 필요해요. 소스를 동기화할 때 빌드된 자동화 실행 파일을 함께 전달하므로 게스트에서 패키지를 다운로드하지 않아요. 녹화기는 Tatami의 Tuist 그래프와 분리된 독립 SwiftPM 패키지로 유지돼요.

자동화에는 `swift-subprocess`, ArgumentParser, SwiftSoup, Hummingbird, `swift-markdown`, `swift-cmark`, Swift Crypto를 사용해요. JSON과 속성 목록은 Foundation으로 처리해요. 녹화 승인 조건, 번역 단위, 영상 길이·용량 제한은 Tatami 고유의 규칙으로 유지해요. `Tools/Package.resolved`에서 의존성 버전을 고정해요.

내보내기를 실행할 Mac에는 Fontconfig도 필요해요. 인코딩 전에 지정한 글꼴과 모든 자막 글자 지원 여부를 확인해요. OCR 검증은 영상 위에 표시된 자막을 타임라인과 별도로 비교해요.

<a id="a-small-set-of-useful-apps"></a>
## 실제로 쓰는 작은 앱 모음

|작업 공간|앱|실제 작업|
| --- | --- | --- |
|Design|Canvas + Docs|색상 방향을 바꾸고 저장한 초안을 확인한 뒤 PNG를 내보내요.|
|Write|Editor + Docs|안내를 읽고 제목을 고친 뒤 초안을 저장해요.|
|Review|Review + Docs|저장한 문구를 검사하고 의견을 남겨 승인해요.|
|Chat|Chat|로컬 데모 답장을 입력하고 보내요.|
|Build|Terminal|실제 Tatami CLI와 포함된 자동화 스크립트를 실행해요.|
|Notes(빌려오기 전용)|Notes|후속 작업을 적고 체크리스트 항목을 완료해요.|
|Focus|Canvas + Notes|해당 작업 공간의 메모를 항상 위에 두고 사용해요.|
|공용 앱|Monitor|저장한 프로젝트 상태나 실제 작업 공간·화면 알림 훅을 확인해요.|

8개 앱이 로컬에 저장한 데이터를 사용해요. 저장하면 Review와 Canvas에 반영되고 PNG도 실제로 만들어져요. 메모와 대화는 공간을 바꿔도 남아요. Terminal은 허용한 명령과 스크립트만 실행하고 훅은 실제 Tatami 환경을 받아요. 대화 서비스에는 연결하지 않으며 AI 영상은 표시해둔 로컬 예시를 사용해요.

<a id="what-changed-in-the-capture-contract"></a>
## 촬영 규칙의 변화

장면은 두 단계로 나뉘어요.

- `setup`은 **촬영 전에** 종료·앱 실행·작업 공간 준비·데이터와 배치 설정을 해요.
- `steps`은 영상에 보이는 동작이에요. 녹화 전에 `openingApps`의 창과 배치가 안정돼야 해요. `autoopen`만 자동 열기를 보여주기 위해 잠깐 빈 화면으로 시작해요.

녹화 전과 각 동작 전후에 시스템 권한·설정 창을 검사해요. 다른 창 뒤의 권한 창도 찾아요. 오류를 숨기거나 잘라내지 말고 해당 창을 해결하세요.

**녹화기 권한과 Tatami 권한은 별개예요.** `doctor`을 통과해도 오래된 Tatami 화면 기록 요청이 남은 적이 있어요. 항상 위 기능은 별도 ScreenCaptureKit 스트림을 쓰므로 녹화기 준비만으로는 확인할 수 없어요. `shared`을 미리 실행해 실제 상태 창을 확인하세요. 공용 Monitor는 모든 장면에 자동으로 열지 않고 `shared`에서 촬영 전에 명시적으로 열어요.

`waitWindows`은 지정 앱과 안정된 배치를 기다려요. `saveLayout`/`assertLayout`는 공간 전환·빌려오기 종료·확대 복귀 뒤에 같은 창 ID와 영역인지 비교해요. 창이 빠지거나 늘거나 4포인트 넘게 움직이면 실패해요.

`key`, `hold`은 실제 입력으로 키 표시를 만들어요. `keys` 문구로 CLI 실행을 키 입력처럼 꾸미면 안 돼요. 첫 인코딩 프레임이 없으면 시작을 거부하고, 그 프레임의 단조 시간을 넘겨 영상과 자막의 시계를 맞춰요.

<a id="presentation"></a>
## 화면 구성

원본 MOV에는 촬영한 데스크톱 전체가 담겨요. 내보낼 때는 1920×1200을 유지하고, 두 화면 영상은 1920×600으로 만들어요. 자막은 영상 아래쪽에, 장면 이름은 왼쪽 위에, 실제 키 입력은 오른쪽 위에 겹쳐 표시해요. 반투명 배경으로 밝거나 어두운 앱 위에서도 읽기 쉽게 했어요. 색상은 웹사이트 팔레트를 사용하므로 표현을 바꿀 때 다시 촬영할 필요는 없어요.

자막만 고칠 때는 촬영한 동작, 입력 내용, 검증 조건, 대기 시간이 모두 같아야 원본을 재사용할 수 있어요. 내보내기 도구는 촬영 당시 고정한 장면 파일의 해시와 동작을 검증한 뒤 원래 타임라인의 자막을 교체해요. 증거 자료에는 원본과 수정본의 장면 파일 및 타임라인을 모두 포함해요.

각 테이크에는 다음 파일이 있어요.

- `.mov`: 자막 없는 원본 영상.
- `.ass`: 수정할 수 있는 설명과 실제 키 입력 시간.
- `.timeline.json`: 모든 이벤트의 시작·끝 시간.
- `.take.json`: 성공 여부, 장면 해시, Tatami 버전, 언어, 출력별 프레임·손실 수, 시작 시각과 오버레이 모드.
- `.scene.json`: 녹화 시작 시 고정한 정확한 장면 파일.

실패한 촬영본은 진단용으로 보관하지만 내보내기에는 사용할 수 없어요. 촬영 조건 검증, 정상 자막, 1% 미만의 프레임 손실, 제때 나오는 시작 자막, 영상과 타임라인 길이 일치가 필요해요. 결과물은 시간·용량 제한을 지키고 H.264/yuv420p를 사용하며 FFmpeg 전체 디코딩을 통과해야 해요. `faststart`는 MP4 헤더를 영상 데이터 앞에 배치해요.

내보내기 묶음에는 재생 갤러리, 포스터, 추출한 검증 프레임, 원본·결과물 해시와 모든 부가 파일이 들어 있어요. 자동 검증이 실제 동작 확인을 대신하지는 않아요. 특히 공용 창 미러링과 포커스 대상은 화면으로 확인해야 해요. 웹 플레이어는 기본 컨트롤과 `preload="none"`를 사용하며, 직접 재생하고 한 번에 영상 하나만 재생돼요. 각 모음에는 썸네일 목록, 개수, 이전·다음 버튼이 있어요. 영상마다 관련 설정 키로 가는 링크도 제공해요. 방향키, Home/End, 개별 영상 링크는 별도 펼치기 없이 사용할 수 있어요.

두 화면 촬영은 게스트에 실제 가상 디스플레이를 연결하고 각각 녹화한 뒤 첫 프레임 시각으로 맞춰요. [확인한 VM 구성](../docs/ko/MULTI-DISPLAY.md)을 참고하세요.

<a id="work-on-one-scene"></a>
## 장면 하나 수정하기

촬영 명령은 전용 게스트 안에서 실행해요.

```sh
.build/DemoLab/bin/democtl doctor
.build/DemoLab/bin/democtl reset
.build/DemoLab/bin/democtl seed
.build/DemoLab/bin/democtl scene tour --dry-run    # prints setup and visible steps
.build/DemoLab/bin/democtl take tour --output recordings/iteration/tour.mov
# Host: after fetching that batch; run from the repository root.
Tools/.build/release/tatami-tools export --takes DemoLab/recordings/iteration \
  --output ~/Downloads/TatamiDemoLab-iteration --scenes tour
```

`democtl scene`은 실시간 설명을 띄워 연습해요. 녹화 `take`의 기본값은 `--overlay off`이며 공개용으로는 이 모드만 받아요. 연습 패널과 출력 디자인은 별개예요. `subtitle burn`으로 확인용 영상을 만들 수 있지만 예산·웹 인코딩·증거 검사는 `tatami-tools export`를 사용하세요.

마치면 게스트에서 `democtl quit`, `democtl restore`을 실행해요. 호스트의 Tatami와 원래 환경설정은 건드리지 않아요.

<a id="development-and-reference"></a>
## 개발과 참고 자료

```sh
swift test --package-path Tools
swift run --package-path Tools tatami-tools bundle-apps
DEMOLAB_LOCALIZATION_DIR="$PWD/DemoLab/.build/DemoLab/Localization" \
  swift test --package-path DemoLab
```

- [장면 문법](../docs/ko/SCENES.md)
- [VM 설정](../docs/ko/VM-TART.md)
- [권한](../docs/ko/PERMISSIONS.md)
- [실제 두 화면 촬영](../docs/ko/MULTI-DISPLAY.md)

<a id="five-language-production"></a>
## 다섯 언어 영상 제작

`en`, `ko`, `ja`, `zh-Hans`, `zh-Hant`를 지원해요. `Localization/Localizable.xcstrings`는 앱 문구와 초기 데이터, `Localization/Films.json`은 영상 제목·설명·입력 문구, `Localization/Interface.json`은 검수용 모음을 관리해요. 고유 ID가 없으면 제품 카탈로그에서 Tatami의 AX 문구를 가져와요. 앱과 사용자 지정 작업 공간·프로필 이름은 유지해요.

```sh
Tools/.build/release/tatami-tools localize-scenes
Tools/.build/release/tatami-tools vm-sync
# Inside the guest:
.build/tools/tatami-tools capture --locale ko --output recordings/ko-batch
# After fetching that explicit batch to the host:
Tools/.build/release/tatami-tools export --locale ko --takes DemoLab/recordings/ko-batch --output ~/Downloads/Tatami-ko
```

앱과 Tatami의 언어를 함께 설정해요. 입력과 검증은 같은 문구를 사용하고 실제 CLI 명령·출력은 유지해요. 최종 영상이 30fps라 촬영도 30fps로 해서 불필요한 60fps 처리를 줄여요.

`tatami-tools record-locales`는 언어별로 없거나 검증에 실패한 촬영본을 찾아요. 영어 촬영본으로 번역된 UI를 검증했다고 간주하지 않아요. 실패한 장면은 진단용으로 보관하고 다른 언어는 독립적으로 진행할 수 있어요.

작은 도구 창은 오른쪽 아래에서 시작해요. 종합 영상은 상태 창을 왼쪽 아래로 직접 옮겨요. 장면을 바꿀 때도 문서의 주요 읽기 영역은 비워두세요.

터미널 명령이 끝난 뒤에도 로컬 웹사이트 미리보기를 유지하려면 저장소 루트에서 `Tools/.build/release/tatami-tools preview-site --background`을 실행해요.
