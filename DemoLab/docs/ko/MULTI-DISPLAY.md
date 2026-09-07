<!-- LANGUAGE-LINKS:START -->
[English](../MULTI-DISPLAY.md) · [한국어](MULTI-DISPLAY.md) · [日本語](../ja/MULTI-DISPLAY.md) · [简体中文](../zh-Hans/MULTI-DISPLAY.md) · [繁體中文](../zh-Hant/MULTI-DISPLAY.md)
<!-- LANGUAGE-LINKS:END -->

<a id="multiple-displays-inside-the-recording-vm"></a>
# 녹화 VM 안의 여러 화면

macOS 26.6.2 Tart 게스트는 **게스트 내부 CoreGraphics 가상 화면**을 만들 수 있어요. 호스트의 `VZMacGraphicsDeviceConfiguration`에 두 번째 그래픽 화면을 추가하는 것과는 다른 경로예요.

예전 문서는 VZ 하드웨어 화면 제한을 게스트가 만드는 모든 화면의 제한으로 잘못 봤어요. 실제로 활성 1920×1200 화면 두 개가 열거됐고, Tatami 체인으로 Review와 Chat을 각각 배치했으며 두 화면을 독립 영상으로 녹화했어요.

<a id="reproduce"></a>
## 재현

전용 게스트 안에서 실행하세요.

```sh
.build/tools/tatami-tools build-virtual-display
.build/DemoLab/bin/democtl display connect
.build/DemoLab/bin/democtl displays
.build/DemoLab/bin/democtl reset
.build/DemoLab/bin/democtl seed
.build/DemoLab/bin/democtl take desk --display all --output recordings/desk.mov
.build/DemoLab/bin/democtl quit
.build/DemoLab/bin/democtl display disconnect
```

비공개 `CGVirtualDisplay` API는 Demo Lab 도구에만 쓰고 Tatami에는 넣지 않아요. [DeskPad CoreGraphics 인터페이스](https://github.com/Stengo/DeskPad/blob/main/DeskPad/CGVirtualDisplayPrivate.h)를 참고했어요. 1920×1200 일반 해상도 화면을 만들고 해제나 제한 시간까지 유지해요. PID의 실행 파일을 확인한 뒤 신호를 보내며 없거나 지원하지 않으면 명시적으로 실패해요.

<a id="synchronization-and-composition"></a>
## 동기화와 합성

`--display all`은 화면마다 원본을 하나씩 써요. 공통 단조 시계에 대한 첫 프레임 차이, 화면 원점, 각각의 프레임·손실 수를 남겨요. 호스트로 가져온 뒤 다음처럼 사용해요.

```sh
Tools/.build/release/tatami-tools compose-displays DemoLab/recordings desk
```

화면 원점 순서와 기록한 시간 차이로 영상을 맞춰요. 원본 두 개를 유지하고 무손실 중간 파일을 만들어요. 한 화면 영상과 같은 팔레트의 넓은 영상으로 내보내며, 스크린샷을 복제하거나 움직여 두 번째 화면을 꾸미지 않아요.

<a id="hotplug-is-a-separate-scene"></a>
## 화면 연결·해제는 별도 장면이에요.

화면 연결 데모는 주 화면을 계속 녹화해요. 두 번째 가상 화면이 연결되면 별도 녹화기가 해당 화면을 녹화하고, 연결 해제 직전에 종료해요. 두 영상은 각각의 실제 첫 프레임 시각으로 맞춰요. 합성할 때 나란히 배치하고 보조 화면을 촬영하지 않은 구간은 비워둬요. 주 화면을 복제하거나 연결 해제 뒤 정지 화면을 남기지 않아요. 촬영 명세에는 두 원본의 해시와 보조 화면 촬영 구간을 보관해요.

실제 케이블·독·HDR·혼합 DPI·트랙패드 인식은 별도 하드웨어 검증이에요. 게스트 OS가 바뀌면 비공개 CoreGraphics 호환성을 다시 확인해야 해요.
