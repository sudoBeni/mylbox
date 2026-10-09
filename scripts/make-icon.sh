#!/bin/zsh
# Renders Resources/AppIcon.icns from Resources/AppIcon.svg (the logo source of truth).
# Needs librsvg: brew install librsvg
set -euo pipefail
cd "$(dirname "$0")/.."
SET="build/AppIcon.iconset"
rm -rf "$SET" && mkdir -p "$SET"
for size in 16 32 128 256 512; do
    rsvg-convert -w $size -h $size Resources/AppIcon.svg -o "$SET/icon_${size}x${size}.png"
    double=$((size * 2))
    rsvg-convert -w $double -h $double Resources/AppIcon.svg -o "$SET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
