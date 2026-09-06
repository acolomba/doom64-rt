#!/usr/bin/env bash
# Package build/linux/stage into a self-contained Doom64-RT AppImage.
# Runs tools/build-linux.sh first (a no-op when everything is already built).
#
# Usage: tools/appimage/build-appimage.sh [version]
# Env:   the same D64RT_* variables tools/build-linux.sh takes.
set -euo pipefail

PROJ="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$PROJ"

version="${1:-dev}"
stage="$PROJ/build/linux/stage"
app_dir="$PROJ/AppDir"
dist_dir="$PROJ/dist"

command -v appimage-builder >/dev/null || {
    echo "appimage-builder is required (pip install appimage-builder 'packaging==21.3')." >&2
    exit 1
}

tools/build-linux.sh

rm -rf "$app_dir" "$dist_dir"
mkdir -p "$app_dir" "$dist_dir"
cp -a "$stage/." "$app_dir/"

# The desktop icon, from the same .ico the Windows build stamps onto the exe.
icon_dir="$app_dir/usr/share/icons/hicolor/256x256/apps"
mkdir -p "$icon_dir"
convert "Doom64-Retribution/d64rtr.ico[0]" -flatten -resize 256x256 "$icon_dir/d64rt_icon.png"

cp tools/appimage/AppImageBuilder.yml "$PROJ/AppImageBuilder.yml"
appimage-builder --skip-tests
rm -f "$PROJ/AppImageBuilder.yml"

image="$(find . -maxdepth 1 -type f -name '*.AppImage' -print -quit)"
[[ -n "$image" ]] || { echo "appimage-builder did not produce an AppImage." >&2; exit 1; }
mv "$image" "$dist_dir/doom64-rt-${version}-x86_64.AppImage"
echo "OK $dist_dir/doom64-rt-${version}-x86_64.AppImage"
