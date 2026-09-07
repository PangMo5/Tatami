<!-- LANGUAGE-LINKS:START -->
[English](../MULTI-DISPLAY.md) · [한국어](../ko/MULTI-DISPLAY.md) · [日本語](../ja/MULTI-DISPLAY.md) · [简体中文](MULTI-DISPLAY.md) · [繁體中文](../zh-Hant/MULTI-DISPLAY.md)
<!-- LANGUAGE-LINKS:END -->

<a id="multiple-displays-inside-the-recording-vm"></a>
# 录制 VM 内的多显示器

macOS 26.6.2 Tart VM 可以创建**虚拟机内的 CoreGraphics 虚拟显示器**，不同于向主机 `VZMacGraphicsDeviceConfiguration` 添加第二个图形显示器。

旧文档错误地把 VZ 硬件显示器限制视为所有虚拟显示器的限制。实测枚举出两个活动 1920×1200 显示器，Tatami 链分别放置 Review 和 Chat，ScreenCaptureKit 成功独立录制两屏。

<a id="reproduce"></a>
## 复现

在专用 VM 内执行：

```sh
./scripts/build-virtual-display.sh
./bin/democtl display connect
./bin/democtl displays
./bin/democtl reset
./bin/democtl seed
./bin/democtl take desk --display all --output recordings/desk.mov
./bin/democtl quit
./bin/democtl display disconnect
```

私有 `CGVirtualDisplay` 仅用于 Demo Lab，不进入 Tatami。参考 [DeskPad 接口](https://github.com/Stengo/DeskPad/blob/main/DeskPad/CGVirtualDisplayPrivate.h)，创建 1920×1200 非 HiDPI 显示器，持续到断开或限时结束。发送信号前检查 PID 对应执行文件；工具缺失或不支持时明确失败。

<a id="synchronization-and-composition"></a>
## 同步与合成

`--display all` 为每个显示器写一个原始文件，记录相对公共单调时钟的首帧偏移、显示器原点和独立帧数、丢帧数。取回主机后：

```sh
python3 scripts/compose-displays.py recordings desk
```

按物理原点排序并用记录的偏移对齐，保留两个原始文件，生成无损中间文件，再使用相同 Tatami 配色导出宽屏双屏视频。不会复制或动画化截图来伪造第二个屏幕。

<a id="hotplug-is-a-separate-scene"></a>
## 热插拔是独立场景

显示器连接场景会持续录制主屏幕。第二个虚拟显示器连接后，由独立录制器拍摄该屏幕，并在移除前停止。两路视频按各自实际的首帧时间同步。合成器将它们并排显示，未录制副屏的时间段留空。它不会复制主屏，也不会在断开后保留冻结画面。录制清单保留两个源文件的哈希及副屏录制区间。

实际线缆、扩展坞、HDR、混合 DPI 和触控板手势识别需单独硬件验证。更换虚拟机系统版本后应重新验证私有 API 兼容性。
