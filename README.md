# pmw2-port

Tooling and patches for building a **native Linux port of Pac-Man World 2**
(GameCube, `GP2E`) by static recompilation, using
[DolRecomp](https://github.com/) + [ModernGekko](https://github.com/).

**This repository contains no game content.** You supply your own disc dump.

---

## What is actually here

| Path | What it is |
|---|---|
| `tools/gcdisc.py` | GameCube disc inspector/extractor. Reads NKit images in place; `info`, `ls`, `verify`, `dol`, `extract`, `dolphin-dir`. |
| `tools/dolmap.py` | DOL analyser and symbol-map generator. Recovers entry points from four sources and emits a DolRecomp symbol map. |
| `tools/mkinput.py` | Generates `GCPadNew.ini` for keyboard + gamepad, with correct platform key naming. |
| `tools/disasm/ppcdis.cpp` | Standalone Gekko disassembler over a raw DOL (wraps Dolphin's `GekkoDisassembler`). |
| `tools/check-no-game-content.sh` | Pre-commit hook that blocks game data from being committed. **Install this first.** |
| `patches/` | Patches against ModernGekko/Dolphin — see below. |
| `shaders/` | Four original CRT post-process shaders. |
| `docs/` | Modding guide, and notes from the framerate investigation. |

### Patches

| Patch | Fixes |
|---|---|
| `01-gxruntime-cpu-abi-v4` | GXRuntime CPU ABI version skew that made valid modules get rejected. |
| `02-port-symbol-map` | Pass `--map` when a symbol map exists; fold its hash into the module cache key. |
| `03-cmake-windows-crosscompile` | MinGW cross-build: guard X11/Wayland targets behind `NOT WIN32`. |
| `04-ingame-settings-menu` | In-game settings menu on Escape (video, audio, input remapping, mods, clean exit). |
| `05-audio-volume-alsa-pulse` | Volume/mute silently did nothing on ALSA/PulseAudio — `SoundStream::SetVolume` is an empty virtual on those backends. Applies the gain in the mixer instead. |

Patches 01, 03 and 05 are upstream bugs, not port-specific hacks, and are worth
reporting upstream.

---

## You need your own copy of the game

This project does not, and will never, distribute:

- the disc image, or any file extracted from it
- `main.dol` or any patched version of it
- **the recompiled module (`*_recomp.so`)**

That last one catches people out. The recompiled module is the game's own
executable code translated to x86-64. Compiling something does not launder its
copyright — the module is a derivative work of the game and is exactly as
un-distributable as the ISO.

Use a disc you own, dumped with something like CleanRip on a Wii. Please don't
open an issue asking for a link.

---

## Build

```sh
# 1. Install the guard first, so game data can never be committed by accident
ln -s ../../tools/check-no-game-content.sh .git/hooks/pre-commit

# 2. Extract your own disc
python3 tools/gcdisc.py extract /path/to/your.iso disc/PacManWorld2

# 3. Generate a symbol map (improves recompilation coverage)
python3 tools/dolmap.py map disc/PacManWorld2/sys/main.dol > disc/PacManWorld2/sys/main.map

# 4. Apply the patches to your ModernGekko checkout, then build it
cd /path/to/ModernGekko/vendor/dolphin
for p in /path/to/pmw2-port/patches/*.patch; do git apply "$p"; done

# 5. Input config
python3 tools/mkinput.py --out <bundle>/userdata/Config/

# 6. Shaders
cp shaders/*.glsl <bundle>/Sys/Shaders/
```

---

## Licensing

The patches modify Dolphin (GPL-2.0-or-later) as vendored by ModernGekko
(GPL-3.0), so they are **GPL-3.0-or-later** — see `LICENSE`. `tools/` and
`shaders/` are original work, also released under GPL-3.0-or-later for
consistency.

If you distribute a *built binary* of the runtime, GPL-3.0 obliges you to offer
the corresponding source. Publishing these patches plus your build scripts
satisfies that; shipping a binary with no source does not.

Pac-Man World 2 is © Bandai Namco. This project is unaffiliated with and
unendorsed by them. No copyright in the game is claimed or transferred here.

---

## Notes

`docs/framerate-investigation.md` documents a failed attempt to run the game
above 60 FPS, including the disassembly that shows why it is not feasible. It
is kept because negative results save the next person the effort.
