#!/usr/bin/env bash
# Doom 64 - Ray Traced : Linux build + stage.
#
# The Linux counterpart of tools/build-gzdoom-rt.cmd + tools/build-rtgl.cmd.
# One difference in layout, on purpose: on Linux the engine carries RTGL as its
# libraries/RTGL submodule (the acolomba/gzdoom-rt arrangement), so there is no
# deps/RTGL clone and no deps/DLSS requirement -- native DLSS is optional and
# comes from D64RT_DLSS_SDK when set.
#
# Inputs:
#   sourcecode/gzdoom-rt   engine checkout. Clone it with:
#       git clone --recurse-submodules -b doom64-rt-linux \
#           https://github.com/acolomba/gzdoom-rt.git sourcecode/gzdoom-rt
#   D64RT_STOCK_RT         the stock gzdoom-rt 1.0.2 release rt/ directory
#                          (unzip gzdoom-rt-1.0.2.zip and point this at its rt/).
#                          Same role as gzdoom-rt-1.0.2\ in the Windows build.
#   D64RT_DLSS_SDK         optional NVIDIA DLSS SDK checkout for native DLSS.
#
# Output: build/linux/stage/ -- a complete runnable bundle (also the AppDir
# payload for tools/appimage/build-appimage.sh):
#   gzdoom, *.pk3, soundfonts/, fm_banks/, libzmusic.so*
#   rt/        stock tree minus the parts this project never loads,
#              + RTGL1.json, + authored materials, + rt-wad-overlay, + fresh
#              shaders, + rt/bin/libRTGL1.so
#   mods/      the Retribution RT patch set + d64rt-pins.cfg
#   launch-doom64-rt.sh
set -euo pipefail

PROJ="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$PROJ/sourcecode/gzdoom-rt"
STAGE="$PROJ/build/linux/stage"

# Homebrew-provided deps (SDL2, X11, glslc) when present, same as the engine's
# own tools/appimage/build-appimage.sh.
if command -v brew >/dev/null; then
    brew_prefix="$(brew --prefix)"
    export CMAKE_PREFIX_PATH="$brew_prefix${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
    export PKG_CONFIG_PATH="$brew_prefix/lib/pkgconfig:$brew_prefix/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
fi

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -e "$ROOT/libraries/RTGL/Include/RTGL1/RTGL1.h" ]] || die \
"engine checkout missing or cloned without submodules at $ROOT
Clone it with:
  git clone --recurse-submodules -b doom64-rt-linux https://github.com/acolomba/gzdoom-rt.git \"$ROOT\""

STOCK_RT="${D64RT_STOCK_RT:-$PROJ/gzdoom-rt-1.0.2/rt}"
[[ -e "$STOCK_RT/data/textures.json" ]] || die \
"stock rt/ tree not found at $STOCK_RT
Download gzdoom-rt-1.0.2.zip from https://github.com/vs-shirokii/gzdoom-rt/releases,
unzip it, and set D64RT_STOCK_RT to its rt/ directory."

# Build dirs -- overridable so a developer can reuse an existing engine build.
ZMUSIC_BUILD="${D64RT_ZMUSIC_BUILD:-$ROOT/build/linux/zmusic}"
RTGL_BUILD="${D64RT_RTGL_BUILD:-$ROOT/build/linux/rtgl}"
GAME_BUILD="${D64RT_GAME_BUILD:-$ROOT/build/linux/game}"

x11_cxx_flags="$(pkg-config --cflags x11 xcb xau xdmcp 2>/dev/null | sed 's/-I/-isystem /g' || true)"
if command -v brew >/dev/null && [[ -d "$(brew --prefix xorgproto 2>/dev/null)/include" ]]; then
    x11_cxx_flags="$x11_cxx_flags -isystem $(brew --prefix xorgproto)/include"
fi

# --- 1. shaders --------------------------------------------------------------
# The merged renderer changed many shaders, so the stock release SPIR-V is
# stale; regenerate the whole set. GenerateShaders.py exits 0 even when a
# shader fails, so grep the log -- same guard as build-rtgl.cmd, for the same
# reason: a compile error must not sail through to a playtest of the OLD spv.
echo "=== Generating RTGL shaders ==="
shaderlog="$(mktemp)"
( cd "$ROOT/libraries/RTGL/Source/Shaders" && python3 GenerateShaders.py -g ) > "$shaderlog" 2>&1 || {
    cat "$shaderlog"; die "shader generation failed"; }
if grep -qi "error:" "$shaderlog"; then
    cat "$shaderlog"
    die "a shader failed to compile; refusing to stage the old SPIR-V"
fi
tail -1 "$shaderlog"

echo "=== Checking ShGlobalUniform layout ==="
D64RT_RTGL_DIR="$ROOT/libraries/RTGL" python3 "$PROJ/tools/check_uniform_layout.py"

# --- 2. ZMusic ---------------------------------------------------------------
if [[ ! -e "$ZMUSIC_BUILD/source/libzmusic.so" ]]; then
    echo "=== Building ZMusic ==="
    cmake -S "$ROOT/libraries/ZMusic" -B "$ZMUSIC_BUILD" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DZMUSIC_INSTALL=OFF
    cmake --build "$ZMUSIC_BUILD" --parallel
fi

# --- 3. RTGL -----------------------------------------------------------------
if [[ ! -e "$RTGL_BUILD/libRTGL1.so" ]]; then
    echo "=== Building RTGL ==="
    rtgl_options=(
        -DCMAKE_BUILD_TYPE=Release
        -DRG_WITH_SURFACE_XLIB=ON
        -DRG_WITH_SURFACE_WAYLAND=OFF
        -DRG_WITH_DX12=OFF
        -DRG_WITH_IMGUI=OFF
        -DRG_WITH_EXAMPLES=OFF
        "-DCMAKE_CXX_FLAGS=$x11_cxx_flags"
    )
    if [[ -n "${D64RT_DLSS_SDK:-}" ]]; then
        [[ -e "$D64RT_DLSS_SDK/include/nvsdk_ngx.h" ]] || die "D64RT_DLSS_SDK has no include/nvsdk_ngx.h"
        rtgl_options+=(-DRG_WITH_NATIVE_DLSS=ON "-DDLSS_SDK_PATH=$D64RT_DLSS_SDK")
    else
        rtgl_options+=(-DRG_WITH_NATIVE_DLSS=OFF)
    fi
    CC="${RTGL_CC:-gcc}" CXX="${RTGL_CXX:-g++}" \
        cmake -S "$ROOT/libraries/RTGL" -B "$RTGL_BUILD" -G Ninja "${rtgl_options[@]}"
    cmake --build "$RTGL_BUILD" --parallel
fi

# --- 4. engine ---------------------------------------------------------------
if [[ ! -e "$GAME_BUILD/gzdoom" ]]; then
    echo "=== Building gzdoom-rt ==="
    RTGL1_SDK_PATH="$ROOT/libraries/RTGL" cmake -S "$ROOT" -B "$GAME_BUILD" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DHAVE_RT=ON \
        -DPK3_QUIET_ZIPDIR=ON \
        -DZMUSIC_INCLUDE_DIR="$ROOT/libraries/ZMusic/include" \
        -DZMUSIC_LIBRARIES="$ZMUSIC_BUILD/source/libzmusic.so" \
        -DCMAKE_BUILD_RPATH='$ORIGIN' \
        -DINSTALL_RPATH='$ORIGIN' \
        "-DCMAKE_CXX_FLAGS=$x11_cxx_flags"
    cmake --build "$GAME_BUILD" --parallel
fi

# --- 5. stage ----------------------------------------------------------------
echo "=== Staging $STAGE ==="
mkdir -p "$STAGE"

cp "$GAME_BUILD/gzdoom" "$STAGE/"
cp "$GAME_BUILD/"*.pk3 "$STAGE/"
cp -a "$GAME_BUILD/soundfonts" "$GAME_BUILD/fm_banks" "$STAGE/"
cp -a "$ZMUSIC_BUILD/source/libzmusic.so"* "$STAGE/"

# dlopen("libopenal.so.1") honors the binary's RUNPATH, and a Homebrew
# toolchain leaves its lib dir in there -- shadowing the system's
# PipeWire-enabled OpenAL with brew's, which cannot open an audio device.
# The launcher puts the stage root on LD_LIBRARY_PATH (searched before
# RUNPATH), so a symlink to the system library wins. The AppImage is
# unaffected: CI has no brew and bundles libopenal1 from apt.
if command -v brew >/dev/null; then
    for sysdir in /usr/lib64 /usr/lib/x86_64-linux-gnu; do
        if [[ -e "$sysdir/libopenal.so.1" ]]; then
            ln -sf "$sysdir/libopenal.so.1" "$STAGE/libopenal.so.1"
            break
        fi
    done
fi

# Stock rt/ minus what this project never loads (see build-gzdoom-rt.cmd for
# the accounting: replace/ scenes/ bin_remix/ filter/ sounds/ are 2.2 GB of
# Doom II payload). bin/ additionally holds only Windows DLLs.
if [[ ! -e "$STAGE/rt/data/textures.json" ]]; then
    echo "=== Staging stock rt/ from $STOCK_RT ==="
    mkdir -p "$STAGE/rt"
    if command -v rsync >/dev/null; then
        rsync -a \
            --exclude=/replace --exclude=/replace_old \
            --exclude=/scenes --exclude=/scenes_doom2_backup \
            --exclude=/bin_remix --exclude=/bin --exclude=/launcher \
            --exclude=filter/ --exclude=sounds/ \
            "$STOCK_RT/" "$STAGE/rt/"
    else
        cp -a "$STOCK_RT/." "$STAGE/rt/"
        rm -rf "$STAGE/rt/replace" "$STAGE/rt/replace_old" "$STAGE/rt/scenes" \
               "$STAGE/rt/scenes_doom2_backup" "$STAGE/rt/bin_remix" \
               "$STAGE/rt/bin" "$STAGE/rt/launcher" \
               "$STAGE/rt/wad/filter" "$STAGE/rt/wad/sounds"
    fi
fi

# RTGL1 only ever READS rt/RTGL1.json; no file means developerMode=false and
# every authored PNG material is silently ignored.
if [[ ! -e "$STAGE/rt/RTGL1.json" ]]; then
    echo "=== Writing rt/RTGL1.json (developerMode on) ==="
    cat > "$STAGE/rt/RTGL1.json" <<'EOF'
{
  "version": 0,
  "developerMode": true,
  "vulkanValidation": false,
  "dx12Validation": false,
  "dlssValidation": false,
  "fpsMonitor": false
}
EOF
fi

echo "=== Staging authored RT materials ==="
cp -a "$PROJ/Doom64-Retribution/Retribution-RT-Materials/rt/." "$STAGE/rt/"

echo "=== Syncing rt-wad-overlay into rt/wad ==="
cp -a "$PROJ/rt-wad-overlay/." "$STAGE/rt/wad/"

echo "=== Staging fresh shaders ==="
cp -a "$ROOT/libraries/RTGL/Build/shaders/." "$STAGE/rt/shaders/"

mkdir -p "$STAGE/rt/bin"
cp "$RTGL_BUILD/libRTGL1.so" "$STAGE/rt/bin/"
if [[ -n "${D64RT_DLSS_SDK:-}" ]]; then
    # dlss = Super Resolution, dlssd = Ray Reconstruction. dlssg (frame
    # generation) is not wired up on Linux, so it stays out of the bundle.
    find "$D64RT_DLSS_SDK/lib" -type f \
        \( -name 'libnvidia-ngx-dlss.so*' -o -name 'libnvidia-ngx-dlssd.so*' \) \
        -exec cp -a {} "$STAGE/rt/bin/" \;
fi

echo "=== Staging mods/ ==="
mkdir -p "$STAGE/mods"
cp "$PROJ/Doom64-Retribution/"d64r-*.pk3 "$PROJ/Doom64-Retribution/"d64r-*.wad "$STAGE/mods/" 2>/dev/null || true
cp "$PROJ/tools/d64rt-pins.cfg" "$STAGE/mods/"

cp "$PROJ/launch-doom64-rt.sh" "$STAGE/"
chmod +x "$STAGE/launch-doom64-rt.sh" "$STAGE/gzdoom"

echo
echo "BUILD_OK $STAGE"
echo "Run:  $STAGE/launch-doom64-rt.sh   (game files go in a game/ directory beside it, see README)"
