# Patches

Applied to the trees under `build/`. Re-apply after any `git checkout`/re-clone,
and on the Windows box before building there.

## 01-gxruntime-cpu-abi-v4.patch  (REQUIRED - nothing runs without it)

`vendor/dolphin/GXRuntime/include/core/cpu.h` declared
`GXRUNTIME_CPU_ABI_VERSION 3` with a 3528-byte `CPUState`, while ModernGekko's
own `include/moderngekko/cpu_state.h` is at ABI 4 with 3536 bytes -- it adds
`s64 cycle_budget` after `downcount`. DolRecomp's `src/cpu/cpu.h` also has the
field, so the vendored GXRuntime was the only component left behind.

`module-template/module_export.c` stamps the descriptor from GXRuntime's
header, so every module built from this checkout declared `cpu_abi_version=3`
and `StaticRecompCore::LoadModule` rejected it with "CPU ABI mismatch". With
`--allow-interpreter` the rejection is swallowed and the module is silently
dropped (`config.module = {}`), which is why the first boots reported
`native=0 fallback=0 cycles=0` and looked like a hang rather than an error.

The patch adds the missing field and bumps the version. Nothing in GXRuntime or
the Dolphin-side core referenced `cycle_budget`, so this is layout alignment
only. Upstream `RecompCore@moderngekko-vendor` is already at its branch tip
(`55c7b02`) with no fix, so this is worth reporting upstream.

## 02-port-symbol-map.patch  (optional, quality-of-life)

`moderngekko-port build` invoked DolRecomp without `--map`, so the symbol map
was ignored on the port path even though ModernGekko's README advertises named
address constants for code mods. The patch passes `--map` when
`<game-root>/sys/main.map` exists and folds the map's hash into the build cache
identity, so editing names correctly invalidates the cached module.

## Not a patch: the shallow-clone git ref

`vendor/dolphin` is cloned shallow on branch `main`, but Dolphin's
`ScmRevGen.cmake` runs `git rev-list --count HEAD ^master` and dies with
`fatal: bad revision '^master'`. Fix once:

    git -C build/ModernGekko/vendor/dolphin branch -f master HEAD

## 03-cmake-windows-crosscompile.patch  (NOT NEEDED HERE - kept as a bug report)

The Windows build has been deleted; this patch is retained only because it
documents a real upstream defect worth reporting. It is not applied by
`setup.sh` and has no effect on the Linux build.


`ModernGekko/CMakeLists.txt` forces `ENABLE_WAYLAND ON` unconditionally, and
gates its X11/Wayland blocks only on `if(TARGET PkgConfig::X11 / ::WAYLAND)`.
When cross-compiling, pkg-config still resolves the *host's* Wayland, so the
block is entered and `find_file(xdg-shell.xml ... REQUIRED)` aborts configure.
The patch makes Wayland Linux-only and adds `AND NOT WIN32` to both guards.

Worth reporting upstream alongside 01.

## 04-ingame-settings-menu.patch  (the Escape menu)

Adds an in-game settings overlay toggled with Escape. Three files:

- `VideoCommon/OnScreenUI.h` - declares the `g_ingame_menu_open` toggle.
- `VideoCommon/OnScreenUI.cpp` - draws the menu inside `Finalize()`, into the
  ImGui context Dolphin already renders over the emulated frame.
- `DolphinNoGUI/PlatformX11.cpp` - detects Escape and feeds the mouse.

Two findings made this harder than it looks, both pre-existing:

**Core key events never reach PlatformX11.** Dolphin's `XInput2` ciface selects
XI2 events on the render window, and XI2 selection suppresses core `KeyPress`
delivery. `ProcessEvents()` runs and receives `MapNotify`/`ConfigureNotify`/
`FocusIn`, but never a key. This is also why the pre-existing **F10 pause
hotkey has never worked** in this build. The menu therefore polls
`XQueryKeymap` and `XQueryPointer` instead of waiting for events.

**Xlib is not thread-safe here.** Polling on `m_display`, which the video
thread also uses, corrupted the `XQueryKeymap` reply and produced phantom key
edges - the menu flickered open and shut ~18 times in 45 s. The poller now
opens its own `Display*`. A two-sample debounce plus a 300 ms cooldown covers
the remainder.

**The menu does not pause.** Pausing was the original design, but a paused core
stops presenting frames, so `Finalize()` never runs and the menu cannot draw
itself. It is drawn over a running game instead. The game keeps reading the
controller while the menu is open, which is the trade-off for it being visible
at all.

**Mouse coordinates must be scaled.** `XQueryPointer` returns window
coordinates; ImGui works in backbuffer coordinates. Whenever the window is not
1:1 with the render target the two diverge, so the drawn pointer sat well away
from the real one and clicks missed every control -- which presents as
"the settings don't apply" rather than as a cursor bug. The poller now scales
by `GetBackbufferWidth()/window_width`.

**Only draw one cursor.** Opening the menu originally called `XUndefineCursor`,
revealing the OS pointer while ImGui drew its own, so two arrows appeared. The
OS cursor is now hidden while the menu is open.

**Startup grace period.** `m_last_toggle` defaulted to the clock epoch, so the
cooldown was already satisfied on the very first poll and a phantom keymap read
could pop the menu open before the game had even appeared. It is stamped on
first entry instead.

**16:9 on a 4:3 game.** The "16:9 widescreen hack" checkbox sets
`GFX_WIDESCREEN_HACK`, which widens the projection matrix so geometry is drawn
with a wider field of view rather than stretched, and pairs it with
`GFX_ASPECT_RATIO = ForceWide`. Both halves are needed: the hack alone gets
squeezed back into a 4:3 frame and looks thin; ForceWide alone stretches the
4:3 image. An Aspect ratio combo is exposed separately for manual control.

Settings apply live and are verified: Show FPS makes the FPS overlay appear,
internal resolution visibly changes the image, the widescreen hack widens the
view with correct proportions, and volume/mute are measured in
`05-audio-volume-alsa-pulse.patch`. Plus V-Sync, Resume / Reset / Exit.
Mouse-driven.

## 05-audio-volume-alsa-pulse.patch  (volume and mute actually work)

`SoundStream::SetVolume(int) {}` is an empty virtual. Only `CubebStream`,
`OpenALStream`, `OpenSLESStream` and `NullSoundStream` override it. This build
enables ALSA and PulseAudio on Linux, **neither of which implements it**, so
`AudioCommon::UpdateSoundStream` faithfully computed a volume and threw it
away. Volume and mute have never done anything on a Linux ALSA/Pulse build.

Rather than implement `SetVolume` per backend, the gain is applied in
`Mixer::Mix()` -- the one point every backend pulls samples from -- via a new
`Mixer::SetMasterVolume`, driven from `UpdateSoundStream`. That fixes every
backend at once, present and future.

Measured on the sink monitor with `parec`, 3 s windows:

| state | RMS | peak |
|---|---|---|
| volume 100 | 8410.9 | 32767 |
| mute on | **0.0** | **0** |
| volume ~50% | 4067.1 (0.48x) | 20301 |

This is an upstream Dolphin bug, independent of the menu, and worth reporting
on its own.

## Option 3 (native 16:9) — WORKING

`patches/06-widescreen-dol-manifest.md` documents the final form. The whole
16:9 code from the Dolphin wiki is baked into `main.dol` before recompilation,
so it runs as native code with **zero interpreter fallback and zero SMC
events**. The HUD renders correctly: the Pac-Man life icon is a circle, where
both Dolphin's widescreen hack and the data-only patch left it an ellipse.

The manifest lives at
`build/ModernGekko/vendor/dolphin/Data/Sys/GameSettings/GP2EAF.ini`
and has three kinds of entry:

| | count | |
|---|---|---|
| data/constant writes | 58 | the `04`/`02` lines, `02` merged into their dword |
| code-cave words | 66 | at `0x8020C57C`, 264 bytes |
| `b <cave>` hooks | 16 | 13 from the wiki code + 3 added |

**The C2 hooks needed code caves.** A Gecko `C2` replaces the instruction at
the address and the payload re-includes it — confirmed by observing that 9 of
the 13 payloads begin with a byte-identical copy of the instruction they
replace. Each hook therefore becomes: `b cave` at the site, and a cave holding
`payload… ; b hook+4`.

### Full audit of the 2D hook sites

All 34 `fmr f4,f3` instructions in the binary were enumerated and grouped by
the draw function the following `bl` reaches:

| call target | sites | hooked by wiki | added here | status |
|---|---|---|---|---|
| `0x8007095C` | 6 | 6 | 0 | complete |
| `0x80070934` | 9 | 2 | **7** | complete |
| `0x80071820` | 5 | 0 | 0 | different fn, left alone |
| `0x80071844` | 2 | 0 | 0 | different fn, left alone |
| 8 other targets | 12 | 0 | 0 | unrelated subsystems |

The wiki code hooks **both** draw functions but covers `0x80070934`
incompletely -- 2 of its 9 call sites. The 7 missing ones are
`0x800F89D4`, `0x80147810`, `0x80147844`, `0x80085B40`, `0x80085CA4`,
`0x80085CE4`, `0x80085D24`; leaving them out is what kept the front-end menu
and other 2D elements stretched.

Each added site was checked before hooking: the instruction is byte-identical
to the ones the wiki hooks, the surrounding code has the same argument-setup
shape (`lwz r4,<sda>` / `fmr f4,f3` / `addi r5,r0,818x` / `addi r6,r0,1`), and
`r7` -- the scratch register the payload uses -- is dead at each, since a call
follows within a few instructions and `r7` is caller-saved.

The other 19 sites were deliberately **not** hooked. `fmr f4,f3` is a generic
instruction; hooking every occurrence would scale floats in unrelated code.
Two of them (`0x8012FD04`, `0x8013F520`) additionally have `r7` live.

**The wiki code misses the front-end menu.** Its six 2D hooks all sit at call
sites that reach `0x8007095C`. Three other sites -- `0x800F89D4`,
`0x80147810`, `0x80147844` -- reach `0x80070934`, a sibling entry point 0x28
away, and the author covered one path and not the other. That is why the
in-game HUD came out correct while the title-screen menu stayed stretched.
Hooking those three with the same payload fixes the menu. `r7` (the scratch
register the payload uses) is unwritten near all three, matching the profile of
the sites the wiki code already hooks safely.

**Use `b`, never `bl`.** The first attempt shared caves between hooks with the
same payload by branching with `bl` and returning with `blr`, which fit all 13
into 132 bytes. It also clobbers LR at sites where the compiler still needs it,
and the game died after ~26 s of guest time. An A/B against the data-only build
confirmed the caves were the cause. Plain `b` with a per-hook return branch
never touches LR; it costs 264 bytes instead of 132 and is stable.

**The runtime must boot the patched DOL.** The module is compiled from
`patched-main.dol`, so `Game/sys/main.dol` has to be that same file or the
chunk hashes disagree and the guard drops those chunks to the interpreter —
47 SMC events, and the patches have no effect because guest memory is
unpatched. With the patched DOL installed: 0 events.

Config: `EnableCheats = False` (nothing at runtime), `AspectRatio = 1`,
`wideScreenHack = False`.

## Bundle fix found along the way

The bundle shipped **without Dolphin's `Sys/` directory** (15 MB: shaders,
fonts, GameSettings, codehandler.bin). It ran only because Dolphin fell back to
the build tree on this machine, and would have failed anywhere else. `Sys/` is
now part of the bundle.


## Why there are still thin pillarbox bars in a 16:9 window — and why that is correct

With the window sized to exactly 960x540 (16:9), the picture leaves ~42 px bars
each side: the render is about 1.63, not 1.778.

That is not a bug. Dolphin's own comment in `VideoInterface.cpp` explains it:
games pad the VI active area and most apply a slight horizontal scale, so the
XFB "is therefore almost never 4:3". Here `vi.GetAspectRatio()` is about 1.21,
and `AspectMode::ForceWide` scales it by (16/9)/(4/3), giving ~1.63. Dolphin is
faithfully widening *this game's actual* image.

Forcing the frame to fill with `AspectMode::CustomStretch` and a 16:9 custom
ratio does remove the bars, and it is measurably wrong. Pac-Man's head on the
title screen:

| aspect mode | head w x h | ratio | |
|---|---|---|---|
| ForceWide | 49 x 48 | **1.021** | round |
| CustomStretch 16:9 | 55 x 44 | 1.250 | stretched 25% |

So the bars are the price of correct geometry. `AspectRatio = 1` (ForceWide) is
the right setting; do not "fix" the bars.


## Menu additions (round 2)

Added to `04-ingame-settings-menu.patch`, plus a new shader file:

- **Pac-Man World 2 theme** - pellet yellow on maze blue, rounded frames,
  yellow checkmarks and slider grabs. Applied per-frame while the menu is open
  so it never leaks into Dolphin's other ImGui output.
- **CRT post-process** - `Sys/Shaders/CRT.glsl`, written for this port because
  Dolphin ships 48 post shaders and none is a CRT. Scanlines, soft aperture
  grille, tube curvature, vignette, phosphor bleed.
  *Tuning note:* the post-process runs at the INTERNAL resolution, so a mask
  keyed to `GetResolution()` gets finer as internal res rises and turns sprites
  into checkerboard - which is exactly what the first version did at 3x. Mask
  and scanline pitch are locked to a virtual 480-line screen instead, so the
  look is constant from 1x to 8x.
- **MSAA** (off/2x/4x/8x) and **SSAA**.
- **Toggle fullscreen** - the menu runs on the video thread and does not own
  the X connection, so it raises `g_ingame_fullscreen_request` and
  `PlatformX11::PollOverlayInput` consumes it and calls
  `X11Utils::ToggleFullscreen`. Verified 1280x662 -> 1280x720.
- **Second cursor** - already fixed earlier; the OS pointer is hidden while the
  menu is open so only ImGui's is drawn. Verified again here.

- **Full input remapping** - an "Input mapping" section in the menu that rebinds
  every GameCube control from any device. Built the same way DolphinQt's
  `MappingWidget` does it, minus Qt:

  1. `ciface::Core::InputDetector::Start()` on either the default device or
     every device (`GetAllDeviceStrings()`), depending on the checkbox.
  2. `Update(3s initial, 0ms confirmation, 5s maximum)` pumped once per frame
     from the menu draw. Nothing blocks, so the game keeps running at full
     rate while the user presses something.
  3. `ContainsCompleteDetection` -> `RemoveSpuriousTriggerCombinations` ->
     `MappingCommon::BuildExpression` -> `ControlReference::SetExpression` ->
     `UpdateSingleControlReference` -> `InputConfig::SaveConfig`.

  Controls come from `EmulatedController::groups` / `ControlGroup::controls`,
  so the list is whatever the pad actually exposes (Buttons, Control Stick,
  C Stick, Triggers, D-Pad, Triforce, Microphone, Rumble) rather than a
  hardcoded table. `ControlReference::IsInput()` filters out the rumble
  motors, which are outputs and not bindable.

  Verified live: clicking `A` showed `[ press now ]`, pressing J wrote
  `Buttons/A = J` into `userdata/Config/GCPadNew.ini`, and the original
  `SDL/0/Generic X-Box pad:Button A` binding restored cleanly afterwards.

  Keyboard and mouse both work because Dolphin exposes them on Linux as the
  single device `XInput2/0/Virtual core pointer`. `tools/mkinput.py` still
  generates the initial mapping; this edits it in place.


## Cursor fix, final version (2026-09-02)

The "second white mouse" over the settings menu was ImGui's own software
cursor (`io.MouseDrawCursor = true`) drawn on top of the OS pointer. Two
earlier attempts tried to hide the OS pointer under it with XDefineCursor
blanking; the durable fix is the opposite and simpler: the software cursor is
now disabled and the normal OS pointer is the menu's only cursor. The
window->backbuffer coordinate mapping is proportional, so the real pointer
always sits exactly over what a click will hit. The platform layer no longer
touches the cursor on menu open/close at all (the ShowCursor::Never paths are
unchanged).

## Gamma presets (2026-09-02)

Added a **Gamma** control to the settings menu. Pac-Man World 2 also shipped on
PS2 and Xbox, and those ports were mastered against different assumed display
gammas, which is a large part of why they don't look alike.

Mechanism: Dolphin's colour correction (`GFX_CC_CORRECT_GAMMA` +
`GFX_CC_GAME_GAMMA`) decodes the frame with "game gamma" and re-encodes for an
sRGB display, so the net transfer is approximately `pow(c, game_gamma / 2.2)`.
2.2 is therefore neutral and larger values darken the midtones - verified
directly in `Data/Sys/Shaders/default_pre_post_process.glsl` (decode at line
438, re-encode at 466/472).

Presets: Native (off, no correction) / GameCube 2.35 (Dolphin's default for GC)
/ Xbox 2.20 (brighter) / PS2 2.60 (darker), plus a free slider (clamped 2.2-2.8
by Dolphin) because these are approximations, not measured captures of the
retail PS2/Xbox discs.

Verified by A/B measurement at matched elapsed times from boot (attract demo
shows the same scenes): mean luminance ratio vs OFF was 0.984 for the PS2
preset and 1.079 for Xbox - i.e. the labels match the direction of the effect.

Note: Dolphin rewrites GFX.ini from its live config on shutdown, so a setting
changed in-menu (or by an experiment) persists into the next boot. Aspect had
drifted to Force 16:9 this way and was reset to Auto.

## Clean exit from the menu (2026-09-02)

The menu's Exit button called `Core::Stop(system)`, which stops the emulated
machine but leaves `Platform::MainLoop` running - the window stayed open around
a dead core, and the process never reached its shutdown path.

Fixed the same way as the fullscreen toggle: the menu runs on the video thread
and does not own the X connection, so Exit raises `g_ingame_exit_request` and
`PlatformX11::PollOverlayInput` consumes it and calls `Platform::Stop()` - the
identical call the window-manager close button makes (PlatformX11.cpp,
ClientMessage / WM_DELETE_WINDOW).

Verified: exiting from the menu now prints the full `[staticrecomp] shutdown:`
line (fallback=0, smc_failed=0) with no errors, which only happens on a
graceful teardown.
