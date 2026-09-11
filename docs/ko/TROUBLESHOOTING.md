<!-- LANGUAGE-LINKS:START -->
[English](../TROUBLESHOOTING.md) · [한국어](TROUBLESHOOTING.md) · [日本語](../ja/TROUBLESHOOTING.md) · [简体中文](../zh-Hans/TROUBLESHOOTING.md) · [繁體中文](../zh-Hant/TROUBLESHOOTING.md)
<!-- LANGUAGE-LINKS:END -->

<a id="troubleshooting"></a>
# 문제 해결

<a id="a-floating-control-disappears-or-brings-its-app-back"></a>
## 별도 컨트롤이 사라지거나 앱이 다시 나타나요.

일부 앱은 일반 창과 같은 프로세스에서 회의 기록이나 화면 속 화면을 보여줘요. 그 앱의 작업 공간을 떠나면 macOS의 앱 숨기기가 컨트롤도 함께 숨길 수 있어요. 컨트롤이 사라지거나 앱이 스스로 활성화되면서 일반 창이나 작업 공간이 다시 나타날 수 있어요.

대표적인 경우예요.

- AI Meeting Notes로 회의를 기록 중인 Notion
- Google Chrome이나 Dia 같은 브라우저의 화면 속 화면

앱을 표시 예외로 등록해보세요.

1. **설정 → 작업 공간**을 열고 별도 컨트롤이 있는 앱을 설정하는 영역으로 내려가세요.
2. **+**를 눌러 실행 중인 앱을 고르세요. 실행 중이 아니라면 파일에서 앱을 선택할 수 있어요.
3. 기존 작업 공간 배정은 그대로 두세요. 공용 앱으로 추가하는 것보다 좁은 범위의 설정이에요.

등록한 앱을 항상 숨기지 않는 것은 아니에요. 작업 공간·빌려오기 표시를 바꿀 때 일반 WindowServer 레이어 밖에 최상위 컨트롤이 실제로 보일 때만 프로세스를 남겨요. 이때 일반 창은 살아 있지만 포커스 자동화·창 전환·배치·드래그·배정에서 제외돼요. 다른 창 뒤나 Mission Control에는 보일 수 있어요.

조건에 맞는 컨트롤이 없어지면 다음 표시 변경부터 일반 숨기기로 돌아가요. 화면 밖·투명·일반 레이어의 컨트롤, 보조 프로세스가 소유한 컨트롤, 최상위 접근성 창으로 노출되지 않은 컨트롤은 해당하지 않아요.

> [!NOTE]
> 화면 속 화면이 타일링되는 문제는 별개예요. Tatami는 일반 레이어 밖의 PiP를 자동으로 타일링에서 제외하므로 앱 등록이 필요하지 않아요. 작업 공간을 바꿀 때 브라우저와 함께 PiP가 숨겨지는 경우에만 브라우저를 등록하세요.

`config.toml`을 직접 관리한다면 정확한 앱 번들 식별자를 사용하세요.

```toml
[settings.visibility]
overlayAwareApps = [
  "notion.id",
  "com.google.Chrome",
  "company.thebrowser.dia",
]
```

계속 사라진다면 **설정 → 일반**에서 디버그 로그를 켜고 작업 공간을 한 번 전환해보세요. `~/.config/tatami/tatami.log`의 `OverlayAware evaluate ... preserve=` 항목을 확인하세요. `preserve=false`는 컨트롤이 위 조건을 충족하지 못했다는 뜻이에요.

<a id="fullscreen-zoom-changes-after-connecting-a-display"></a>
## 디스플레이 연결 후 전체 화면 상태가 달라져요

현재 프로필과 작업 공간을 확인해 보세요. 연결된 모니터가 바뀌면 디스플레이 규칙에 따라 프로필이 자동으로 전환될 수 있어요. 다른 프로필에 같은 앱이 있어도 레이아웃과 전체 화면 상태는 작업 공간마다 따로 기억해요. 사용하는 각 프로필에서 배치를 설정하거나, 원치 않는 전환이라면 프로필의 디스플레이 규칙을 조정하세요.
