<!-- LANGUAGE-LINKS:START -->
[English](../VM-TART.md) · [한국어](VM-TART.md) · [日本語](../ja/VM-TART.md) · [简体中文](../zh-Hans/VM-TART.md) · [繁體中文](../zh-Hant/VM-TART.md)
<!-- LANGUAGE-LINKS:END -->

<a id="recording-in-a-tart-vm"></a>
# Tart VM에서 녹화하기

전용 `tatami-demo`로 개인 창·환경설정·권한을 촬영과 분리해요. macOS 26.6.2, 고정 1920×1200 주 화면, 실제 Tatami와 8개 데모 앱을 써요. 두 번째 화면은 [MULTI-DISPLAY.md](MULTI-DISPLAY.md)처럼 게스트 안에서 만들어요.

<a id="prepare-the-guest"></a>
## 게스트 준비

호스트에는 Apple Silicon, Swift 6.2 이상, `exec`을 지원하는 Tart가 필요해요. 게스트에는 Tart 에이전트, Command Line Tools, Tatami가 필요해요. 호스트 명령은 저장소 루트에서, 게스트 명령은 `~/DemoLab`에서 실행해요.

```sh
swift build --package-path Tools -c release
Tools/.build/release/tatami-tools vm-bootstrap
```

`--no-display-refit`과 함께 `1920x1200px`으로 화면을 고정해 호스트 창 크기를 바꿔도 녹화 해상도가 바뀌지 않아요. 공유 폴더는 `/Volumes/My Shared Files/demolab`에 연결돼요.

프로비저닝하기 전에 사용할 Tatami 빌드를 Demo Lab 공유 폴더에 복사해요.

```sh
ditto /Applications/Tatami.app DemoLab/.build/Tatami.app
TATAMI_APP="/Volumes/My Shared Files/demolab/.build/Tatami.app" \
  Tools/.build/release/tatami-tools vm-provision
```

`TATAMI_APP` 대신 `TATAMI_DMG`도 사용할 수 있어요. SwiftPM은 공유 폴더가 아닌 게스트 디스크에서 빌드해요. 번들 생성 시 모든 앱을 LaunchServices에 등록해 배정한 ID를 찾을 수 있게 해요.

VM 창이나 화면 공유로 게스트를 열고 [PERMISSIONS.md](PERMISSIONS.md)에 따라 시스템 설정에서 권한을 주세요. 녹화기와 항상 위 기능을 모두 검사해야 해요. 현재 에이전트는 입력·캡처 권한이 있지만 새 이미지·실행기는 따로 확인해요. TCC DB를 고치거나 녹화기 준비만으로 미러 권한을 판단하지 마세요.

<a id="record-an-explicit-batch"></a>
## 지정한 배치 촬영

```sh
# Host: sync current sources and rebuild in the guest.
Tools/.build/release/tatami-tools vm-sync

# Guest: each scene gets fresh lab data and preferences suppression.
tart exec tatami-demo /Users/admin/DemoLab/.build/tools/tatami-tools capture \
  --root /Users/admin/DemoLab --continue-on-error \
  --output /Users/admin/DemoLab/recordings/review-batch

# Host: a new destination, retaining originals and all provenance sidecars.
GUEST_DIR=DemoLab/recordings/review-batch \
  Tools/.build/release/tatami-tools vm-fetch-recordings DemoLab/recordings/review-batch

Tools/.build/release/tatami-tools export --takes DemoLab/recordings/review-batch \
  --output ~/Downloads/TatamiDemoLab-review
```

일부 장면은 `--scenes tour cli desk`으로 고르세요. 기존 테이크를 덮어쓰지 않아요. `--continue-on-error`은 실패본을 남기고 장면 사이를 초기화하며 하나라도 실패하면 0이 아닌 코드로 끝나요. `capture-report.json`에 결과를 기록하고 현재 장면과 맞는 성공본만 내보내요.

녹화 중에는 호스트의 무거운 인코딩·컴파일을 피하세요. VM과 CPU를 나눠 쓰며 손실은 화면마다 측정해요. 촬영이 끝난 뒤 인코딩하세요.

<a id="shared-filesystem-correctness"></a>
## 공유 파일의 정확성

양방향 모두 고유한 이름의 아카이브를 써요. 호스트에서 옛 파일을 옮긴 뒤 같은 이름에 쓰면 virtiofs가 오래된 내용·inode를 보인 적이 있어요. 새 이름으로 이 재사용 경로를 없앴어요.

관리하는 소스 폴더만 동기화해 삭제한 Swift 파일이 게스트에 남지 않게 해요. `.build`과 녹화본은 유지해요. 고유 마커로 공유 위치를 확인하고 양쪽 SHA256을 비교한 뒤 새 로컬 폴더에 풀어요. 영상·자막·시간·촬영 정보·장면 JSON·결과 보고서를 함께 가져와요.

<a id="finish-or-preserve-the-image"></a>
## 마치기와 이미지 보관

```sh
tart exec tatami-demo /Users/admin/DemoLab/.build/DemoLab/bin/democtl quit
tart exec tatami-demo /Users/admin/DemoLab/.build/DemoLab/bin/democtl display disconnect
tart exec tatami-demo /Users/admin/DemoLab/.build/DemoLab/bin/democtl restore
```

`restore`은 촬영 전에 백업한 환경설정을 복원해요. 개인 호스트 설정은 건드리지 않아요. 종료하고 검증한 게스트는 `tart clone`으로 보관할 수 있어요. VM을 정리하기 전에 원본과 증거를 밖에 보관하세요.

<a id="verified-boundary"></a>
## 검증한 범위

v4에서는 실제 ScreenCaptureKit, 입력·AX 확인, 타일링·빌려오기, 두 화면 개별 캡처, 체인, 연결·해제 자동 프로필을 검증했어요. 독·물리 제스처·혼합 DPI·HDR·새 OS는 별도 검사예요. macOS 전체화면 복귀 실패는 [COVERAGE.md](COVERAGE.md)에 남겨뒀어요.
