#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
#
# Builds the Demo Lab and wraps the SwiftPM executables in real `.app` bundles.
# A bare executable has no bundle identifier, no icon, and no stable TCC
# subject, so the demo apps have to be real bundles before Tatami (or the
# screen recorder) can treat them like ordinary Mac apps.
#
#   bundle-apps.sh [output-directory]
#
# Output directory resolution: first positional argument, then $DEMOLAB_OUT,
# then <package root>/.build/DemoLab.
#
# Environment:
#   DEMOLAB_OUT        default output directory
#   CODESIGN_IDENTITY  signing identity; defaults to "-" (ad hoc)

set -euo pipefail

# Mirrors Sources/DemoAppKit/DemoCatalog.swift. `democtl` cannot dump the
# catalog yet, so this table is the second copy: when an app is added there,
# add it here too. Fields: name|LSApplicationCategoryType.
DEMO_APPS=(
  "Canvas|public.app-category.graphics-design"
  "Editor|public.app-category.developer-tools"
  "Terminal|public.app-category.developer-tools"
  "Review|public.app-category.developer-tools"
  "Docs|public.app-category.reference"
  "Chat|public.app-category.social-networking"
  "Notes|public.app-category.productivity"
  "Monitor|public.app-category.developer-tools"
)

# Deliberately not `dev.PangMo5.Tatami.` — Tatami treats that exact prefix as
# itself, and a demo app must never be mistaken for the window manager.
BUNDLE_ID_PREFIX="dev.PangMo5.DemoLab"
PLAIN_TOOLS=(democtl demokey demohook)

# MARK: - Output helpers

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() {
  printf '\nbundle-apps: %s\n' "$*" >&2
  exit 1
}

# MARK: - Locate the package

# Works from any cwd, and through a symlinked invocation.
script_source="${BASH_SOURCE[0]}"
while [ -L "$script_source" ]; do
  link_dir="$(cd -P "$(dirname "$script_source")" && pwd)"
  script_source="$(readlink "$script_source")"
  case "$script_source" in
    /*) ;;
    *) script_source="$link_dir/$script_source" ;;
  esac
done
script_dir="$(cd -P "$(dirname "$script_source")" && pwd)"
package_root="$(cd -P "$script_dir/.." && pwd)"
[ -f "$package_root/Package.swift" ] || die "no Package.swift at $package_root"
cd "$package_root"

out_dir="${1:-${DEMOLAB_OUT:-$package_root/.build/DemoLab}}"
mkdir -p "$out_dir"
out_dir="$(cd -P "$out_dir" && pwd)"

build_dir="$package_root/.build"
iconsets_dir="$build_dir/iconsets"
icns_dir="$build_dir/icns"

sign_identity="${CODESIGN_IDENTITY:--}"
if [ "$sign_identity" = "-" ]; then
  sign_label="ad-hoc"
else
  sign_label="$sign_identity"
fi

# MARK: - Build

step "Building (release)"
swift build -c release || die "swift build -c release failed"
bin_path="$(swift build -c release --show-bin-path)"
[ -d "$bin_path" ] || die "cannot resolve the release bin path"
info "$bin_path"

# Compile the shared catalog once, then place it in each app that owns UI.
python3 "$package_root/scripts/compile-localization.py" --output "$out_dir/Localization"

# MARK: - Icons

icons_ok=0
icon_warning=""

step "Rendering icons"
if command -v iconutil >/dev/null 2>&1; then
  rm -rf "$iconsets_dir" "$icns_dir"
  mkdir -p "$icns_dir"
  # demoicon fails hard on an unavailable SF Symbol. Do not soften that: a
  # fallback glyph would ship a wrong-looking app into a recording.
  "$bin_path/demoicon" --all --out "$iconsets_dir" || die "demoicon failed"
  for iconset in "$iconsets_dir"/*.iconset; do
    icon_name="$(basename "$iconset" .iconset)"
    iconutil -c icns -o "$icns_dir/$icon_name.icns" "$iconset" \
      || die "iconutil failed for $iconset"
  done
  icons_ok=1
  info "$(ls -1 "$icns_dir" | wc -l | tr -d ' ') .icns files in $icns_dir"
else
  icon_warning="iconutil not found — bundles were assembled WITHOUT icons"
  cat >&2 <<'WARN'

################################################################################
##                                                                            ##
##   WARNING: `iconutil` was not found on this machine.                       ##
##                                                                            ##
##   The bundles are still assembled and fully usable, but every demo app     ##
##   will show the generic macOS placeholder icon in the Dock, the app        ##
##   switcher, and any recording made with it.                                ##
##                                                                            ##
##   Fix: install the Xcode Command Line Tools (`xcode-select --install`)     ##
##   and re-run this script.                                                  ##
##                                                                            ##
################################################################################

WARN
fi

# MARK: - Bundle assembly

plist_string() { printf '  <key>%s</key>\n  <string>%s</string>\n' "$1" "$2"; }
plist_bool() { printf '  <key>%s</key>\n  <%s/>\n' "$1" "$2"; }

SUMMARY_ROWS=()

# assemble <name> <category> <lsuielement true|false> [capture usage description]
assemble() {
  local name="$1"
  local category="$2"
  local ui_element="$3"
  local capture_usage="${4:-}"
  # The bundle identifier is normally derived from the name, but the overlay's
  # bundle is DemoOverlay.app while `DemoCatalog.overlayBundleIdentifier` says
  # `…DemoLab.Overlay`. `democtl` addresses it by that identifier to reach its
  # control socket, so a derived `…DemoLab.DemoOverlay` would make every seed
  # fail with "the overlay never answered".
  local bundle_id="${5:-$BUNDLE_ID_PREFIX.$name}"
  local bundle="$out_dir/$name.app"
  local executable="$bin_path/$name"
  local icon_state icon_file
  [ -x "$executable" ] || die "built executable missing: $executable"

  # Re-runnable: rebuild the bundle instead of layering onto a stale one, so a
  # renamed resource or a dropped key can never survive a rebuild.
  rm -rf "$bundle"
  mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
  for localization in "$out_dir/Localization/"*.lproj; do
    cp -R "$localization" "$bundle/Contents/Resources/"
  done
  cp "$executable" "$bundle/Contents/MacOS/$name"

  icon_state="no"
  icon_file=""
  if [ "$icons_ok" -eq 1 ] && [ -f "$icns_dir/$name.icns" ]; then
    cp "$icns_dir/$name.icns" "$bundle/Contents/Resources/$name.icns"
    icon_file="$name"
    icon_state="yes"
  elif [ "$ui_element" = "true" ]; then
    # An LSUIElement agent has no Dock tile and no Launchpad entry, so it has
    # nothing to show an icon on. Reported as n/a rather than a missing icon.
    icon_state="n/a"
  fi

  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0">'
    printf '%s\n' '<dict>'
    plist_string CFBundleDevelopmentRegion "en"
    plist_string CFBundleName "$name"
    plist_string CFBundleDisplayName "$name"
    plist_string CFBundleExecutable "$name"
    plist_string CFBundleIdentifier "$bundle_id"
    [ -n "$icon_file" ] && plist_string CFBundleIconFile "$icon_file"
    plist_string CFBundlePackageType "APPL"
    plist_string CFBundleShortVersionString "1.0"
    plist_string CFBundleVersion "1"
    plist_string LSMinimumSystemVersion "14.0"
    plist_string LSApplicationCategoryType "$category"
    plist_string NSPrincipalClass "NSApplication"
    plist_bool NSHighResolutionCapable "true"
    # Both false: a demo app that quits itself between takes would change the
    # window set mid-recording.
    plist_bool NSSupportsAutomaticTermination "false"
    plist_bool NSSupportsSuddenTermination "false"
    [ "$ui_element" = "true" ] && plist_bool LSUIElement "true"
    [ -n "$capture_usage" ] && plist_string NSScreenCaptureUsageDescription "$capture_usage"
    printf '%s\n' '</dict>'
    printf '%s\n' '</plist>'
  } > "$bundle/Contents/Info.plist"

  plutil -lint "$bundle/Contents/Info.plist" >/dev/null \
    || die "generated Info.plist for $name is not a valid plist"

  # Sign last, once the bundle is complete. A signing failure is fatal: an
  # unsigned or half-signed bundle is refused by Gatekeeper and by TCC.
  codesign --force --sign "$sign_identity" --timestamp=none "$bundle" \
    || die "codesign failed for $bundle (identity: $sign_identity)"

  SUMMARY_ROWS+=("$name|$bundle_id|$bundle|$icon_state|$sign_label")
  info "$name.app"
}

step "Assembling demo app bundles -> $out_dir"
for entry in "${DEMO_APPS[@]}"; do
  app_name="${entry%%|*}"
  app_category="${entry#*|}"
  assemble "$app_name" "$app_category" "false"
done

# DemoRecorder is bundled for one reason: macOS TCC keys the Screen Recording
# grant to a bundle identity, so the recorder needs a stable bundle to be
# granted *once* instead of re-prompting as an anonymous executable.
# LSUIElement keeps it out of the Dock and the app switcher, so it never
# appears in the very recording it is making.
step "Assembling DemoRecorder.app"
assemble "DemoRecorder" "public.app-category.video" "true" \
  "Demo Lab records the screen to produce Tatami demo videos."

# The narration layer: keystroke keycaps and captions drawn over the demo. It is
# LSUIElement for the same reason the recorder is, plus one of its own: an
# accessory app never takes focus, so it cannot steal a keystroke meant for
# Tatami. It is not in DEMO_APPS because it is never assigned to a workspace and
# never tiled; Tatami is told to leave it alone through
# `settings.visibility.overlayAwareApps` instead.
step "Assembling DemoOverlay.app"
assemble "DemoOverlay" "public.app-category.utilities" "true" "" "$BUNDLE_ID_PREFIX.Overlay"

# MARK: - Plain tools

step "Copying plain executables -> $out_dir/bin"
mkdir -p "$out_dir/bin"
for tool in "${PLAIN_TOOLS[@]}"; do
  [ -x "$bin_path/$tool" ] || die "built executable missing: $bin_path/$tool"
  rm -f "$out_dir/bin/$tool"
  cp "$bin_path/$tool" "$out_dir/bin/$tool"
  info "$tool"
done

# MARK: - LaunchServices registration

# Without this, Tatami's `autoOpen` cannot find the demo apps and a workspace
# activates to an EMPTY screen, silently. Tatami resolves an assigned app by
# bundle identifier through LaunchServices, and LaunchServices only knows about
# bundles it has seen — which, for apps that live in a build directory and have
# never been double-clicked, is none of them. Registering here is what makes a
# freshly provisioned machine behave like one where the apps were opened by hand.
step "Registering the bundles with LaunchServices"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$lsregister" ]; then
  for bundle in "$out_dir"/*.app; do
    [ -d "$bundle" ] || continue
    "$lsregister" -f "$bundle"
    info "$(basename "$bundle")"
  done
else
  die "lsregister not found at $lsregister; Tatami would not be able to auto-open the demo apps"
fi

# MARK: - Signing consequences

cat <<SIGNED

--------------------------------------------------------------------------------
Signed with: $sign_label

An ad-hoc signature is derived from the binary, so it CHANGES on every rebuild.
macOS keys the Screen Recording grant to that signature, which means the grant
given to DemoRecorder.app is invalidated by the next rebuild and macOS will ask
again (and silently record nothing until it is re-granted).

  Golden VM image : build ONCE, grant ONCE, then snapshot. Never rebuild inside
                    a snapshot you intend to reuse.
  Local rebuilds  : sign with a stable identity so the grant survives, e.g.
                    CODESIGN_IDENTITY="Apple Development: you@example.com" \\
                      scripts/bundle-apps.sh
--------------------------------------------------------------------------------
SIGNED

# MARK: - Summary

step "Summary"
{
  printf 'APP|BUNDLE ID|PATH|ICON|SIGNATURE\n'
  for row in "${SUMMARY_ROWS[@]}"; do
    printf '%s\n' "$row"
  done
} | column -t -s '|'

if [ -n "$icon_warning" ]; then
  printf '\n!!  %s\n' "$icon_warning"
fi
printf '\nBundles: %s\n' "$out_dir"

# Build the lab-only virtual-display helper.
"$(dirname "$0")/build-virtual-display.sh"
