#!/usr/bin/env bash
# Installs build dependencies and builds DolRecomp + ModernGekko.
# Review before running; the pacman step needs sudo.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 1. dependencies ---------------------------------------------------------
# Missing on this machine: cmake, ninja. Everything else is either present
# (gcc 16, clang 22, python 3.14, git) or vendored in Dolphin's Externals.
PKGS=(
  cmake ninja pkgconf            # build system (ModernGekko needs CMake >= 3.20)
  qt6-base qt6-svg               # Dolphin frontend
  libx11 libxi libxrandr libxkbcommon wayland wayland-protocols
  alsa-lib libpulse
  vulkan-headers vulkan-icd-loader
  libevdev libusb bluez-libs hidapi
  mesa libglvnd
)
echo ">> installing: ${PKGS[*]}"
sudo pacman -S --needed --noconfirm "${PKGS[@]}"

# --- 1b. patches + shallow-clone git ref ------------------------------------
# vendor/dolphin is a shallow clone on branch `main`, but Dolphin's
# ScmRevGen.cmake runs `git rev-list --count HEAD ^master` and aborts the build.
git -C "$ROOT/build/ModernGekko/vendor/dolphin" branch -f master HEAD

# 01 is REQUIRED: without it every built module is rejected at load with
# "CPU ABI mismatch". See patches/README.md.
# Which of the two repositories a patch belongs to is decided by trying it,
# not by its name: some patches touch ModernGekko itself, some touch the
# vendored Dolphin, and 04 has a half in each. Routing by name got 04 and 05
# sent to the ModernGekko root, where their Source/Core/... paths live inside a
# submodule and git refuses to apply - so both were silently skipped and a
# fresh setup came up with no Escape menu and no working volume control.
for p in "$ROOT"/patches/*.patch; do
  applied=""
  for d in "$ROOT/build/ModernGekko/vendor/dolphin" "$ROOT/build/ModernGekko"; do
    if git -C "$d" apply --check "$p" 2>/dev/null; then
      git -C "$d" apply "$p" && applied="$d" && break
    fi
  done
  if [ -n "$applied" ]; then
    echo ">> applied $(basename "$p") to ${applied#$ROOT/}"
  else
    echo ">> skipping $(basename "$p") (already applied or does not fit)"
  fi
done

# --- 2. DolRecomp ------------------------------------------------------------
# The LLVM object-emission path wants LLVM 19 or 20; this box has 22, so we
# build the portable C-output path, which is what the ModernGekko flow uses.
echo ">> building DolRecomp"
cmake -S "$ROOT/build/DolRecomp" -B "$ROOT/build/DolRecomp/build" \
      -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build "$ROOT/build/DolRecomp/build" --config Release
ctest --test-dir "$ROOT/build/DolRecomp/build" -C Release --output-on-failure || \
  echo "!! some DolRecomp tests failed -- review before trusting output"

# --- 3. ModernGekko ----------------------------------------------------------
echo ">> building ModernGekko"
cmake -S "$ROOT/build/ModernGekko" -B "$ROOT/build/ModernGekko/build" \
      -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build "$ROOT/build/ModernGekko/build" --config Release

echo
echo "done. binaries:"
find "$ROOT/build" -name 'dolrecomp*' -o -name 'moderngekko*' -type f -perm -u+x 2>/dev/null | grep -v '\.o$' | head
