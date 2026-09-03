#!/usr/bin/env bash
# Refuses to let game content reach a commit.
#
# .gitignore stops the obvious cases, but `git add -f`, a renamed file, or a
# stray copy will slip past it. This checks the actual staged CONTENT, not
# just filenames, and is meant to run as a pre-commit hook.
#
#   ln -s ../../tools/check-no-game-content.sh .git/hooks/pre-commit
set -uo pipefail
fail=0
say() { printf '  %s\n' "$*" >&2; }

staged=$(git diff --cached --name-only --diff-filter=ACM)
[ -z "$staged" ] && exit 0

# 1. Size. Nothing in a tooling repo needs to be large; game assets are.
while IFS= read -r f; do
  [ -f "$f" ] || continue
  sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
  if [ "$sz" -gt 2000000 ]; then
    say "TOO LARGE (${sz} bytes): $f"
    say "  Nothing in this repo should be >2 MB. Is this a game asset?"
    fail=1
  fi
done <<< "$staged"

# 2. Extensions that only ever belong to the disc or its derivatives.
while IFS= read -r f; do
  case "${f,,}" in
    *.dol|*.iso|*.rvz|*.gcm|*.gcz|*.nkit|*.tpl|*.dsp|*.thp|*.ast|*.bnr|\
    *.amf|*.hxf|*.sam|*.sdi|*.gci|*_recomp.so|*_recomp.dll)
      say "GAME CONTENT by extension: $f"; fail=1 ;;
  esac
done <<< "$staged"

# 3. Content signatures, so a renamed file is still caught.
while IFS= read -r f; do
  [ -f "$f" ] || continue
  # The checks below look for BINARY headers. Skip text files, or a patch or
  # doc that merely names GameSettings/GP2EAF.ini in its first line trips the
  # game-ID check - that ID is meant to catch a raw DOL/ISO header, not a
  # filename in a unified diff.
  case "$(file -b --mime-type "$f" 2>/dev/null)" in
    text/*|inode/x-empty|application/json) continue ;;
  esac
  head -c 64 "$f" 2>/dev/null | grep -qa "GP2E"   && { say "Contains GameCube game ID 'GP2E': $f"; fail=1; }
  head -c 8  "$f" 2>/dev/null | grep -qa $'\xc2\x33\x9f\x3d' && { say "GameCube disc magic: $f"; fail=1; }
  # A DOL has its text section offsets in the first 0x100 bytes and no ELF magic.
  if [ "$(stat -c%s "$f" 2>/dev/null || echo 0)" -gt 100000 ] \
     && ! head -c 4 "$f" | grep -qa $'\x7fELF' \
     && head -c 4 "$f" | grep -qa $'\x00\x00\x01\x00'; then
    say "Looks like a GameCube DOL: $f"; fail=1
  fi
done <<< "$staged"

if [ "$fail" -ne 0 ]; then
  cat >&2 <<'MSG'

COMMIT BLOCKED - game content detected.

This project is publishable ONLY as tooling. The game's data, its executable,
and anything recompiled from it are Bandai Namco's copyrighted work. Users must
supply their own disc dump.

If a flagged file is genuinely fine (e.g. a small docs screenshot), commit it
with:  git commit --no-verify
MSG
  exit 1
fi
exit 0
