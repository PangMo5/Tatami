# Troubleshooting

## A floating control disappears or brings its app back

Some apps keep a meeting recorder or Picture-in-Picture surface in the same
process as their ordinary windows. When Tatami switches away from that app's
workspace, the normal macOS hide operation also hides the floating surface.
The control can disappear, or the app may reactivate itself afterward and
bring its ordinary window or Tatami workspace back into view.

Common candidates include:

- Notion while AI Meeting Notes is recording
- Picture-in-Picture in browsers such as Google Chrome and Dia

Register the app as a visibility exception:

1. Open **Settings → Workspaces** and scroll to
   **Apps With Floating Controls**.
2. Click **+** and choose the running app. Use **Choose from Files…** if the
   app is not running.
3. Keep the app's regular workspace assignment unchanged. This setting is
   narrower than adding the app to Shared Apps.

Tatami does not exempt a registered app from hiding all the time. During a
workspace or Borrow visibility change, it preserves the process only when the
app owns an on-screen, top-level control outside the normal WindowServer layer.
While preserved, the app's ordinary windows remain alive but stay out of
Tatami focus automation, app / window switching, layout, drag, and membership
actions. They can remain behind tiled windows or appear in Mission Control.

When no qualifying control remains, the next visibility change uses normal
workspace hiding again. Apps whose control is off-screen, transparent, on the
normal window layer, owned by a helper process, or not exposed as a top-level
Accessibility window do not qualify.

> [!NOTE]
> Picture-in-Picture being tiled is a separate issue. Tatami automatically
> excludes nonzero-layer PiP surfaces from tiling; no app registration is
> needed for that. Register the browser only when switching workspaces hides
> its PiP surface along with the browser process.

If you manage `config.toml` directly, use the app's exact bundle identifier:

```toml
[settings.visibility]
overlayAwareApps = [
  "notion.id",
  "com.google.Chrome",
  "company.thebrowser.dia",
]
```

If the control still disappears, enable **Settings → General → Debug Logging**,
reproduce one workspace switch, and inspect `~/.config/tatami/tatami.log` for
an `OverlayAware evaluate ... preserve=` entry. A `preserve=false` result means
the current control did not satisfy the conditions above.
