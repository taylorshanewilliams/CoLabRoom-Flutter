#!/usr/bin/env bash
# Rasterizes assets/icon/launcher_icon.svg into every legacy mipmap density
# Android's launcher expects. Run from the repo root after android/ exists
# (scaffolded or checked in). Requires rsvg-convert.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RES="$ROOT/android/app/src/main/res"
ICON_SVG="$ROOT/assets/icon/launcher_icon.svg"

declare -A SIZES=( [mdpi]=48 [hdpi]=72 [xhdpi]=96 [xxhdpi]=144 [xxxhdpi]=192 )

for density in "${!SIZES[@]}"; do
  size="${SIZES[$density]}"
  dir="$RES/mipmap-$density"
  mkdir -p "$dir"
  rsvg-convert -w "$size" -h "$size" "$ICON_SVG" -o "$dir/ic_launcher.png"
  echo "Wrote $dir/ic_launcher.png (${size}x${size})"
done
