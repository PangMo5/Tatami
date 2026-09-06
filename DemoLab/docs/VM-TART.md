# Recording in a Tart VM

The dedicated `tatami-demo` guest isolates personal windows, preferences and
permissions from the shoot. Current captures use macOS 26.6.2, a fixed
1920×1200 primary display, the installed Tatami app, and eight fixture apps.
A guest-side virtual display provides a second real screen; see
[MULTI-DISPLAY.md](MULTI-DISPLAY.md).

## Prepare the guest

The host needs Apple silicon and Tart with `exec` support. The guest needs the
Tart agent, Command Line Tools, Python 3, and a copy of Tatami. Run commands
from `DemoLab/` unless a command explicitly enters the guest.

```sh
./vm/tart/host-bootstrap.sh
```

Bootstrap fixes the display at `1920x1200px` with `--no-display-refit`, so moving
the host's VM window cannot change the recording canvas. The lab share mounts
at `/Volumes/My Shared Files/demolab`.

Provide the Tatami build you want to demonstrate through a separate share:

```sh
# Include both shares when starting the dedicated VM.
tart run tatami-demo --dir="demolab:$PWD" --dir="tatami:/Applications"

# From a separate host terminal:
tart exec tatami-demo /bin/bash -lc \
  'TATAMI_APP="/Volumes/My Shared Files/tatami/Tatami.app" \
   "/Volumes/My Shared Files/demolab/vm/tart/guest-provision.sh"'
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
./vm/tart/sync.sh

# Guest: each scene gets fresh lab data and preferences suppression.
tart exec tatami-demo /bin/bash -lc \
  'cd ~/DemoLab && python3 scripts/capture.py --continue-on-error \
   --output /Users/admin/DemoLab/recordings/review-batch'

# Host: a new destination, retaining originals and all provenance sidecars.
GUEST_DIR=DemoLab/recordings/review-batch \
  ./vm/tart/fetch-recordings.sh recordings/review-batch

python3 scripts/export.py --takes recordings/review-batch \
  --output ~/Downloads/TatamiDemoLab-review
```

Use `--scenes tour cli desk` to rehearse a subset. Capture never overwrites an
existing take. `--continue-on-error` preserves failures, cleans between scenes,
and exits nonzero if any scene failed. `capture-report.json` names every result.
Only passed takes matching the current scene bytes can enter the exporter.

Avoid heavy host encoding or compilation while recording. The VM and host
share CPU resources, and dropped frames are measured per display. Encode after
the capture finishes.

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
tart exec tatami-demo /bin/bash -lc \
  'cd ~/DemoLab && ./bin/democtl quit && ./bin/democtl display disconnect && ./bin/democtl restore'
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
