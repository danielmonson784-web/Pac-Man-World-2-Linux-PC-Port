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
`05-audio-volume-alsa-pulse.patch`. Plus V-Sync, Resume / Restart / Exit.
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

## 06-portable-moderngekko-port.patch  (a shipped moderngekko-port that works)

`moderngekko-port` resolved its source root from `MODERNGEKKO_SOURCE_DIR`, an
absolute path baked in at compile time. Two consequences, both bad for a
redistributable build: the binary is unusable on any machine but the builder's,
and the builder's home directory ends up in its strings.

`ResolveSourceRoot()` now prefers, in order: `$MODERNGEKKO_SOURCE_DIR` if it
points at a real tree; then `runtime/`, `.` or `..` beside the executable, which
is how a bundle is laid out; then the compiled-in path, so in-tree usage is
unchanged. The compiled-in value is overridable, which is what a release build
wants:

    cmake -DMODERNGEKKO_EMBED_SOURCE_DIR=/nonexistent

Without the override the default stays `CMAKE_CURRENT_SOURCE_DIR`.

Worth knowing when chasing the same leak: the build path *also* reaches the
binary through `__FILE__` in assertion and logging macros. That accounted for
128 of the 129 occurrences in a release build, and is fixed with

    -ffile-prefix-map=/your/build/root=/build

which does **not** touch this compile definition — hence the separate knob.
`strip` does not help either: the strings live in `.rodata` and are read at
runtime.

Apply after 03. Both touch `CMakeLists.txt`, and 06's hunk offset assumes 03 is
already in.

Patches 01, 03, 05 and 06 are upstream bugs rather than port-specific hacks.

## 07-ingame-restart-relaunch.patch  (the menu's Restart button)

The ModernGekko-side half of the Escape menu; `04` is the Dolphin-side half.
Kept separate only because the two live in different repositories -- `04`
applies to `vendor/dolphin`, this one to `ModernGekko` itself.

The menu originally had a **Reset** button that called `ResetButton_Tap()`. That
hangs the game: a statically recompiled module is initialised once and cannot be
re-entered from the reset vector, so the video backend dutifully tears down and
rebuilds -- the log shows the Vulkan context and both shader caches
reinitialising -- while the guest never resumes. The symptom is a black screen at
a steady frame delta of exactly 0.000 with the process still alive at ~47% CPU
and the FPS counter still ticking, which reads as a freeze rather than an error.
This is not specific to the widescreen flow; the plain Reset button hung the same
way.

There is also a second reason a guest reset would not have been enough. The
Gecko codes that switch the game between 4:3 and native 16:9 are applied while
the game boots, so a widescreen change only takes effect on a fresh boot.

So Reset became **Restart**, which relaunches the process. The overlay runs on
the video thread and owns neither the X connection nor `main`, so it raises
`g_ingame_restart_request`; `PlatformX11::PollOverlayInput` consumes it and calls
`Platform::Stop()` (the same path as Exit), and `main()` re-execs once `RunMain`
has returned and shutdown is complete.

Two things worth knowing:

  * The re-exec resolves `/proc/self/exe` with `readlink` and execs the resolved
    path. Exec'ing the literal `"/proc/self/exe"` works, but the kernel names the
    new process after the path it was exec'd with, so the game came back as
    **`exe`** in `ps` -- and `pgrep`/`pkill moderngekko-run` stopped finding it.
  * `PollOverlayInput` deliberately `load()`s the flag rather than `exchange()`ing
    it, because `main()` reads the same flag after shutdown to decide whether to
    re-exec.

`execv` keeps the pid, the controlling terminal and the working directory, so
`play.sh` stays attached to the new instance.

The same block is mirrored into `Source/Core/DolphinNoGUI/MainNoGUI.cpp` in
patch `04`, for the equivalent upstream frontend. Note that `moderngekko-run`
does **not** build `MainNoGUI.cpp` -- it has its own `main` in
`tools/moderngekko_run.cpp`. Putting the re-exec only in `MainNoGUI.cpp` compiles
cleanly, links cleanly and does exactly nothing, which cost a debugging round:
the giveaway is `strings moderngekko-run | grep "Restart failed"` returning 0.

Verified end to end, on the flow the bug was reported against: tick **Native
16:9 widescreen** (`userdata/GameSettings/GP2EAF.ini` gains `[Gecko_Enabled]` /
`$16:9 Widescreen`), click **Restart**, and the captured stdout shows one
`[staticrecomp] shutdown:` line followed by a second `core init` and
`module loaded` -- pid unchanged (execv), `comm` still `moderngekko-run`, and the
game back up at ~62% CPU with 5/5 moving frames and an active image of 1168x662,
aspect 1.764.

## 16:9 — native, via the wiki Gecko codes applied at runtime

The port renders 16:9 natively: the GAME lays out its projection, HUD and 2D for
a wide screen, rather than the emulator stretching a 4:3 image.

**What the codes actually do**, decoded against the DOL rather than taken on
faith. Parsing the DOL section table and reading each patch address gives a
coherent scheme built on one ratio and its exact reciprocal:

| what | factor | examples |
|---|---|---|
| 3 layout extents | 85/64 = 1.328125 | 512 -> 680, 512 -> 680, 256 -> 340 |
| ~25 normalized sizes | 64/85 = 0.752941 | 0.8 -> 0.602, 0.42 -> 0.316 |
| 13 `C2` hooks | 0.752941 | multiply a computed value, constant at 0x8000328C |

The game lays out 2D in a **512-unit-wide space**; 680 is that space at 16:9.
Widening it is what lets the HUD reach the edges of the frame. The size
constants take the reciprocal so elements do not grow as the space widens.

**Why data-only was never going to work.** One `C2` replaces
`lfs f3, 0x1ACC(r29)` - a load through a *runtime pointer*, with no fixed
address a data write could target. That is exactly why the earlier data-only
attempt left the Pac-Man life icon an ellipse.

**Why this works where baking into the DOL did not.** The `C2` codes are applied
at runtime by the Gecko engine. Under static recompilation the affected chunks
fail their hash check and fall back to the interpreter - which is correct, and
measured free: 59.9 FPS on all 30 samples across 60 s. Baking the same patches
into `main.dol` with code caves was tried instead and broke the game in play,
including the title screen. `Game/sys/main.dol` stays pristine.

Config: `EnableCheats = True`, `$16:9 Widescreen` in `[Gecko_Enabled]`,
`wideScreenHack = False`, `AspectRatio = Auto`. The hack must be OFF - the game
is doing the widening itself and both together double-correct. Auto is right
rather than Force 16:9: Dolphin's widescreen heuristic detects the game is now
genuinely anamorphic, and still handles any 4:3 content correctly.

Verified: title screen correct (the case that broke every previous attempt),
in-level HUD reaching the edges, life icon measured a circle, 59.9 FPS steady.

### Why there is no renderer-side 2D correction (and no widescreen-hack checkbox)

A renderer-side version was built and then removed, because it cannot work for
this game and the checkbox for it was an active trap: with the game already
rendering wide, enabling Dolphin's widescreen hack widens an already-wide image
and double-corrects it. Both checkboxes are gone from the menu; the aspect combo
stays, so 4:3 is still reachable.

The reason it cannot work is worth recording. This game submits 2D **one glyph
per draw call** - 12 vertices, ~0.07 clip-space span, measured by instrumenting
the batch walk. With `s` the scale applied to glyph size, `p` the scale applied
to glyph position, and a 1.333 display stretch:

* correct glyph shape needs `s = 0.75`
* correct letter spacing needs `p = s`
* filling the 16:9 width needs `p = 1`

`p` cannot be both 0.75 and 1. Anchoring the scale on the screen centre buys
correct text at the cost of a 12.5% dead band on each side; anchoring on each
batch's own centre fills the screen but spaces letters 33% too far apart. Both
were built and both were rejected on sight. Only the game changing its own
layout escapes the contradiction - which is exactly what the Gecko codes do by
widening the 2D layout space from 512 units to 680.

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

## 08-shader-cache-dirs-background-input.patch  (the shader cache actually persists)

Applies to `ModernGekko` itself. Two small runtime fixes:

**The shader cache never persisted.** `UICommon::CreateDirectories()` is only
called from DolphinQt's `main()`, which this port does not build, so nothing
ever created the user directories. `Cache/` in particular did not exist, and
`ShaderGenCommon`'s `File::CreateDir` for `Cache/Shaders/` is non-recursive, so
it failed on the missing parent on every launch. Every session started with
"Loaded 0 cached shaders", and each effect the player had not yet seen in THAT
session drew through the ubershader while its specialised shader compiled. With
SSAA on that is per-sample shading -- the ubershader runs once per MSAA sample on
every pixel it covers -- which is why the Clyde boss fight stuttered exactly when
smoke and fire filled the screen. One call added after `UICommon::Init()`.

**`--background-input`.** Without it Dolphin stops polling input when the
window loses focus, and the game reads that as the pad being unplugged
("PLEASE INSERT A CONTROLLER INTO CONTROLLER SOCKET 1"). It has to be a
command-line option rather than an INI edit: `dolphin_runtime.cpp` pushes its
own field into `MAIN_INPUT_BACKGROUND_INPUT` with `Config::SetBase` on every
boot, so an edited `BackgroundInput` in `Dolphin.ini` is overwritten and then
persisted back over the user's edit on shutdown.
