<!-- LANGUAGE-LINKS:START -->
[English](MULTI-DISPLAY.md) · [한국어](ko/MULTI-DISPLAY.md) · [日本語](ja/MULTI-DISPLAY.md) · [简体中文](zh-Hans/MULTI-DISPLAY.md) · [繁體中文](zh-Hant/MULTI-DISPLAY.md)
<!-- LANGUAGE-LINKS:END -->

# Multiple displays inside the recording VM

The macOS 26.6.2 Tart guest can create an additional **guest-side CoreGraphics
virtual display**. This is different from adding a second graphics display to
the host's `VZMacGraphicsDeviceConfiguration`.

The previous document incorrectly treated the VZ hardware-display limit as a
limit on every display a guest can create. The guest-side route has now been
verified: macOS enumerated two active 1920×1200 displays, Tatami placed Review on
the primary and Chat on the secondary through a workspace chain, and
ScreenCaptureKit recorded both screens into independent playable movies.

## Reproduce

Inside the dedicated guest:

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

The helper uses private `CGVirtualDisplay` interfaces only in Demo Lab, never in
the Tatami app. Its API reference is
[DeskPad's CoreGraphics bridge](https://github.com/Stengo/DeskPad/blob/main/DeskPad/CGVirtualDisplayPrivate.h).
It creates a 1920×1200 non-HiDPI screen and remains alive until disconnected or
its bounded lifetime ends. The controller checks the PID's executable before
signalling it. A missing or unsupported helper fails explicitly.

## Synchronization and composition

`--display all` writes one original per display. Each output records its actual
first-frame offset against the common monotonic clock, display origin and its
own frame/drop counts. After fetching the batch to the host:

```sh
Tools/.build/release/tatami-tools compose-displays DemoLab/recordings desk
```

The compositor orders screens by physical origin and aligns the streams using
those recorded offsets. It retains the two originals and creates a lossless
intermediate. The exporter presents it as a wide two-screen video with the same
Tatami palette as the single-screen films. It does not invent the second screen
by duplicating or animating a screenshot.

## Hotplug is a separate scene

The hotplug scene records the main screen continuously. Once the second virtual
display is connected, a separate recorder captures it until just before removal.
Both streams use their actual first-frame clocks. The compositor places them
side by side and leaves the second region blank outside its captured interval.
It never duplicates the main screen or keeps a frozen screen after disconnection.
The capture manifest retains both source hashes and the secondary interval.

Physical monitor cables, docking hardware, HDR behavior, mixed DPI hardware,
and actual trackpad gesture recognition remain separate hardware checks.
Private CoreGraphics compatibility must be rechecked on a new guest OS version.
