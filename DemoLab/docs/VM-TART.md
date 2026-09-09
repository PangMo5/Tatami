# Recording in a Tart VM

The dedicated `tatami-demo` guest isolates personal windows, preferences and
permissions from the shoot. Current captures use macOS 26.6.2, a fixed
1920×1200 primary display, the installed Tatami app, and eight fixture apps.
A guest-side virtual display provides a second real screen; see
[MULTI-DISPLAY.md](MULTI-DISPLAY.md).

## Prepare the guest

The host needs Apple silicon, Swift 6.2+ and Tart with `exec` support. The guest
needs the Tart agent, Command Line Tools and a copy of Tatami. Run host commands
from the repository root; guest commands use `~/DemoLab`.

```sh
swift build --package-path Tools -c release
Tools/.build/release/tatami-tools vm-bootstrap
```

Bootstrap fixes the display at `1920x1200px` with `--no-display-refit`, so moving
the host's VM window cannot change the recording canvas. The lab share mounts
at `/Volumes/My Shared Files/demolab`.

Place the Tatami build in the lab share before provisioning:

```sh
ditto /Applications/Tatami.app DemoLab/.build/Tatami.app
TATAMI_APP="/Volumes/My Shared Files/demolab/.build/Tatami.app" \
  Tools/.build/release/tatami-tools vm-provision
```

Provisioning accepts `TATAMI_DMG` instead of `TATAMI_APP` as well. SwiftPM builds
on the guest's local disk, not the shared filesystem. App bundling registers
every fixture with LaunchServices so Tatami can resolve assigned bundle IDs.

Open the guest through its VM window or Screen Sharing. Grant missing access
through System Settings, following [PERMISSIONS.md](PERMISSIONS.md). Test both
the recorder and Tatami's Always on Top path. The current agent launch path
has capture/input access; a new image or launcher must be checked separately.
Do not edit TCC database rows or treat a recorder-only warm-up as proof of
Tatami's mirroring permission.

## Record an explicit batch

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

Use `--scenes tour cli desk` to rehearse a subset. Capture never overwrites an
existing take. `--continue-on-error` preserves failures, cleans between scenes,
and exits nonzero if any scene failed. `capture-report.json` names every result.
Only passed takes matching the current scene bytes can enter the exporter.

Avoid heavy host encoding or compilation while recording. The VM and host
share CPU resources, and dropped frames are measured per display. Encode after
the capture finishes.

## Rendering health and VM ownership

Select the recording VM by its exact configured name. Other projects can use Tart at the same time. Inspect the VM inventory and confirm which task owns the target before stopping or restarting it; never select the first running VM or terminate all Tart processes. Preserve the target VM's shares, display settings, and in-flight capture files.

Before a batch, exercise both a scrolling Guided Setup preview and a confirmation HUD entering, changing content, and disappearing. Inspect the transitions frame by frame in a short recording, not only settled screenshots. Repeat this check after a graphics error or a change to the VM session. An idle-screen recorder warm-up does not cover these paths.

If a preview, material, or HUD becomes black or magenta, reject the take and preserve the original movie, scene, timestamps, and VM logs. Compare the camera original with the export, and obtain separate PNG screenshots inside the guest. When possible, reproduce the same scene with a previously known app build. These comparisons distinguish export defects from failures already present in the VM's graphics or capture path.

Check the guest's WindowServer and application logs for GPU hangs or aborted Metal command buffers. Finish or abort the recording cleanly before restarting only the owned VM. Then repeat the same scrolling and HUD transitions before starting another batch. Restart recovery is evidence about the VM session, not proof that a particular app change or concurrent VM caused the failure.

Do not hide corruption by cropping frames, disabling product effects, or repeatedly recording until a sampled still happens to look correct. A restart or a windowed launch is not an acceptance check by itself. Decoder success, OCR success, low frame loss, and passing state assertions can all coexist with visibly corrupt content. Reject even brief black remnants during appearance, scrolling, resizing, and dismissal.

Use the owned VM's name explicitly when collecting graphics diagnostics:

```sh
tart list
tart exec tatami-demo /usr/bin/log show --last 15m --style compact \
  --predicate '(process == "WindowServer" OR process == "Tatami") AND (eventMessage CONTAINS[c] "GPU" OR eventMessage CONTAINS[c] "Metal")'
```

## Shared-filesystem correctness

Both directions use a uniquely named archive. Rewriting the same file through
virtiofs was observed to expose stale bytes or a stale inode after the host
moved an earlier take. A new archive name removes that reuse path.

Source sync mirrors only managed source directories, so deleted Swift files
cannot survive in the guest. It preserves `.build` and recordings. Fetch proves
the share identity with a unique marker, compares guest/host archive SHA256,
and extracts into a new local destination. It includes movies, captions,
timeline, take metadata, frozen scene JSON and the batch report.

## Finish or preserve the image

```sh
tart exec tatami-demo /Users/admin/DemoLab/.build/DemoLab/bin/democtl quit
tart exec tatami-demo /Users/admin/DemoLab/.build/DemoLab/bin/democtl display disconnect
tart exec tatami-demo /Users/admin/DemoLab/.build/DemoLab/bin/democtl restore
```

`restore` returns the preferences domain backed up before the recording session.
Original personal-host Tatami preferences are not involved. A stopped, verified
guest can be preserved with `tart clone`; keep originals and evidence outside
the VM before retiring any recording image.

## Verified boundary

The v4 batch proves real ScreenCaptureKit capture, actual input/AX readback,
Tatami tiling/Borrow, two independently captured guest displays, workspace
chains, and profile activation on display connect/disconnect. Hardware docks,
physical gesture recognition, mixed-DPI/HDR monitors and new guest OS versions
need their own checks. Native macOS fullscreen restoration has a separate
failed reproduction documented in [COVERAGE.md](COVERAGE.md).
