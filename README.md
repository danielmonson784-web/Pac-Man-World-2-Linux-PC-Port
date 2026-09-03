# pmw2-port

Tooling and patches for building a **native Linux port of Pac-Man World 2**
(GameCube, `GP2E`) by static recompilation, using
[DolRecomp](https://github.com/ExpansionPak/DolRecomp) + [ModernGekko](https://github.com/ExpansionPak/ModernGekko).

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
| `play.sh` | Bundle launcher. Auto-detects a disc image dropped in `Game/`, verifies and extracts it on first run, then launches. |
| `setup.sh` | Source-build setup. Requires `--iso`; verifies and extracts the disc and generates the symbol map. |
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
| `06-portable-moderngekko-port` | A shipped `moderngekko-port` baked an absolute build path in at compile time, making it unusable elsewhere and leaking the builder's home directory. Resolves the source root at runtime instead. |

Patches 01, 03 and 05 are upstream bugs rather than port-specific hacks.
Write-ups suitable for filing are in `docs/upstream-issues/`.

### Native 16:9

The port renders 16:9 natively: the **game** lays out its own projection, HUD
and 2D for a wide screen. It is not Dolphin's widescreen hack, and not a
stretched 4:3 image.

It is a **live** toggle in the in-game settings menu ("16:9 widescreen") - it
applies immediately, with no reset.

That works because none of the 13 code hooks ever has to be un-patched. Every
one of them reads its scale from one of two scratch words in guest RAM
(`0x8000328C`, `0x80003294`), so writing pristine neutral values there turns each
hook into an exact identity operation with its branch left permanently in place.
Toggling is then just 55 word writes, done on the CPU thread immediately after
the Gecko handler runs - ordering matters, because the handler rewrites those
same constants every field and would otherwise undo the neutrals before the
guest read them.

52 of the 55 neutral values were checked byte-for-byte against the pristine
`main.dol`. The other three are scratch words that are zero padding in the
pristine image. One of those, `0x80003294`, could not be read statically at all -
its hook replaces a load through a runtime object pointer - and an inferred
value of 0.5 turned out to be **wrong**: pristine 4:3 draws the Pac-Man life
icon 64x64, and 0.5 produced 48x64, exactly 3/4 too narrow. The real value is
2/3, confirmed by measuring the icon against a codes-disabled reference run.

Under the hood this enables the Dolphin-wiki `$16:9 Widescreen` Gecko codes for
`GP2EAF` at runtime (`EnableCheats = True`, codes in
`userdata/GameSettings/GP2EAF.ini`), with `wideScreenHack = False` — the two
together would double-correct. Decoded against the DOL, those codes scale three
layout extents by 85/64 (`512 -> 680`, `256 -> 340`; the game lays out 2D in a
512-unit-wide space) and about 25 normalized size constants by the exact
reciprocal 64/85, plus 13 code hooks.

Two things worth knowing if you fork this:

- **Do not bake the codes into `main.dol`.** That was tried, with code caves for
  the `C2` payloads, and it broke the game in play including the title screen.
  Applied at runtime instead, the affected chunks fall back to the interpreter,
  which is correct and costs nothing measurable — 59.9 FPS steady.
- **A renderer-side 2D correction cannot work for this game**, and one was built
  and removed before this was understood. The game submits 2D one glyph per draw
  call, so with a 1.333 display stretch: correct glyph shape needs size scaled by
  0.75, correct letter spacing needs position scaled by the same 0.75, and
  filling the width needs position scaled by 1. The last two contradict. Details
  in `patches/README.md`.

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

### Using a finished bundle

Once the runtime is built, running the game is just:

1. Drop your own disc image into the bundle's `Game/` folder — any filename,
   any GameCube dump format (`.iso`, `.gcm`, `.rvz`, `.gcz`, NKit).
2. Run `./play.sh`.

The first launch verifies the disc, extracts it and generates the symbol map;
every launch after that goes straight to the game. With no disc image present
it explains what to do rather than failing obscurely.

```
Game/
  Pac-Man World 2 (USA).iso      <- you provide this
  sys/    files/                 <- created on first launch
```

### Building the runtime

`setup.sh` does the same verification for a source build, and **requires your
own disc image**:

```sh
# Install the commit guard first, so game data can never be committed by accident
ln -s ../../tools/check-no-game-content.sh .git/hooks/pre-commit

# Verify and extract your disc, and generate the symbol map
./setup.sh --iso "/path/to/Pac-Man World 2 (USA).iso"
```

Both `setup.sh` and `play.sh` check three things before touching anything:

1. the GameCube disc magic at `0x1C` (`0xC2339F3D`),
2. the game ID at `0x00` — it names the PAL and JP releases specifically if you
   feed it the wrong region,
3. the SHA-1 of the extracted `main.dol`, which is byte identical across
   ISO / GCM / NKit / RVZ dumps of the same disc. Any dump format works; a
   corrupt or modified one is rejected.

Then:

```sh
# Get the upstream projects
git clone https://github.com/ExpansionPak/ModernGekko.git
git clone https://github.com/ExpansionPak/DolRecomp.git

# Apply the patches to the vendored Dolphin tree inside ModernGekko, then build
cd ModernGekko/vendor/dolphin
for p in /path/to/pmw2-port/patches/*.patch; do git apply "$p"; done

# Point the recompiler at disc/PacManWorld2/sys/main.dol, then finish the bundle
cp shaders/*.glsl <bundle>/Sys/Shaders/
python3 tools/mkinput.py --out <bundle>/userdata/Config/
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
