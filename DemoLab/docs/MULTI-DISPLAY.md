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
./scripts/build-virtual-display.sh
./bin/democtl display connect
./bin/democtl displays
./bin/democtl reset
./bin/democtl seed
./bin/democtl take desk --display all --output recordings/desk.mov
./bin/democtl quit
./bin/democtl display disconnect
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
python3 scripts/compose-displays.py recordings desk
```

The compositor orders screens by physical origin and aligns the streams using
those recorded offsets. It retains the two originals and creates a lossless
intermediate. The exporter presents it as a wide two-screen video with the same
Tatami palette as the single-screen films. It does not invent the second screen
by duplicating or animating a screenshot.

## Hotplug is a separate scene

`hotplug` captures only the primary screen while the helper connects and
disconnects the secondary. These are real display-topology changes, so Tatami's
display-count rules activate Desk and Laptop automatically. Recording the
removed display itself would stop its capture stream; the primary-only capture
is deliberate.

Physical monitor cables, docking hardware, HDR behavior, mixed DPI hardware,
and actual trackpad gesture recognition remain separate hardware checks.
Private CoreGraphics compatibility must be rechecked on a new guest OS version.
