#!/usr/bin/env bash
# Generate the full app-icon set (PNG 16–512, multi-size .ico, .icns) from a source.
# Priority: a user-supplied raster (source-favicon.ico / source.png / source.ico),
# otherwise the vector icon.svg (best quality — no upscaling loss).
# Requires ImageMagick v7 (`magick`) + Python Pillow.
set -e
cd "$(dirname "$0")"

SRC=""
for c in source-favicon.ico source.png source.ico source-favicon.png; do
  [ -f "$c" ] && SRC="$c" && break
done

if [ -n "$SRC" ]; then
  echo "source: $SRC (raster — Lanczos upscale to 1024 master)"
  magick "${SRC}[0]" -background none -alpha on \
    -filter Lanczos -resize 1024x1024 -unsharp 0x0.75+0.75+0.008 -strip icon-1024.png
else
  echo "source: icon.svg (vector — true high-res master)"
  magick -background none -density 512 icon.svg -resize 1024x1024 -strip icon-1024.png
fi

for s in 16 24 32 48 64 128 256 512; do
  magick icon-1024.png -filter Lanczos -resize ${s}x${s} -unsharp 0x0.5+0.5+0.005 -strip icon-${s}.png
done
cp icon-512.png icon.png
magick icon-256.png icon-128.png icon-64.png icon-48.png icon-32.png icon-24.png icon-16.png icon.ico
python3 - <<'PY'
from PIL import Image
Image.open("icon-1024.png").convert("RGBA").save("icon.icns", format="ICNS")
PY
rm -f icon-1024.png
echo "generated: icon.png icon.ico icon.icns icon-{16,24,32,48,64,128,256,512}.png"
