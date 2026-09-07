<!-- LANGUAGE-LINKS:START -->
[English](PERMISSIONS.md) · [한국어](ko/PERMISSIONS.md) · [日本語](ja/PERMISSIONS.md) · [简体中文](zh-Hans/PERMISSIONS.md) · [繁體中文](zh-Hant/PERMISSIONS.md)
<!-- LANGUAGE-LINKS:END -->

# Capture permissions

Check permissions through the actual launch path used for the take. A recorder
passing preflight does not establish that Tatami can tile or mirror windows.

| Process | Needed for | Evidence |
| --- | --- | --- |
| Tatami | Accessibility: move and focus real windows | Visible workspace changes and layout assertions |
| Tatami | Screen Recording: Always on Top mirrors | A shared monitor remains visible over a zoomed window |
| democtl / its launcher | Accessibility: keyboard, pointer, native controls | Real input and control-value assertions |
| DemoRecorder / its launcher | Screen Recording: capture the display | First encoded frame, finalized movie and decode validation |

Use System Settings → Privacy & Security to grant missing permissions in the
**dedicated recording VM**. Relaunch the relevant processes after changing a
grant, then run `democtl doctor` and a short take again. Do not alter the host's
permissions or its personal Tatami configuration for a VM recording.

`record start` selects direct launch when its caller already has capture access,
otherwise LaunchServices. In the current Tart guest, `tart exec` runs through a
pre-authorized agent. This is an observed property of that image and launch path;
it is not a promise about every guest or every rebuilt executable.

## A window can outlive the process that requested it

The old tour contained a `Screen Recording` dialog asking for **Tatami** access.
It was left behind a stack of app windows and appeared when those windows closed.
The earlier recorder-only preflight did not detect it. It was not evidence of a
periodic recorder reminder.

The capture gate now rejects visible permission/settings windows even when they
are occluded by another app. Resolve the identified dialog in the guest before
retrying. Closing a stale request does not grant access and must not be reported
as granting access. If the current run needs a missing grant, make that grant in
System Settings and test the relevant behavior.

A throwaway `democtl record warmup` exercises only the recorder. To exercise
Tatami's separate ScreenCaptureKit path, rehearse the `shared` scene too. Do not
crop permission UI out of footage or label an unverified take successful.

## Repeatable recording image

Build the exact tools and app bundles, resolve their permissions, verify the
actual workload, then preserve that VM image. Rebuilding or changing the launcher
can change permission attribution; verify again rather than copying database
rows or assuming an old grant still applies. The former direct-TCC-database
modification script has been removed from the lab.
