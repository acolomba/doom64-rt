#!/usr/bin/env bash
# ===========================================================================
#  Doom 64 - Ray Traced : Linux launcher
#
#  The Linux port of launch-doom64-rt.cmd. Same three jobs:
#    1. find the parts the user has to supply, and explain what is missing,
#    2. pick an upscaler for the GPU that is actually installed,
#    3. write BOTH upscaler cvars -- never one. DLSS and FSR2 share a single
#       upscaler slot and FSR is applied second, so a stale rt_upscale_fsr2 in
#       the user's ini silently disables DLSS.
#
#  It runs from three layouts, checked in this order:
#    - inside the AppImage ($APPDIR set by the runtime; game files are found
#      next to the .AppImage file),
#    - the staged bundle build/linux/stage/ (gzdoom beside this script),
#    - a source checkout (engine under sourcecode/gzdoom-rt/build/linux).
#
#  Usage: launch-doom64-rt.sh [1-34|menu] [gzdoom args...]
#  Env:   D64RT_IWAD, D64RT_GAME_DIR, D64RT_UPSCALER=dlss|fsr|none,
#         D64RT_SPIKE_MS / D64RT_SPIKE_REL (flight recorder, see the .cmd)
# ===========================================================================
set -euo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# --- layout ----------------------------------------------------------------
if [[ -n "${APPDIR:-}" && -x "$APPDIR/gzdoom" ]]; then
    PROJ="$APPDIR"
    # Where the user actually is: appimage runtime records the launch dir in
    # OWD, and the image location in APPIMAGE. Game data cannot live inside
    # the read-only image, so it is looked for next to the image first.
    USERDIR="${OWD:-$PWD}"
    [[ -n "${APPIMAGE:-}" ]] && IMAGEDIR="$(dirname -- "$APPIMAGE")" || IMAGEDIR="$USERDIR"
else
    PROJ="$HERE"
    USERDIR="$HERE"
    IMAGEDIR="$HERE"
fi

ENGINE="$PROJ"
if [[ ! -x "$ENGINE/gzdoom" ]]; then
    ENGINE="$PROJ/build/linux/stage"
fi
if [[ ! -x "$ENGINE/gzdoom" ]]; then
    echo "gzdoom not found. Build the bundle first:  tools/build-linux.sh" >&2
    exit 1
fi

MODS="$ENGINE/mods"
[[ -d "$MODS" ]] || MODS="$PROJ/Doom64-Retribution"

PINS="$MODS/d64rt-pins.cfg"
[[ -e "$PINS" ]] || PINS="$PROJ/tools/d64rt-pins.cfg"

# --- config / state --------------------------------------------------------
CONFDIR="${XDG_CONFIG_HOME:-$HOME/.config}/doom64-rt"
mkdir -p "$CONFDIR"
SETTINGS="$CONFDIR/settings.conf"
INI="$CONFDIR/doom64-rt.ini"

# --- game data: the parts we cannot ship -----------------------------------
find_ci() { # find_ci DIR NAME -> first case-insensitive match, or nothing
    [[ -d "$1" ]] || return 0
    find "$1" -maxdepth 1 -iname "$2" -print -quit 2>/dev/null
}

GAME="${D64RT_GAME_DIR:-}"
if [[ -z "$GAME" ]]; then
    for cand in "$IMAGEDIR/game" "$USERDIR/game" "$PROJ/game" "$PROJ/Doom64-Retribution" \
                "${XDG_DATA_HOME:-$HOME/.local/share}/doom64-rt/game"; do
        if [[ -n "$(find_ci "$cand" 'D64RTR*.WAD')" ]]; then GAME="$cand"; break; fi
    done
    [[ -n "$GAME" ]] || GAME="$IMAGEDIR/game"
fi
ADDONS="$(dirname -- "$GAME")/Addons"

IWAD="${D64RT_IWAD:-}"
UEMON=1
RECOLOR=0
MOD=""

# settings file: key=value, written by this script; a saved answer wins over
# the search below (matching the .cmd's behavior).
if [[ -e "$SETTINGS" ]]; then
    while IFS='=' read -r k v; do
        case "$k" in
            iwad)       IWAD="$v" ;;
            uemonsters) UEMON="$v" ;;
            mod)        MOD="$v" ;;
            recolor)    RECOLOR="$v" ;;
        esac
    done < "$SETTINGS"
fi

if [[ -z "$IWAD" || ! -e "$IWAD" ]]; then
    for cand in \
        "$(find_ci "$GAME" doom2.wad)" \
        "$(find_ci "$IMAGEDIR" doom2.wad)" \
        "$(find_ci "$HOME/.steam/steam/steamapps/common/Doom 2/base" doom2.wad)" \
        "$(find_ci "$HOME/.steam/steam/steamapps/common/Doom 2/masterbase" doom2.wad)" \
        "$(find_ci "$HOME/.steam/steam/steamapps/common/Ultimate Doom/base" doom2.wad)" \
        "$(find_ci "$HOME/.local/share/Steam/steamapps/common/Doom 2/base" doom2.wad)" \
        "$(find_ci "$HOME/.local/share/Steam/steamapps/common/Doom 2/masterbase" doom2.wad)" \
        "$(find_ci "${XDG_DATA_HOME:-$HOME/.local/share}/games/doom" doom2.wad)" \
        "$(find_ci "$HOME/GOG Games/DOOM II/DOOM II" DOOM2.WAD)"; do
        if [[ -n "$cand" && -e "$cand" ]]; then IWAD="$cand"; break; fi
    done
fi

# The ModDB download is named D64RTR[v1.5].WAD; the repo also carries a
# shell-safe D64RTR_v15.WAD spelling. Accept whichever is present -- and on a
# case-sensitive filesystem, whatever case it extracted with.
if [[ -z "$MOD" || ! -e "$MOD" ]]; then
    MOD="$(find_ci "$GAME" 'D64RTR\[v1.5\].WAD')"
    [[ -n "$MOD" ]] || MOD="$(find_ci "$GAME" 'D64RTR_v15.WAD')"
fi
BRIGHT="$(find_ci "$GAME" 'D64RTR_BRIGHTMAPS.PK3')"
MUSIC="$(find_ci "$GAME" 'D64MUS.PK3')"

# --- the startup check ------------------------------------------------------
missing=()
[[ -n "$IWAD" && -e "$IWAD" ]] || missing+=("doom2.wad (DOOM II -- Steam/GOG; or set D64RT_IWAD)")
[[ -n "$MOD" ]]    || missing+=("D64RTR[v1.5].WAD (Doom 64: Retribution v1.5 -- moddb.com/mods/doom-64-retribution)")
[[ -n "$BRIGHT" ]] || missing+=("D64RTR_BRIGHTMAPS.PK3 (in the same Retribution download -- extract ALL of it)")
[[ -n "$MUSIC" ]]  || missing+=("D64MUS.PK3 (OGG music pack v1.3 -- the addons page of the same mod)")
[[ -e "$ENGINE/rt/bin/libRTGL1.so" ]] || missing+=("rt/bin/libRTGL1.so (broken bundle -- rebuild with tools/build-linux.sh)")

if (( ${#missing[@]} )); then
    echo ""
    echo "  Doom 64 - Ray Traced cannot start. Missing:"
    printf '    - %s\n' "${missing[@]}"
    echo ""
    echo "  Put the downloaded game files in:  $GAME"
    echo "  (create the directory if needed; D64RT_GAME_DIR overrides the location)"
    exit 1
fi

# Remember the answers that were searched for, so the next launch starts from
# them. Written without a BOM, obviously -- see the .cmd for that war story.
{
    echo "iwad=$IWAD"
    echo "uemonsters=$UEMON"
    echo "mod=$MOD"
    echo "recolor=$RECOLOR"
} > "$SETTINGS"

# --- flight recorder (opt-in, see launch-doom64-rt.cmd) ---------------------
D64RT_SPIKE_MS="${D64RT_SPIKE_MS:-0}"
D64RT_SPIKE_REL="${D64RT_SPIKE_REL:-0}"
LOGF="$CONFDIR/rt-console.log"
[[ -e "$LOGF" ]] && mv -f "$LOGF" "$CONFDIR/rt-console.prev.log"
RECORDER=(+logfile "$LOGF")
if [[ "$D64RT_SPIKE_MS" != 0 || "$D64RT_SPIKE_REL" != 0 ]]; then
    RECORDER+=(+rt_stat_force 1 +rt_stat_spike "$D64RT_SPIKE_MS" +rt_stat_spike_rel "$D64RT_SPIKE_REL")
fi

# --- upscaler: pick one, then write BOTH cvars ------------------------------
if [[ -z "${D64RT_UPSCALER:-}" ]]; then
    if [[ -e /proc/driver/nvidia/version || -d /sys/module/nvidia ]]; then
        # DLSS also needs its runtime next to the renderer; without it, NGX
        # fails at init and the game runs unupscaled -- FSR is the better hand.
        if compgen -G "$ENGINE/rt/bin/*nvngx_dlss*" >/dev/null || \
           compgen -G "$ENGINE/rt/bin/libnvidia-ngx-dlss*" >/dev/null; then
            D64RT_UPSCALER=dlss
        else
            D64RT_UPSCALER=fsr
        fi
    else
        D64RT_UPSCALER=fsr
    fi
fi
case "$D64RT_UPSCALER" in
    dlss) UPSCALE=(+rt_upscale_dlss 2 +rt_upscale_fsr2 0) ;;
    fsr)  UPSCALE=(+rt_upscale_dlss 0 +rt_upscale_fsr2 2) ;;
    *)    UPSCALE=(+rt_upscale_dlss 0 +rt_upscale_fsr2 0) ;;
esac

# --- map argument: 1-34, or "menu"; the rest is passed through --------------
MAPARG=()
WHAT="${1:-menu}"
CHECKONLY=
[[ "$WHAT" == check ]] && { CHECKONLY=1; WHAT=menu; }
[[ "$WHAT" == setup ]] && WHAT=menu
if [[ "$WHAT" != menu ]]; then
    printf -v n '%02d' "$WHAT" 2>/dev/null || { echo "bad map number: $WHAT" >&2; exit 1; }
    MAPARG=(+map "map$n")
fi
(( $# )) && shift

# --- optional: the Unseen Evil monsters -------------------------------------
UEMONARGS=()
UEMONCVAR=()
if [[ "$UEMON" == 1 && -e "$MODS/d64r-ue-monsters.pk3" ]]; then
    UEMONARGS=("$MODS/d64r-ue-monsters.pk3")
    # Assert the cvar too: d64_ue_enable archives, and a dev launcher may have
    # written 0 into the shared ini. The tick is the switch, so state it.
    UEMONCVAR=(+d64_ue_enable 1)
fi

# --- optional: classic recoloured Cacodemon / Pain Elemental ----------------
RECOLORARGS=()
if [[ "$RECOLOR" == 1 ]]; then
    rec="$(find_ci "$ADDONS" 'D64ClassicRecolored.wad')"
    [[ -n "$rec" ]] || rec="$(find_ci "$ADDONS" 'D64ClassicRecolored_OffsetFix.wad')"
    if [[ -n "$rec" ]]; then
        RECOLORARGS=("$rec")
        [[ -e "$MODS/d64r-caco-ball-recolor.pk3" ]] && RECOLORARGS+=("$MODS/d64r-caco-ball-recolor.pk3")
    fi
fi

echo ""
echo "  Doom 64 - Ray Traced"
echo "  engine    : $ENGINE"
echo "  iwad      : $IWAD"
echo "  game      : $GAME"
echo "  log       : $LOGF"
if [[ "$UEMON" == 1 && -e "$MODS/d64r-ue-monsters.pk3" ]]; then
    echo "  monsters  : Retribution + Unseen Evil replacements"
else
    echo "  monsters  : Retribution only"
fi
echo "  upscaler  : $D64RT_UPSCALER   (override with D64RT_UPSCALER=dlss|fsr|none)"
echo ""
if [[ -n "$CHECKONLY" ]]; then
    echo "  check     : everything is in place -- run without 'check' to play"
    exit 0
fi

# --- runtime environment ----------------------------------------------------
# The RT renderer needs an Xlib Vulkan surface; XWayland is fine.
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-x11}"
export LD_LIBRARY_PATH="$ENGINE${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export RTGL1_LIBRARY_PATH="${RTGL1_LIBRARY_PATH:-$ENGINE/rt/bin/libRTGL1.so}"
export GZDOOM_RT_ASSET_DIR="${GZDOOM_RT_ASSET_DIR:-$ENGINE/rt}"

# NO -width/-height here: the window size the player saves in the menus is
# theirs to keep (see the .cmd for the story).
cd "$ENGINE"
exec "$ENGINE/gzdoom" -iwad "$IWAD" \
    -file "$MOD" "$BRIGHT" "$MUSIC" \
    "$MODS/d64r-lostsoul-rt.pk3" "$MODS/d64r-rt-flashlight.pk3" \
    "$MODS/d64r-seqlight-fix.wad" \
    "$MODS/d64r-bulb-textures.wad" "$MODS/d64r-sflatas-broken.wad" \
    "$MODS/d64r-ctel-fix.wad" \
    "$MODS/d64r-liquid-art.wad" \
    "$MODS/d64r-smonf-blink.wad" "$MODS/d64r-smonf-lights.wad" \
    "$MODS/d64r-rt-sky.pk3" \
    -file "$MODS/d64r-lava-fx.pk3" "$MODS/d64r-poison-fx.pk3" \
    "$MODS/d64r-blood-persist.pk3" \
    "${UEMONARGS[@]}" \
    "$MODS/d64r-widescreen-gfx.pk3" "$MODS/d64r-mugshot.pk3" "$MODS/d64r-rt-titlelogo.pk3" \
    "${RECOLORARGS[@]}" \
    -rtnolauncher \
    -config "$INI" \
    +exec "$PINS" "${UPSCALE[@]}" "${UEMONCVAR[@]}" "${RECORDER[@]}" "${MAPARG[@]}" "$@"
