#!/usr/bin/env bash
# Pac-Man World 2 - Linux launcher.
#
# Only --user-dir is passed. The module is auto-discovered as
# gGP2EAF_recomp.so from this folder, and the game path is read from
# userdata/default-game.txt (resolved relative to this folder).
#
# -X11 is deliberate: Dolphin's keyboard input comes from its XInput2 backend,
# which reads through the X server. Under a native Wayland surface the keyboard
# is dead. A gamepad works either way. Pass --wayland to override.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")" || exit 1

for f in moderngekko-run gGP2EAF_recomp.so; do
  [ -e "$f" ] || { echo "Missing $f -- run this from inside the bundle folder." >&2; exit 1; }
done

# ---------------------------------------------------------------- game data
# The game itself is not distributed. Drop your own disc image anywhere in
# Game/ and this extracts it once, on the first launch.
EXPECTED_DOL_SHA1="782bcce95127da823ed8903953f35cc00723919f"

find_iso() {
  find Game -maxdepth 2 -type f \( -iname '*.iso' -o -iname '*.gcm' -o -iname '*.rvz' \
       -o -iname '*.gcz' -o -iname '*.ciso' -o -iname '*.nkit.iso' \) 2>/dev/null | head -1
}

if [ ! -f Game/sys/main.dol ]; then
  iso=$(find_iso)
  if [ -z "$iso" ]; then
    cat >&2 <<'MSG'

No game data found.

  Put your own Pac-Man World 2 (USA) disc image in the Game/ folder, then run
  this again. Any GameCube dump works - .iso, .gcm, .rvz, .gcz or NKit.

      Game/Pac-Man World 2 (USA).iso

  The game is not included with this port and never will be: the disc data is
  Bandai Namco's copyrighted work. Use a disc you own.

MSG
    exit 1
  fi

  echo "Found disc image: $iso"

  magic=$(dd if="$iso" bs=1 skip=28 count=4 status=none 2>/dev/null | xxd -p)
  if [ "$magic" != "c2339f3d" ]; then
    echo "  ERROR: not a GameCube disc image (magic 0x$magic)." >&2; exit 1
  fi
  gameid=$(dd if="$iso" bs=1 count=6 status=none 2>/dev/null | tr -d '\0')
  case "$gameid" in
    GP2E*) ;;
    GP2P*) echo "  ERROR: PAL release ($gameid). This port needs the USA disc (GP2E)." >&2; exit 1 ;;
    GP2J*) echo "  ERROR: JP release ($gameid). This port needs the USA disc (GP2E)." >&2; exit 1 ;;
    *)     echo "  ERROR: wrong game - disc reports '$gameid', expected GP2E." >&2; exit 1 ;;
  esac
  echo "  game id: $gameid"

  echo "  extracting (one time, takes a moment)..."
  python3 tools/gcdisc.py dolphin-dir "$iso" -o Game >/dev/null || {
    echo "  ERROR: extraction failed." >&2; exit 1; }

  got=$(sha1sum Game/sys/main.dol 2>/dev/null | cut -d' ' -f1)
  if [ "$got" != "$EXPECTED_DOL_SHA1" ]; then
    echo "  ERROR: main.dol does not match the expected USA release." >&2
    echo "         expected $EXPECTED_DOL_SHA1" >&2
    echo "         got      $got" >&2
    echo "         This looks like a bad or modified dump." >&2
    rm -rf Game/sys Game/files
    exit 1
  fi
  echo "  verified. Generating symbol map..."
  python3 tools/dolmap.py map Game/sys/main.dol -o Game/sys/main.map >/dev/null 2>&1
  echo "  ready."
fi
[ -x moderngekko-run ] || chmod +x moderngekko-run

# This binary links ~70 shared libraries. Report anything absent up front
# rather than dying with a bare loader error.
missing=$(ldd ./moderngekko-run 2>/dev/null | awk '/not found/ {print "  " $1}')
if [ -n "$missing" ]; then
  echo "Missing shared libraries:" >&2
  echo "$missing" >&2
  echo >&2
  echo "This build links against the system's Vulkan, glslang, SPIRV-Tools, fmt," >&2
  echo "curl, hidapi and audio libraries. On Arch/CachyOS:" >&2
  echo "  sudo pacman -S --needed vulkan-icd-loader glslang spirv-tools fmt \\" >&2
  echo "      curl hidapi libusb bluez-libs alsa-lib libpulse lzo lz4 zstd xxhash" >&2
  exit 1
fi

mode=-X11
args=()
for a in "$@"; do
  if [ "$a" = "--wayland" ]; then mode=--wayland; else args+=("$a"); fi
done

exec ./moderngekko-run --user-dir userdata "$mode" "${args[@]}"
