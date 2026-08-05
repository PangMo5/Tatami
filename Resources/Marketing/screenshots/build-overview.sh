#!/usr/bin/env bash
# Rebuilds overview.png, the README's screenshot cascade: the three captures
# stacked with an overlap so each one renders larger than a side-by-side row
# allows. Guided Setup sits in front, then workspace settings, then borrow at
# the back. Transparent background and soft shadows, so it reads on GitHub's
# light and dark themes.
#
# Requires ImageMagick 7 (`brew install imagemagick`). Run after replacing any
# of the source captures:
#
#   ./Resources/Marketing/screenshots/build-overview.sh
set -euo pipefail
cd "$(dirname "$0")"

H=1000    # card height for the full-screen captures
R=24      # corner radius
YSTEP=620 # vertical cascade step: how much of each card stays uncovered
XOFF=110  # horizontal drift per step

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Rounded corners + a drop shadow for an opaque full-screen capture.
card() {
  local src=$1 out=$2 w
  magick "$src" -resize "x${H}" -depth 8 -strip "$TMP/flat.png"
  w=$(magick identify -format %w "$TMP/flat.png")
  magick -size "${w}x${H}" xc:black -fill white \
    -draw "roundrectangle 0,0,$((w - 1)),$((H - 1)),$R,$R" -alpha off "$TMP/mask.png"
  magick "$TMP/flat.png" "$TMP/mask.png" -alpha off -compose CopyOpacity -composite "$TMP/round.png"
  magick "$TMP/round.png" \( +clone -background black -shadow 45x26+0+14 \) \
    +swap -background none -layers merge +repage "$out"
}

card workspaces.png "$TMP/ws.png"
card borrow.png "$TMP/bw.png"

card_w=$(magick identify -format %w "$TMP/ws.png")
card_h=$(magick identify -format %h "$TMP/ws.png")

# Guided Setup is already a transparent window capture with its own shadow, so
# it only needs trimming and scaling to the card width.
magick guided-setup.png -trim +repage -resize "${card_w}x" -depth 8 -strip "$TMP/guide.png"
guide_h=$(magick identify -format %h "$TMP/guide.png")

# Composited back to front, so Guided Setup ends up on top and fully visible
# while the two desktop captures recede behind it.
magick -size "$((card_w + XOFF * 2 + 60))x$((YSTEP * 2 + card_h + guide_h + 60))" xc:none \
  "$TMP/bw.png" -geometry "+0+0" -composite \
  "$TMP/ws.png" -geometry "+${XOFF}+${YSTEP}" -composite \
  "$TMP/guide.png" -geometry "+$((XOFF * 2))+$((YSTEP * 2))" -composite \
  -trim +repage -bordercolor none -border 20 \
  -define png:compression-level=9 overview.png

magick identify -format "Built %f  %wx%h  %B bytes\n" overview.png
