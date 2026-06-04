#!/usr/bin/env bash
# Build the Tatami Demo helper apps — standalone, dependency-free SwiftUI apps
# used only to record promo footage. No Xcode/Tuist project: just swiftc + a
# hand-assembled .app bundle, fully isolated from the product.
#
# Ships FOUR apps (Terminal / Code / Safari / Notes) from one binary, each with
# a distinct bundle id, so Tatami can assign them to different workspaces and
# the full website demo flow (tiling + workspace switching + floating) works.
set -euo pipefail
cd "$(dirname "$0")"

rm -rf build
mkdir -p build

# Compile the sources once into a shared binary; each app copies it and picks
# its panel from the bundle's TatamiDemoPanel Info.plist key.
ARCH="$(uname -m)"
swiftc Sources/*.swift \
  -o build/tatami-demo \
  -target "${ARCH}-apple-macos14.0" \
  -framework AppKit -framework SwiftUI \
  -O

make_app() {
  local kind="$1" name="$2"
  local app="build/${name}.app"
  mkdir -p "${app}/Contents/MacOS"
  cp build/tatami-demo "${app}/Contents/MacOS/${name}"
  cat > "${app}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${name}</string>
  <key>CFBundleDisplayName</key><string>${name}</string>
  <key>CFBundleIdentifier</key><string>dev.PangMo5.TatamiDemo.${kind}</string>
  <key>CFBundleExecutable</key><string>${name}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>TatamiDemoPanel</key><string>${kind}</string>
</dict>
</plist>
PLIST
  # Ad-hoc sign so it launches without Gatekeeper friction on this machine.
  codesign --force --sign - "${app}" >/dev/null 2>&1 || true
  echo "Built ${app}  (dev.PangMo5.TatamiDemo.${kind})"
}

make_app terminal Terminal
make_app code Code
make_app safari Safari
make_app notes Notes
make_app figma Figma
make_app photos Photos
make_app messages Messages
make_app mail Mail
make_app calendar Calendar

rm -f build/tatami-demo
echo
echo "Open a workspace's apps, e.g. Code:"
echo "  open build/Terminal.app build/Code.app build/Safari.app build/Notes.app"
