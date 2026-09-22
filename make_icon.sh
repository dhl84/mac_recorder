#!/bin/bash
# Draws the app icon and builds AppIcon.icns. Run it only after you change the
# drawing. The .icns is in the repository, so a normal build needs no rsvg.
set -euo pipefail
cd "$(dirname "$0")"

python3 - <<'PY'
# Two tracks, one recording. The blue bars above the axis are the microphone.
# The amber bars below are the system output. The red bar through the middle is
# the record mark.
UP   = [(152, 120), (272, 260), (392, 180), (632, 300), (752, 200), (872, 110)]
DOWN = [(152,  90), (272, 200), (392, 300), (632, 160), (752, 260), (872, 130)]
W, R, AXIS, GAP = 72, 36, 512, 12

bars = []
for x, h in UP:
    bars.append(f'<rect x="{x - W // 2}" y="{AXIS - GAP - h}" width="{W}" height="{h}" rx="{R}" fill="#4CC2FF"/>')
for x, h in DOWN:
    bars.append(f'<rect x="{x - W // 2}" y="{AXIS + GAP}" width="{W}" height="{h}" rx="{R}" fill="#FFAE3D"/>')
bars.append(f'<rect x="{512 - W // 2}" y="192" width="{W}" height="640" rx="{R}" fill="#FF4A3D"/>')

svg = f"""<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0.35" y2="1">
      <stop offset="0" stop-color="#31405C"/>
      <stop offset="1" stop-color="#141922"/>
    </linearGradient>
  </defs>
  <rect x="0" y="0" width="1024" height="1024" rx="232" fill="url(#bg)"/>
  <rect x="8" y="8" width="1008" height="1008" rx="228" fill="none" stroke="#FFFFFF" stroke-opacity="0.08" stroke-width="16"/>
  {chr(10).join("  " + b for b in bars)}
</svg>
"""
open("Resources/icon.svg", "w").write(svg)
print("wrote Resources/icon.svg")
PY

# iOS masks the icon itself, so its source is a full square with no transparent
# corners. macOS wants the rounded shape drawn in.
python3 - <<'PY2'
import pathlib, re
svg = pathlib.Path("Resources/icon.svg").read_text()
ios = svg.replace('rx="232"', 'rx="0"')
ios = re.sub(r'\n  <rect x="8" y="8"[^\n]*\n', '\n', ios)
pathlib.Path("Resources/icon-ios.svg").write_text(ios)
PY2
rsvg-convert -w 1024 -h 1024 Resources/icon-ios.svg -o ios/App/Assets.xcassets/AppIcon.appiconset/icon1024.png
echo "wrote the iOS icon"

SET=build/AppIcon.iconset
rm -rf "$SET"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  rsvg-convert -w $size -h $size Resources/icon.svg -o "$SET/icon_${size}x${size}.png"
  rsvg-convert -w $((size * 2)) -h $((size * 2)) Resources/icon.svg -o "$SET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
