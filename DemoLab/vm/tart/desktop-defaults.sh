#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
#
# Make the guest desktop deterministic and quiet.
#
# Two rules, both learned the hard way:
#
#   * `defaults` is cached by cfprefsd, and a running Dock/Finder/WindowManager
#     writes its own image back on quit. Every write here is followed by killing
#     the owner so the value takes.
#   * Several widely-copied settings are dead on modern macOS. They are called
#     out below rather than left in as cargo cult. In particular the Do Not
#     Disturb default has done nothing since Big Sur, and the wallpaper store
#     moved twice — the reliable answer to both is a clean account with nothing
#     installed that can post a notification, plus a snapshot.
#
# Every command reports whether it worked. Silence is not success.
set -uo pipefail

ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
skip() { printf '  \033[33mskip\033[0m  %s\n' "$*"; }
note() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

try() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "${label}"; else skip "${label} (command failed)"; fi
}

note "Dock"
try "hide the Dock"            defaults write com.apple.dock autohide -bool true
try "no autohide delay"        defaults write com.apple.dock autohide-delay -float 1000
try "no autohide animation"    defaults write com.apple.dock autohide-time-modifier -float 0
try "no recent apps"           defaults write com.apple.dock show-recents -bool false
try "no launch animation"      defaults write com.apple.dock launchanim -bool false
# Spaces reordering by use makes window placement history non-reproducible.
try "fixed Space order"        defaults write com.apple.dock mru-spaces -bool false
try "no Space auto-switch"     defaults write com.apple.dock workspaces-auto-swoosh -bool false
for corner in tl tr bl br; do
  try "disable hot corner ${corner}" defaults write com.apple.dock "wvous-${corner}-corner" -int 0
done
killall Dock 2>/dev/null && ok "restarted Dock" || skip "Dock was not running"

note "Desktop and windows"
try "hide desktop icons"       defaults write com.apple.finder CreateDesktop -bool false
# Sonoma and later: clicking the wallpaper sweeps every window aside. On camera
# that looks exactly like a window manager bug.
try "no click-to-show-desktop" defaults write com.apple.WindowManager EnableStandardClickToShowDesktop -bool false
try "Stage Manager off"        defaults write com.apple.WindowManager GloballyEnabled -bool false
try "no window animations"     defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false
try "instant window resize"    defaults write NSGlobalDomain NSWindowResizeTime -float 0.001
# Overlay scrollbars fade on a timer, so two takes of the same window differ.
try "always show scrollbars"   defaults write NSGlobalDomain AppleShowScrollBars -string "Always"
try "no reopen-windows prompt" defaults write NSGlobalDomain NSQuitAlwaysKeepsWindows -bool false
killall Finder 2>/dev/null && ok "restarted Finder" || skip "Finder was not running"
killall WindowManager 2>/dev/null && ok "restarted WindowManager" || skip "WindowManager was not running"

note "Menu bar clock"
# A seconds display changes every frame and defeats frame-level comparison.
try "hide seconds"             defaults write com.apple.menuextra.clock ShowSeconds -bool false
try "hide the date"            defaults write com.apple.menuextra.clock ShowDate -int 2
killall SystemUIServer 2>/dev/null && ok "restarted SystemUIServer" || skip "SystemUIServer was not running"

note "Sleep and screen saver"
# `caffeinate` is the primary mechanism: it behaves the same across releases,
# while the screen-saver defaults have regressed more than once. It is left
# running detached and dies with the VM.
if pgrep -f "caffeinate -dimsu" >/dev/null; then
  ok "caffeinate already running"
else
  nohup caffeinate -dimsu >/dev/null 2>&1 &
  ok "caffeinate started"
fi
try "no screen saver"          defaults -currentHost write com.apple.screensaver idleTime -int 0
if sudo -n true 2>/dev/null; then
  try "no display/system sleep" sudo pmset -a displaysleep 0 sleep 0 disksleep 0
else
  skip "pmset (needs sudo; run 'sudo pmset -a displaysleep 0 sleep 0 disksleep 0' once)"
fi

note "Software update"
if sudo -n true 2>/dev/null; then
  try "no automatic checks"    sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
  try "no automatic download"  sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
  try "no automatic install"   sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
  try "no App Store updates"   sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false
  try "unschedule updates"     sudo softwareupdate --schedule off
else
  skip "software update settings (need sudo)"
fi

note "Spotlight"
# mdutil needs Full Disk Access on macOS 13+ and fails with "Operation not
# permitted" without it, even as root. That is fine: indexing only matters
# because of the menu bar spinner, which a snapshot settles anyway.
if sudo -n true 2>/dev/null; then
  try "disable indexing"       sudo mdutil -a -i off
else
  skip "mdutil (needs sudo, and Full Disk Access on macOS 13+)"
fi

note "Not attempted on purpose"
cat <<'EOF'
  Do Not Disturb  The `com.apple.notificationcenterui doNotDisturb` default has
                  been inert since Big Sur; Focus replaced it and has no
                  supported scripting hook. The reliable fix is a clean account
                  with no mail, no calendar and no login items, which is what a
                  demo VM already is.
  Wallpaper       The store moved to WallpaperAgent in Sonoma and again into a
                  container in macOS 26. Set it once in System Settings and
                  snapshot; scripting it breaks on every other release.
  Screen capture  TCC cannot be granted from a script under SIP, and Apple
                  documents that a configuration profile can only *deny* screen
                  capture. See docs/PERMISSIONS.md.
EOF

note "Done"
echo "Log out and back in (or snapshot and restore) so every setting is picked up cleanly."
