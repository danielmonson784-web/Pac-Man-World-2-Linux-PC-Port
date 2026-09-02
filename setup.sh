#!/usr/bin/env bash
# Pac-Man World 2 Linux port - setup.
#
# This project ships NO game content. It cannot do anything until you point it
# at your own dump of the disc, which this script verifies before proceeding.
#
#   ./setup.sh --iso "/path/to/Pac-Man World 2 (USA).iso"
#
# Any GameCube dump format that gcdisc.py can read works: full ISO/GCM, NKit,
# or a scrubbed image. The check is done against main.dol, which is byte
# identical across all of them, so the format does not matter - only that it is
# genuinely this game and not a corrupt dump.

set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")" || exit 1

ISO=""
OUT="disc/PacManWorld2"
while [ $# -gt 0 ]; do
  case "$1" in
    --iso)  ISO="${2:-}"; shift 2 ;;
    --out)  OUT="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- the gate
if [ -z "$ISO" ]; then
  cat >&2 <<'MSG'

This project requires your own copy of Pac-Man World 2 (GameCube, USA).

    ./setup.sh --iso "/path/to/Pac-Man World 2 (USA).iso"

Nothing here works without it, by design. The disc data, the game executable,
and anything recompiled from them are Bandai Namco's copyrighted work and are
not distributed with this project.

Dump a disc you own - CleanRip on a Wii is the usual route. Please do not open
an issue asking where to download one.
MSG
  exit 1
fi

[ -f "$ISO" ] || die "no such file: $ISO"
[ -r "$ISO" ] || die "cannot read: $ISO"

echo "Verifying disc image..."
echo "  file: $ISO"

# 1. GameCube disc magic at 0x1C.
magic=$(dd if="$ISO" bs=1 skip=28 count=4 status=none 2>/dev/null | xxd -p)
[ "$magic" = "c2339f3d" ] || \
  die "not a GameCube disc image (magic 0x$magic, expected 0xc2339f3d)"

# 2. Game ID at 0x00. GP2E = Pac-Man World 2, USA.
gameid=$(dd if="$ISO" bs=1 count=6 status=none 2>/dev/null | tr -d '\0')
case "$gameid" in
  GP2E*) ;;
  GP2P*) die "this is the PAL release ($gameid). Only the USA disc (GP2E) is supported." ;;
  GP2J*) die "this is the Japanese release ($gameid). Only the USA disc (GP2E) is supported." ;;
  *)     die "wrong game: disc reports '$gameid', expected GP2E (Pac-Man World 2 USA)." ;;
esac
echo "  game id: $gameid"

# 3. Extract, then verify the executable itself. main.dol is byte identical
#    across ISO/NKit/RVZ dumps of the same disc, so this catches a corrupt or
#    modified dump regardless of format.
EXPECTED_DOL_SHA1="782bcce95127da823ed8903953f35cc00723919f"

echo "Extracting to $OUT ..."
python3 tools/gcdisc.py dolphin-dir "$ISO" -o "$OUT" >/dev/null || die "extraction failed"
[ -f "$OUT/sys/main.dol" ] || die "extraction produced no sys/main.dol"

got=$(sha1sum "$OUT/sys/main.dol" | cut -d' ' -f1)
if [ "$got" != "$EXPECTED_DOL_SHA1" ]; then
  cat >&2 <<MSG

ERROR: main.dol does not match the expected USA release.

  expected  $EXPECTED_DOL_SHA1
  got       $got

The disc header looked right, so this is most likely a bad dump, a modified
disc, or a revision this project has not been tested against. Re-dump and try
again.
MSG
  exit 1
fi
echo "  main.dol verified ($got)"

# ---------------------------------------------------------------- the rest
echo "Generating symbol map..."
python3 tools/dolmap.py map "$OUT/sys/main.dol" -o "$OUT/sys/main.map" \
  || die "symbol map generation failed"
echo "  $(wc -l < "$OUT/sys/main.map") symbols"

cat <<MSG

Setup complete.

  disc:    $OUT
  symbols: $OUT/sys/main.map

Next:
  1. Apply patches/ to your ModernGekko checkout and build it.
  2. Point the recompiler at $OUT/sys/main.dol
  3. Copy shaders/*.glsl into the bundle's Sys/Shaders/
  4. python3 tools/mkinput.py --out <bundle>/userdata/Config/

See README.md for detail.
MSG
