#!/usr/bin/env bash
# Pac-Man World 2 - Linux port launcher.
#
#   1. Put your own Pac-Man World 2 (USA) disc image in the Game/ folder.
#   2. Run this script.
#
# On the first run this extracts the disc and recompiles the game into a native
# module on your machine. That takes a few minutes and needs a C compiler.
# Every run after that starts straight away.
#
# No game data ships with this package. The disc image, everything extracted
# from it, and the recompiled module are all Bandai Namco's copyrighted work,
# so they are produced locally from a disc you own and never distributed.

set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")" || exit 1

EXPECTED_DOL_SHA1="782bcce95127da823ed8903953f35cc00723919f"
MODULE="gGP2EAF_recomp.so"

for f in moderngekko-run moderngekko-port dolrecomp; do
  [ -x "$f" ] || { echo "Missing $f -- run this from inside the bundle folder." >&2; exit 1; }
done

# ------------------------------------------------------------ 1. disc data
if [ ! -f Game/sys/main.dol ]; then
  iso=$(find Game -maxdepth 2 -type f \( -iname '*.iso' -o -iname '*.gcm' \
        -o -iname '*.rvz' -o -iname '*.gcz' -o -iname '*.ciso' \) 2>/dev/null | head -1)
  if [ -z "$iso" ]; then
    cat >&2 <<'MSG'

No game data found.

  Put your own Pac-Man World 2 (USA) disc image in the Game/ folder and run
  this again. Any GameCube dump works - .iso, .gcm, .rvz, .gcz or NKit:

      Game/Pac-Man World 2 (USA).iso

  The game is not included and never will be. Use a disc you own.

MSG
    exit 1
  fi

  echo "Found disc image: $iso"
  magic=$(dd if="$iso" bs=1 skip=28 count=4 status=none 2>/dev/null | xxd -p)
  [ "$magic" = "c2339f3d" ] || { echo "  ERROR: not a GameCube disc image (magic 0x$magic)." >&2; exit 1; }
  gameid=$(dd if="$iso" bs=1 count=6 status=none 2>/dev/null | tr -d '\0')
  case "$gameid" in
    GP2E*) ;;
    GP2P*) echo "  ERROR: PAL release ($gameid). This port needs the USA disc (GP2E)." >&2; exit 1 ;;
    GP2J*) echo "  ERROR: JP release ($gameid). This port needs the USA disc (GP2E)." >&2; exit 1 ;;
    *)     echo "  ERROR: wrong game - disc reports '$gameid', expected GP2E." >&2; exit 1 ;;
  esac
  echo "  game id: $gameid"

  echo "  extracting..."
  python3 tools/gcdisc.py dolphin-dir "$iso" -o Game >/dev/null || {
    echo "  ERROR: extraction failed." >&2; exit 1; }

  got=$(sha1sum Game/sys/main.dol 2>/dev/null | cut -d' ' -f1)
  if [ "$got" != "$EXPECTED_DOL_SHA1" ]; then
    echo "  ERROR: main.dol does not match the expected USA release." >&2
    echo "         expected $EXPECTED_DOL_SHA1" >&2
    echo "         got      $got" >&2
    rm -rf Game/sys Game/files
    exit 1
  fi
  echo "  verified."
  python3 tools/dolmap.py map Game/sys/main.dol -o Game/sys/main.map >/dev/null 2>&1 \
    && echo "  symbol map generated."
fi

# ------------------------------------------------------- 2. native module
if [ ! -f "$MODULE" ]; then
  if ! command -v clang >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; then
    cat >&2 <<'MSG'

A C compiler is required to build the game module, and none was found.

  Arch/CachyOS:   sudo pacman -S --needed clang
  Debian/Ubuntu:  sudo apt install clang

MSG
    exit 1
  fi
  cores=$(nproc 2>/dev/null || echo 4)
  cat <<MSG

  ############################################################
  #  ONE-TIME SETUP - please do not interrupt this            #
  ############################################################

  Recompiling the game to native code. Roughly 471,000 PowerPC instructions
  are translated to x86-64 and then compiled as 121 C files.

  This will take several minutes and will use ALL $cores of your CPU cores.
  High CPU load and a few GB of RAM are EXPECTED here - it is the C compiler
  working, not the game hanging.

  Every launch after this one skips straight to the game.

MSG

  BUILD_LOG="userdata/module-build.log"
  mkdir -p userdata
  # Ninja prints one very long absolute path per file, which buries the notice
  # above and reads like a hang. Log it in full, show a single progress line.
  # setsid puts the build in its own process group. Without that, interrupting
  # kills only moderngekko-port and leaves ninja and every cc1 it spawned running
  # at full tilt - which is exactly the runaway-CPU symptom this is meant to avoid.
  setsid env PATH="$PWD:$PATH" ./moderngekko-port build Game --output modules \
      > "$BUILD_LOG" 2>&1 &
  build_pid=$!
  cleanup_build() {
    kill -TERM "-$build_pid" 2>/dev/null   # negative pid = the whole group
    sleep 1
    kill -KILL "-$build_pid" 2>/dev/null
    printf '\r%*s\r' 70 ''
    echo "Interrupted. Removing the partial build so the next run starts clean."
    rm -rf modules/*/ 2>/dev/null
    exit 130
  }
  trap cleanup_build INT TERM
  spin=0
  while kill -0 "$build_pid" 2>/dev/null; do
    prog=$(grep -oE '^\[[0-9]+/[0-9]+\]' "$BUILD_LOG" 2>/dev/null | tail -1)
    case $((spin % 4)) in 0) t='-';; 1) t='\';; 2) t='|';; 3) t='/';; esac
    printf '\r  %s compiling %-12s (all cores busy - this is normal)   ' "$t" "${prog:-starting}"
    spin=$((spin + 1))
    sleep 1
  done
  trap - INT TERM
  printf '\r%*s\r' 70 ''
  if ! wait "$build_pid"; then
    echo "ERROR: module build failed. Full log: $BUILD_LOG" >&2
    tail -20 "$BUILD_LOG" >&2
    exit 1
  fi
  built=$(find modules -name "$MODULE" -type f 2>/dev/null | head -1)
  [ -n "$built" ] || { echo "ERROR: build produced no module." >&2; exit 1; }
  cp "$built" "./$MODULE" || exit 1
  echo "Module built."
fi

# ------------------------------------------------------------- 3. run it
missing=$(ldd ./moderngekko-run 2>/dev/null | awk '/not found/ {print "  " $1}')
if [ -n "$missing" ]; then
  echo "Missing shared libraries:" >&2; echo "$missing" >&2
  echo >&2
  echo "On Arch/CachyOS:" >&2
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
