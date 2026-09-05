# Can Pac-Man World 2 run above 60 FPS? - investigation notes

Date: 2026-09-02
Question: unlock gameplay above 60 FPS, leave FMVs at native rate.

## Tooling built

`tools/disasm/ppcdis.cpp` - standalone Gekko disassembler over a raw DOL,
wrapping Dolphin's `Common::GekkoDisassembler`. No capstone/pip/ppc-objdump on
this box, so this was the way in.

    ppcdis <main.dol> <vaddr> <count>

## What was mapped

r13 (small data base) = 0x80513460, r2 (rtoc) = 0x80523460, recovered from the
entry-point prologue at 0x80003100.

| symbol | address | how identified |
|---|---|---|
| `VIInit` (tail) | ~0x80195470 | clears DI0/DI1, registers int 24 |
| `__VIRetraceHandler` | 0x80194B9C | handler passed to `__OSSetInterruptHandler(24, ...)` |
| `retraceCount` | 0x8050D658 | `lwz r4,-0x5E08(r13)` / `addi r0,r4,1` / `stw` in the handler |
| `retraceQueue` | 0x8050D660 | `subi r3,r13,24064` before `OSSleepThread` |
| `PreRetraceCallback` | 0x8050D668 | `lwz r12,-0x5DF8(r13)` then `mtlr r12; blrl` |
| `PostRetraceCallback` | 0x8050D66C | adjacent slot, setter at 0x80194DC4 |
| `VIWaitForRetrace` | 0x80195508 | `OSDisableInterrupts` / sleep-until-`retraceCount`-changes / `OSRestoreInterrupts` |
| `VISetPostRetraceCallback` | 0x80194DC4 | single store to 0x8050D66C |

## Where the frames actually come from

`VIWaitForRetrace` has **15 call sites**, and every one is accounted for:

- **0x80012CE4** - `bl VIWaitForRetrace; subic. r31,r31,1; bne` = a
  "wait N frames" helper.
- **0x80003804 + 0x80003808** and **0x800052BC + 0x800052C0** - *adjacent
  pairs*, i.e. wait two vblanks = deliberate 30 FPS. Both sit in
  transition/loading loops.
- **0x80012F28, 0x80012FCC** - the THP FMV player loop.
- **0x8000502C, 0x800051B4, 0x80005260, 0x80005568, 0x8000557C, 0x800056BC,
  0x800130A0, 0x800910B4** - one-shot "present and wait" tails; each is
  immediately followed by the function epilogue.

`VISetPostRetraceCallback` has only 2 callers, **both inside the FMV player**.
The game never installs a *pre*-retrace callback at all (the only write to
0x8050D668 is `VIInit` zeroing it).

**So the gameplay loop touches none of the VI pacing machinery.** Its 60 FPS
does not come from a vblank wait that could be halved.

## Why there is no single knob to turn

Searched every data section for frame-timing constants:

| constant | distinct addresses |
|---|---|
| `1/60` (0x3C888889) | 8+ (0x801D1060, 0x801D1090, 0x801D1818, 0x801D7258, ...) |
| `1/30` (0x3D088889) | 6+ |
| `60.0f` | many |
| `30.0f` | many |

These are per-subsystem literal pools, not one shared rate. Notably absent:
`59.94`, `1/59.94`, `16.667`, `33.333` - the game is not computing from a real
refresh rate, it is hardcoding frame counts.

Then ranked every float global by load count, looking for a global delta-time:

    0x8050C3EC  x513  = 0.0
    0x8050C3FC  x203  = 0.0
    0x8050DDB4  x195  = <BSS>     <- best candidate
    0x8050C3E0  x55   = 0.0

0x8050DDB4 is the only hot *runtime* float, but it has **14 writers** scattered
across 0x8009xxxx, 0x800Exxxx and 0x8014xxxx - the signature of a shared
scratch temporary, not a once-per-frame delta.

## Verdict: not feasible as a bounded patch

Three independent blockers, each fatal on its own:

1. **No central delta.** The game advances state by hardcoded per-subsystem
   rates. Halving "the" timestep means finding and halving all of them, with no
   way to know when the list is complete short of playing every level.
2. **Gameplay pacing is not in the VI layer**, so there is no wait to shorten.
   It would have to be located first, and it is not reachable from the VI
   symbols above.
3. **The VI hardware tops out at 59.94 Hz.** Exceeding it means running the
   video interface out of spec - which is exactly what Dolphin's VIOverclock
   does, and at 2.0x it black-screened the game (tested 2026-09-01).

Gating any of this on "gameplay but not FMV" would additionally require finding
the game-state discriminator, which is a fourth unknown.

## What was NOT ruled out

Live RAM inspection would settle whether 0x8050DDB4 is a delta in about five
minutes, but `/proc/<pid>/mem` is blocked by ptrace hardening on this machine
and loosening that is not worth it for a probe. If this is ever revisited, the
cheap next step is a debug read-out of guest memory from inside the running
emulator rather than from outside.

## Standing conclusion

The game is already running at its designed 60 FPS using roughly one core out
of 32. Nothing in the port is capping it. The available headroom is better
spent on internal resolution, MSAA and post-processing - all of which are wired
into the Escape menu and working.

## Round 2 (2026-09-02): VI overclock sweep, measured

Hypothesis worth testing: since gameplay never calls `VIWaitForRetrace`, maybe
VI overclock adds presented frames without speeding gameplay, and only FMVs
(which ARE vblank-locked) would need it gated off.

Built `tools/vitest.sh` + `tools/visample.py` (samples title-bar FPS plus mean
frame brightness, so "black screen" is a number, not an impression).

| factor | result |
|---|---|
| off | 59.9-60.0 FPS, stable (baseline) |
| 1.5x | **30.1 FPS** - wrong direction - then hard freeze |
| 2.0x | black screen (previous session) |

The 1.5x run halving the presented rate proves the game's XFB presentation is
slaved to the SDK's VI state machine even outside `VIWaitForRetrace`: with
retrace timing out of spec, its sync logic misses every other field, then
deadlocks. The hypothesis is falsified: there is no factor that adds frames.

**Final verdict: uncapping is not achievable for this title** short of
rewriting its per-subsystem frame advancement (8+ hardcoded 1/60 pools, no
central delta, no vblank wait to shorten in gameplay). Both directions of the
only external knob break the game before gameplay is even reached.

## Round 3 (2026-09-02): live toggle - and the decision to stop

Runtime toggling (menu control, volatile SetCurrent) got much further than
boot-time config ever did:

| live factor | result |
|---|---|
| 1.5x (90 Hz) | 73.4 FPS presented, stable in the attract demo, CPU ~49% |
| 2.0x (120 Hz) | game crash: wild-pointer guest reads (0x3600cd00), recomp clean |

Deep-dive disassembly (3-agent workflow) also corrected two Round-1 findings:
- The gameplay main loop (0x8017383C) DOES pace on vblank: EndFrame
  0x800057F8 (GXCopyDisp -> GXDrawDone) -> swap fn 0x8000566C
  (VISetNextFrameBuffer -> VIFlush -> VIWaitForRetrace).
- The engine is dt-based: real frame-delta global at 0x8050C3EC (513 loads,
  3 stores, all in the frame-timing accumulator 0x801736C0). 0x8050DDB4 is a
  separate global slow-motion multiplier {0, 0.1, 0.2, 0.75, 1.0}.

Whether dt self-corrects at higher VI rates was never settled - the attract
timer measurement needed identical entry states and the user ended the
experiment during calibration.

**Decision: dropped at user request.** The VI rate menu control was removed
again; the port runs at the native, stable 60. The findings above stay here
for whoever picks this up next - the engine architecture (central dt +
timescale global + single vblank wait at 0x800056BC) is genuinely favorable,
and a future attempt should start from the 0x801736C0 accumulator.

---

# Widescreen round 2 (2026-09-02): dropped at user request

New approach that got further than round 1: runtime scene-gating. All patch
scale factors route through guest constants (0x8000328C/90/94 + 55 data
values); Core/HW/PMW2Widescreen.cpp rewrites them per scene and drives the
aspect via the main loop's state-callback pointer at 0x8050C418. Verified:
neutrals confirmed bit-exact for all 20 stubs (hook table in the workflow
output at tasks/wvc3ylc65.output), neutral boot renders correct 4:3, host
writes to text0 cost one interpreter-fallback chunk (boot stub, harmless).
State values observed live: 80167e00, 80120894 (boot->title cycle). The
remaining step was classifying gameplay values and flipping the tables.

User called it off before completion. PMW2Widescreen.cpp stays in the tree -
it self-arms ONLY when the patched DOL's code cave is in memory, so it is
completely inert on the shipped pristine DOL. Bundle restored: pristine DOL,
unpatched module, AspectRatio=0, wideScreenHack=False.


## Round 4 (2026-09-02): the two remaining candidate levers, both eliminated

### 0x8050C400 - the dt scale factor

Corrects an earlier claim in these notes that there is "no central delta".
There IS one, and the chain is short:

    0x801D1BE4  literal 1.0f
      -> stored once at 0x80040674 into 0x8050C400   (single writer)
      -> read as f12 by the frame accumulator 0x801736C0
      -> accumulator advances by [0x8050C3F0] * f12, wrapping at [0x8050C3FC]
      -> result written to the dt global 0x8050C3EC   (513 loads)

Also decisive, and a cleaner proof of fixed-step than the scattered-constants
argument used earlier: **0x8050B460 - the frame duration EndFrame actually
measures from the retrace counter - has one store and ZERO loads.** The engine
measures real elapsed time every frame and discards it.

Tested: patched the literal 1.0 -> 0.5, rebuilt the module against the patched
DOL, measured picture-change-per-second.

| build | median motion/s | range |
|---|---|---|
| dt = 1.0 | 16.51 | 13.2 - 21.1 |
| dt = 0.5 | 14.24 | 10.7 - 17.4 |

Ratio 0.86 with heavily overlapping ranges - scene variance in the attract
demo, not a real effect. **Not the master simulation rate.**

### 0x8050DDB4 - not a time scale at all

The round-1 agent analysis called this a "global slow-motion multiplier"
(values {0, 0.1, 0.2, 0.75, 1.0} with dt-scaled ramps, multiplied into
"velocities, displacements, damping"). That reading was wrong.

Tested by forcing the value to 0.5 every VI field from the host side (no DOL
patch, no module rebuild - a temporary hook in PMW2Widescreen.cpp), which
overrides all 14 of the game's own writers, i.e. exactly what writer hooks
would achieve.

**Result: Pac-Man became physically smaller. It is a model/render SCALE
multiplier, not a time scale.** The values are a grow/shrink effect. One look
at the screen settled what three automated measurements could not.

### Where that leaves it

Both remaining levers are eliminated. The engine is fixed-step, it throws away
the frame duration it measures, and neither the dt accumulator nor the scale
global governs simulation rate. Raising the refresh rate still requires
rewriting frame advancement subsystem by subsystem.

Methodology note for anyone continuing: automated speed proxies were
unreliable here. Motion-per-second swings 0.00-46.73 across the attract demo's
cuts and fades; logo detection false-positives; audio windows land on the FMV.
Force a candidate value from the host side and *look at the screen* - it is
faster and far more conclusive.

---

# BREAKTHROUGH (2026-09-02, end of session)

## 0x8050C400 DOES control simulation speed

Round 4 recorded this as "not the master simulation rate". **That was wrong** -
the conclusion came from a motion-per-second proxy too noisy to see the effect
(medians 14.24 vs 16.51, overlapping ranges).

Retested by forcing the value from the host every VI field and simply looking
at the screen. Result, confirmed by the user: **"it is slowing down."**

So the lever is real:

    0x8050C400   step scale, single writer at 0x80040674 (init, literal 1.0)
                 read as f12 by the frame accumulator at 0x801736C0
                 advances the dt global 0x8050C3EC (513 readers)

## Where it stands

Combining an N-times VI rate with a 1/N step scale gets close but is NOT yet
correct:

| setting | result |
|---|---|
| VI 1.0x, step 0.5 | clear slow motion - lever confirmed |
| VI 2.0x, step 0.5 | crashes (wild-pointer read, same as VI 2.0x alone) |
| VI 1.5x, step 0.667 | runs, but **Pac-Man still moves too fast** |

So dt governs *some* motion but not all of it - partial compensation. The step
scale that actually yields correct speed has to be found empirically, and may
not be 1/N.

VI 2.0x crashes regardless of compensation, so ~1.5x (about 90 FPS) looks like
the stable ceiling for the VI-overclock approach.

## How to continue

The runtime exposes two independent knobs (both no-ops when unset), so tuning
needs no rebuild:

    PMW2_FPS_MULT=1.5    # VI rate multiplier
    PMW2_DT_STEP=0.45    # step scale, overrides the default 1/mult

    cd out/linux/PacManWorld2-Linux64
    PMW2_FPS_MULT=1.5 PMW2_DT_STEP=0.45 ./play.sh

Next step: hold PMW2_FPS_MULT=1.5 and sweep PMW2_DT_STEP downward from 0.667
until motion looks native. If a value exists that is visually correct, the
approach works and can be promoted to a menu setting. If motion stays wrong at
every value, the remaining motion is driven by something other than the dt
accumulator and that subsystem has to be found next.

Methodology that works: force a candidate from the host side and LOOK. Every
automated proxy tried here (motion-per-second, logo detection, audio windows)
was too noisy or fired on the wrong thing. The user identified both the
geometry-scale global and this one by eye in seconds.

---

# FINAL: the time base is solved, the VI rate is the blocker

## Solved: 0x8050C3F4 is the true global time scale

Three agents mapped every rate source. The engine's time base is not one value
but ONE VALUE THAT FORKS INTO FOUR, which is why every earlier lever only
half-worked:

    EndFrame returns VIGetRetraceCount delta (always 1, at ANY refresh rate)
      -> main loop converts it with a HARDCODED 1/60 at 0x801F0270
      -> rescaled at 0x80173914/0x80173924/0x80173934 by [0x8050C3F4]
      -> then FORKS:
           0x8050C3EC  dt               513 loads   = seconds * [0x8050C400]
           0x8050C3E4  frames elapsed    44 loads   unscaled
           0x8050C3E0  86400s clock      57 loads   unscaled
           0x8050C3F0  seconds elapsed   13 loads   unscaled

0x8050C400 reaches ONLY dt. That is why VI 1.5x + step 0.667 corrected 513
sites and left ~114 running at 1.5x - including player position integration
(the player module is otherwise a dt desert: 3 dt uses in the whole TU).

**0x8050C3F4 is an unused compiled-in time-scale slot** sitting upstream of the
fork. An exhaustive store scan of all ~470k text words finds NO writer anywhere
in the image; its only reference is the single load at 0x80173914. Writing 1/N
there scales frames, seconds, dt and both clocks together.

VERIFIED: setting it to 0.5 at native 60 Hz puts the ENTIRE game in uniform
slow motion - player, animation, camera, everything. That is the correct and
complete time-scale lever, and it is safe to hold from the host every field.

## Blocked: VI overclock is unusable on this title

Getting real frames above 60 requires raising the VI rate, and this game will
not tolerate it, independent of any time compensation:

| VI factor | result |
|---|---|
| 1.25x | runs |
| 1.5x  | only reaches ~73 FPS (not 90); music breaks; title screen breaks; still too fast |
| 2.0x  | crashes - wild-pointer reads (0x3600cd00) |

Audio is clocked off VI/DSP timing, so pushing retrace desyncs the mixer. The
game also never actually achieves the requested rate, so even the frames it
does gain come with broken presentation.

## Verdict

The time-scale half is genuinely solved and reusable. The frame-delivery half
is not achievable through VI overclock on this engine. Real >60 FPS would need
the render loop decoupled from the vblank wait at 0x800056BC - i.e. engine
surgery, not a patch.

Residuals that would ALSO need fixing even if VI worked (from the agent map):
  - 0x8050DDF4 integer frame counter, 55 readers, unscalable (and unsafe to
    overwrite - doing so broke audio, since consumers compute deltas from it)
  - 33 hardcoded 1/60 and 7 hardcoded 1/30 literal timesteps
  - 0x800ED744 1 deg/frame and 0x800ED778 0.5 deg/frame rotations
  - 0x801588F0 57.0 units/frame camera translate

## The vblank wait is NOT the limiter (tested 2026-09-02)

Final experiment: NOP the `bl VIWaitForRetrace` at 0x800056BC (4818FE4D ->
60000000), rebuild the module against the patched DOL, run.

**Result: 49-54 FPS. LOWER than the stock 60.**

So removing the game's frame-pacing wait does not increase presented frames -
it reduces them. The reason is that presented frames are gated by Dolphin's VI
scanout, not by the guest's wait: the game swaps the XFB as fast as it likes,
but the host only presents on VI, which is 60 Hz. Freeing the loop just adds
redundant work (EndFrame still blocks on GXDrawDone at 0x80005834) and costs
throughput.

This closes the last avenue. Frame delivery is gated by the VI rate; the VI
rate cannot be raised on this title (music and title screen break at 1.5x,
crash at 2.0x). Reverted to pristine DOL and the matching module.

## Summary of the whole investigation

SOLVED, and genuinely new:
  - 0x8050C3F4 is the true global time scale, upstream of the four-way fork
    into dt / frames / seconds / clocks. Verified: 0.5 puts the entire game in
    uniform slow motion. This is a complete, safe speed control.

NOT ACHIEVABLE:
  - Real frame rates above 60. Presentation is gated by VI scanout; raising VI
    breaks audio (DSP is VI-clocked) and the title screen, and crashes at 2.0x;
    and removing the guest's own vblank wait makes throughput worse, not better.

The time-scale finding is reusable for anything that wants a correct global
slow-motion or turbo control. The frame-rate goal is closed.

---

# Transform interpolation: working prototype, three defects

Built end-to-end and it DOES work - motion is confirmed smoother by eye. But it
is a prototype, not a shippable feature.

## What was built

- **Draw recorder** in `VertexManagerBase::RenderDrawCall` - captures per draw:
  vertex bytes, indices, pipeline, resolved textures + samplers, the XF
  transform bank (`xfmem.posMatrices`), and whether the draw is orthographic.
  ~300 draws / ~1.5 MB per frame.
- **`ReplayRecordedDraws(draws, t)`** - lerps the transform bank from the
  previous frame toward the current one, rebinds pipeline/textures, re-uploads
  vertices and re-issues the draws.
- **`Presenter::PresentInterpolated(t)`** - clears the EFB, replays at t,
  resolves the EFB to a texture and presents it as an ADDITIONAL frame.
- **2D exclusion** - orthographic draws replay at t=1 (screen-space geometry
  must not be lerped).
- **Discontinuity rejection** - if any matrix component moved >50 units in one
  frame (scene cut/camera cut), that draw uses t=1 instead of interpolating.
- **FMV guard** - frames with <16 perspective draws are skipped entirely
  (FMVs blit an image rather than drawing a scene).
- **Pacing** - NOT by sleeping (tried: stalls the video thread, 60 -> 33 FPS).
  Spacing comes from the swapchain: with VSync on a ~120 Hz display, two
  presents per emulated frame land ~8.3 ms apart for free.

## Verified

- Identity replay (t=1) reproduces the frame correctly - this was the key
  result proving capture/replay is faithful.
- Interpolated frames render correctly (scene, HUD, effects).
- Motion is visibly smoother than 60 (user-confirmed).

## Defects, all still open

1. **Texture corruption.** Records hold raw `AbstractTexture*`. Cache entries
   are refcounted and can be freed between capture and replay, showing up as
   untextured/streaked polygons. `TextureCacheBase::Load()` returns a raw
   pointer, so holding a reference needs a cache-side change.
2. **FMV flicker.** Guarded by the <16-perspective-draw heuristic, but the
   guard is untested and probably too crude.
3. **Performance: ~40 FPS.** A second full render pass at 3x internal
   resolution costs ~1/3 of throughput; CPU pegged at 100% of one core.
   Deduplicating the per-draw uniform upload recovered some (45 -> 59) but not
   enough. The interpolated pass should render at reduced internal resolution -
   it is a transient frame - but that needs EFB resize handling.

## Status

Left in the tree, gated behind `PMW2_RECORD_DRAWS` / `PMW2_INTERP`. Default
`./play.sh` is completely unaffected - verified 59.9-60.0 FPS with the flags
unset. The upstream issue (docs/upstream-issues/04) describes the same design
for a proper implementation.

## Reduced-resolution interpolated pass: did NOT fix performance

Rendered the interpolated frame into a half-size sub-viewport of the EFB and
presented that region stretched to full size (quarter the pixels, no EFB
resize, no second render target). `PMW2_INTERP_SCALE`, default 0.5.

Result: 44-59 FPS, CPU still pegged at 100% of one core. Essentially unchanged.

**Diagnosis: the bottleneck is CPU-side draw submission, not pixel work.** Each
replayed frame issues ~300 extra draw calls, and every one carries its own
SetTexture / SetSamplerState / SetPipeline / UploadUniforms / CommitBuffer /
DrawCurrentBatch. Viewport scaling reduces none of that.

This also answers "can it run at any frame rate": no. Each additional
interpolated frame costs another ~300 draw calls on an already-saturated
thread, so the architecture generalises to N frames but the CPU does not.

Fixing it properly means reducing per-draw CPU cost in the replay - sorting by
pipeline/texture to cut redundant state changes, merging compatible batches, or
recording at a lower level so the replay is closer to a raw command buffer
submit. That is renderer optimisation work, and it belongs upstream alongside
the draw-retention feature itself.

## Optimisation attempts, measured

Three attempts at the ~40 FPS problem, each with numbers:

1. **Reduced-resolution pass** (half-size sub-viewport, quarter the pixels):
   44-59 FPS. Essentially no change. Not pixel-bound.
2. **Uniform-upload dedup** (rebuild the 256-float transform bank only when it
   actually changes): 45 -> 59 FPS. Helped some.
3. **Redundant state elimination** (skip unchanged pipeline/texture/sampler
   binds, order preserved - sorting was rejected because it would break alpha
   blending): eliminated **89% of pipeline binds** (274 draws -> 29 binds),
   44% of texture binds, 35% of uniform uploads. FPS: 50-58. CPU still 100%.

Eliminating 89% of pipeline binds changing nothing is decisive: the cost is not
state changes, not pixels, but the irreducible per-draw work - `CommitBuffer`
re-uploading ~1.5 MB of vertex data per frame and ~300 draw submissions.

### The actual fix, not attempted

For an interpolated frame the VERTEX DATA IS IDENTICAL to the real frame - only
the transform matrices differ. So the replay should not re-upload vertices at
all: it should re-issue draws against the GPU buffer region the real frame
already wrote, changing only the uniform block.

That requires the streaming buffer contents to survive from the real frame's
draw to the interpolated present (Dolphin's vertex buffer is written
sequentially and recycled), i.e. buffer-lifetime changes in the video backend.
Done that way the interpolated frame costs one uniform update plus ~300 draw
calls with zero data upload, which is a completely different performance
proposition.

This is the single highest-value follow-up and belongs with the draw-retention
feature in docs/upstream-issues/04.

## SOLVED: vertex buffer reuse fixes the performance problem

The interpolated frame draws the SAME geometry as the real frame - only the
transform matrices differ. So it does not need its vertex data uploaded again:
record where the real frame put it in the GPU streaming buffer (`base_vertex` /
`base_index` returned by `CommitBuffer`) and re-issue `DrawCurrentBatch`
against that, skipping ResetBuffer/memcpy/CommitBuffer entirely.

| metric | before | after |
|---|---|---|
| FPS with interpolation | 44-58, unstable | **59.9, solid** |
| CPU | 100% (pegged) | 89.9% |
| capture volume | ~1.5 MB/frame | 0.46 MB/frame |

Rendering verified correct (geometry, textures, HUD all present).

This confirms the diagnosis chain: not pixel-bound (reduced-resolution pass
changed nothing), not state-bound (89% of pipeline binds eliminated for no
gain), but bound by per-frame vertex upload + CommitBuffer. Removing the upload
also removed the capture memcpy, so both ends got cheaper.

### Remaining defect

Texture corruption. Records hold raw `AbstractTexture*`; cache entries are
refcounted and can be freed between capture and replay.
`TextureCacheBase::Load()` returns a raw pointer, so holding a reference
requires a texture-cache change - genuinely upstream work.

## Transform interpolation: why it fails in real levels

Built the whole pipeline and it works in sparse scenes - confirmed smoother,
119 FPS of genuinely rasterized frames. It does NOT work in a real level, and
the reason is structural rather than a bug that can be fixed.

Interpolating an object's transform requires knowing which draw call in this
frame is the SAME OBJECT as some draw call in the previous frame. The emulator
never receives that information: it sees an anonymous stream of triangle
batches. Every way of reconstructing identity was tried and every one fails in
a busy scene:

| approach | why it fails |
|---|---|
| draw index (draw i vs draw i) | draw counts change every frame - culling, spawning, LOD |
| content signature (pipeline+texture+vert count) | many objects share all of these; LOD swaps change them |
| XF matrix slot | slots are recycled between objects within a frame |

A mismatched pairing lerps an object toward another object's position, which is
exactly the broken geometry observed. In the attract demo (few objects, little
culling) the guesses land often enough to look correct - which is why this
passed every test until a real level was tried. **The attract demo was not a
valid proxy and testing only there was the process failure here.**

This is why Ship of Harkinian and Zelda 64: Recompiled implement transform
interpolation ENGINE-SIDE: with decompiled source, every object is a named
entity with a persistent transform, so identity is free. From outside the game
it must be inferred, and inference is unreliable by construction.

### What remains valid

The rest of the machinery is sound and was individually verified:
- draw capture (~0.5 MB/frame) and faithful identity replay (pixel-correct)
- rendering interpolated frames to the EFB and presenting them separately
- swapchain-based pacing (VSync on a 120 Hz display spaces them for free)
- 2D/HUD exclusion, FMV guard, scene-cut rejection
- vertex-buffer reuse (offsets, not copies) - the fix that made it full speed

Any engine-side implementation would still need all of the above; only the
identity problem is unsolvable from here.

### Status

The 120 FPS menu option is REMOVED and capture is permanently disabled. The
code is retained for reference. Default play is 60 FPS, unaffected.

---

# Transform interpolation: final state after the deep debugging sessions

Eight rounds of fixes, each a real bug found from the user's own gameplay
captures. Final architecture of the recorder/replayer, all in
VertexManagerBase / Present / BPFunctions / TextureCacheBase:

1. Per-draw capture: pipeline, refcounted textures+samplers, vertex/index
   buffer OFFSETS (current-frame replay - offsets stay live), projection,
   posnormalmatrix block, texmatrices, transformmatrices bank, ortho flag.
2. EFB clears recorded and replayed in order; trailing clears carried to the
   next frame's list (the game clears before its first draw).
3. Identity pairing: signature (pipeline+textures+counts) + occurrence order,
   with graceful fallback: unmatched draws render at current position.
4. THE key discovery: non-skinned geometry is transformed by
   constants.posnormalmatrix - NOT the transformmatrices bank, which only
   per-vertex-indexed (skinned) draws read. Position rows lerped per draw.
5. Full VertexShaderConstants snapshot/restore around replay - without it the
   REAL frames inherit interpolated constants (games set projection once per
   scene) and everything corrupts persistently.
6. Replay presents via EFB resolve between real presents; swapchain VSync on
   a ~120 Hz display paces the pairs.

## Current quality

- World geometry, characters, HUD and text all render correctly at ~119 FPS.
- Confirmed visibly smoother by the user.
- REMAINING artifacts: occasional misplaced backdrop/sky quad and small
  missing geometry chunks. Root cause: state still not captured per draw -
  viewport/scissor changes, TEV/pixel constants, indirect texture state.

## Why iteration stopped

Each fix reveals the next missing piece of per-draw GPU state. A faithful
replay needs the complete state stream - which is what FifoRecorder captures.
The incremental recorder asymptotes; completing it means recording at the
FIFO level with live playback, i.e. the upstream feature described in
docs/upstream-issues/04 (now with a working prototype and this bug ledger as
the design record).

Shipped state: 60 FPS default (untouched, verified), 120 FPS as an explicitly
experimental menu option with the quality above.

---

# Transform interpolation: closed. Root cause of the failure to converge.

Twelve rounds of fixes. Each found a real bug; none produced a usable feature.
The decisive experiment came last and should have come first:

**Forcing draw_t = 1.0** (replay every draw at its exact current pose, zero
interpolation) STILL produced shattered geometry. That proved the corruption
was in the capture/replay data path, not the interpolation - which means the
pairing, occurrence-ordering, rotation-guard and frame-skip work of the
preceding rounds was addressing a non-problem.

## The one genuinely proven bug (worth keeping)

Vertex data was captured AFTER `CommitBuffer`. On Vulkan `CommitMemory`
advances the stream-buffer ring, so reading the mapped region afterwards
returns recycled bytes. Capturing before the commit fixed the shard corruption
outright (verified: correct Pac-Man, logo, menu text, water at 114 FPS).

## Why it still did not work

With that fixed, background terrain was missing and artifacts remained, and
throughput had degraded 119 -> 93 FPS as capture costs accumulated. Each
remaining artifact is another slice of per-draw GPU state not being reproduced
(TEV/indirect state, vertex format details, blend/depth config beyond the
pipeline object, ...). There is no reason to expect the list to terminate: a
faithful replay needs the COMPLETE command stream, which is precisely what
`FifoRecorder` captures and what a piecewise reconstruction cannot.

## Method note

The isolation test (force t=1; if still broken the bug is in the data path,
not the math) is the single most valuable diagnostic here and takes one build.
Use it FIRST next time.

## Disposition

120 FPS option removed from the menu; capture permanently disabled; the
recorder/replayer code retained for reference. Port ships at native 60.
The upstream case (docs/upstream-issues/04) now carries: a working
capture/replay/present/pacing prototype, the complete list of per-draw state
that must be reproduced, this bug ledger, and the CommitBuffer ordering trap.

---

## Final outcome (2026-09-02): interpolation removed, port ships at 60

Transform interpolation was pursued to the point of rendering visibly smoother
frames at 119 FPS, and then to a narrower version that replaced only the VI
duplicate frames of 30 FPS cutscenes. Both were removed.

The narrow version failed on its own terms: artifacts during loading, and 53 FPS
where it should have produced 60 — the extra render cost more than the half
frame it was filling. Before that, a stale always-on interpolation path left
over from the 120 FPS work was still running alongside it, which is why the
first test read 120 FPS instead of 60.

All of it is now gone rather than merely disabled: ~29 KB across
`VertexManagerBase.{h,cpp}` (the draw recorder, arenas, replay engine and
per-draw capture), `Present.{h,cpp}` (`PresentInterpolated`), the `RecordClear`
call in `BPFunctions.cpp`, the EFB-copy epoch in `TextureCacheBase.cpp`, and the
support accessors added for it (`GetBoundTextures`, `GetIndexDataStart`,
`GetStoredViewportAndScissor`) plus the `g_hifps_*` atomics. The build has no
unused-variable warnings left from it and measures a steady 59.9 FPS.

The conclusion from the whole investigation stands: this engine is fixed-step,
every route to a genuinely higher guest frame rate was eliminated by
measurement, and interpolation could not be made to render correctly in real
levels. 60 FPS, rendered honestly, is the ceiling here.

---

# Transform interpolation, round 13 (2026-09-04): the four real bugs, found by audit before writing any code

The user asked for interpolation back, "done correctly, without guessing". Rather than
re-implement, the per-draw state a replay must restore was audited exhaustively against the
code first. That found the actual causes of the twelve-round failure. All four are invisible
to the `draw_t = 1.0` isolation test, which is why that test "proved" the maths innocent and
the search never terminated.

1. **`m_base_buffer_pointer` is not this draw's vertex start on Vulkan.** `VKVertexManager::
   ResetBuffer` sets it to `m_vertex_stream_buffer->GetHostPointer()` - offset 0 of the whole
   48 MB ring (VKVertexManager.cpp:166) - while the draw's vertices begin at
   `GetCurrentHostPointer()` (line 168), typically megabytes further in. Reading
   `[m_base_buffer_pointer, m_cur_buffer_pointer)` returns ring contents shifted by an
   arbitrary offset: shattered geometry, every draw, at any t. The base class version
   (VertexManagerBase.cpp:342-348) DOES set it to the allocation start, which is why the
   formula looks right and works on Null/SW. Correct range:
   `[m_cur_buffer_pointer - num_verts*stride, m_cur_buffer_pointer)`.
   Upstream trips on this too: `CalculateZSlope` (line 720) compares
   `(m_cur_buffer_pointer - m_base_buffer_pointer) < stride*3`, meaningless on Vulkan.
   Note the mapped region is `HOST_ACCESS_SEQUENTIAL_WRITE` (VKStreamBuffer.cpp:50) -
   write-combined, so reading it back per draw is slow as well as wrong.

2. **`BindTextures(used_textures, samplers)` does not bind the textures you pass it.** It has
   no texture parameter; it binds live `m_bound_textures[i]` (TextureCacheBase.cpp:1072-1086).
   `used_textures` is only a mask. Every replayed draw therefore samples whatever was bound
   LAST in the real frame. That is "background terrain was missing", and it also survives
   `draw_t = 1.0`.

3. **Uniform dirty flags gate both the upload and the descriptor offset.**
   `VKVertexManager::UpdateVertexShaderConstants` (line 206) early-returns on `!dirty` without
   calling `StateTracker::SetGXUniformBuffer()`, so the descriptor still points at the previous
   draw's slice. A replay that writes constants without setting `dirty` on all three managers
   draws every batch with the PRECEDING batch's matrices - a one-draw lag, not a bad lerp.

4. **Viewport and scissor are sticky dynamic state.** `BPFunctions::SetScissorAndViewport` runs
   only when `XFStateManager::DidViewportChange()` fires inside `VertexShaderManager::SetConstants`
   - once per change, not per draw. Replaying N draws without restoring them gives every draw
   the last draw's viewport. The pipeline's only dynamic states are viewport and scissor
   (VKPipeline.cpp:390-393).

Corrections to the old post-mortem: "blend/depth config beyond the pipeline object" cannot
exist - `UpdatePipelineConfig` folds Rasterization/Depth/Blending state plus shaders, vertex
format and framebuffer_state into one `AbstractPipelineConfig` and VKPipeline bakes all of it.
"TEV/indirect state" and "vertex format details" are likewise not loose: TEV/indirect live
inside PixelShaderConstants, and the vertex format is `m_config.vertex_format` in the pipeline.
Also: capture must happen between `pixel_shader_manager.custom_constants = ...` and
`UploadUniforms()`, because `Geometry/PixelShaderManager::SetConstants` mutate the blocks
INSIDE `RenderDrawCall`.

## Why it is still not buildable as a draw replay

Fixing all four would still not produce a working feature:

- **A frame is not a list of draws.** EFB clears, EFB->VRAM copies, EFB->RAM copies (which
  write guest memory and must never be re-issued), pixel-format reinterpretation and the XFB
  copy all happen outside `Flush()`. Any effect that copies the EFB mid-frame and samples it
  later reads, on replay, what that entry held at END of frame. The replay stream would have to
  interleave clears and copies in original order - that is the FIFO stream, not a draw list.
- **Texture contents cannot be pinned.** `InvalidateTexture` moves the AbstractTexture out of a
  still-live entry; render-target textures are recycled within the same frame;
  `DoPartialTextureUpdates` blits into a live entry in place. `AcquireContentLock()` is not a
  way out - a locked entry makes partial updates `PanicAlertFmt` and return null.
- **Presentation mismatch.** `Presenter::Present` presents the XFB cache entry, carrying copy
  filter, gamma LUT, y-scale and stitching. A tween resolved from the EFB gets none of that, so
  real and interpolated frames differ in brightness and sharpness and alternate at 60 Hz -
  flicker even with perfect geometry.
- **Object identity is not recoverable**, and this is fatal on its own. Interpolation must pair
  an object in frame N with the same object in frame N-1. Draw index, content signature and XF
  matrix slot were all tried in the earlier rounds and all fail in a busy scene.

## What could work instead

Image-space, at present time, where none of the above applies. The strongest variant is
**camera reprojection**: warp the last presented frame using the view/projection delta and the
depth buffer. It needs no object identity (the fatal blocker), no draw capture, and no texture
lifetime guarantees; objects moving relative to the world are wrong but camera motion dominates
perceived smoothness in this game. Any interpolation costs one full frame (16.68 ms) of input
latency by construction, since the tween can only be shown once frame N exists.

Worth knowing: the user's display runs at 119.86 Hz, so there IS somewhere to put a tween.

## Method note that generalises

Cross-run frame comparison does not work on this port: two launches of an identical build
differ by ~83% of pixels, because the attract demo drifts. Any A/B of rendering must happen
within ONE run - e.g. with F10 pause holding the scene still while a toggle is flipped.
`tools/framecmp.py` implements the capture/compare and was calibrated to find this.

## Step 2 (2026-09-04): the reprojection warp, isolated and verified

Built the depth-based camera warp as `VideoCommon/Reprojection.{h,cpp}` plus
`FramebufferShaderGen::GenerateReprojectionPixelShader`, with the shader generator
living beside the other framebuffer utility shaders because its `EmitSamplerDeclarations`
/ `EmitPixelMainDeclaration` helpers are file-internal there.

Modes exist purely so the pass can be tested before it is trusted, which is the
step the twelve-round attempt skipped: `identity` (must reproduce the frame),
`delta` (the measured camera delta, scaled), `synthetic` (a fixed sideways
translation, so depth is testable in a scene whose real camera is static).
Selected by `MODERNGEKKO_REPROJECT` / `MODERNGEKKO_REPROJECT_SCALE`; unset is Off.

**The bug that cost the most, and would have been invisible without the solid-colour
test:** the warp was originally invoked between `g_gfx->BindBackbuffer()` and
`RenderXFBToScreen()`. Its `SetAndDiscardFramebuffer` stole the binding, so the
subsequent blit drew into the reprojection target instead of the screen and the
window showed the cleared backbuffer - a pure black screen with no error anywhere.
Making the shader emit solid red distinguished "pass not reaching the screen" from
"sampling wrong" in one build. The fix is ordering: run the warp BEFORE the
backbuffer is bound and hand the result to the blit.

Results:
- `identity` renders a clean, undistorted frame. That exercises the full
  inverse-projection -> projection round trip, so a wrong matrix layout or a bad
  `Matrix44::Inverted()` would show as visible distortion. It does not.
- `synthetic` at a large scale produces depth-dependent displacement: near
  geometry moves differently from the background, with a visible seam where
  warped pixels leave the screen and hit the unwarped fallback. Parallax is the
  only thing that can produce that, so depth is genuinely driving the warp.
- Default (no env) costs 62.6% of a core against a 61.8% baseline, and renders
  identically to before.

Also worth recording: `ResolveEFBDepthTexture(region, force_r32f=true)` is the
right accessor rather than `GetEFBDepthTexture()`, because with MSAA on the raw
EFB depth texture is multisampled and binding it to a plain `sampler2DArray` is
invalid.

Watch out: the in-game menu's MSAA/SSAA settings drifted to 1x/off during this
work and had to be restored to 8x/on. Check `userdata/Config/GFX.ini` after any
session that touches graphics settings.

Next is step 3, pacing: present a tween between real frames. Everything before
that is verified; the warp itself is no longer a source of risk.

## Step 3 (2026-09-04): pacing - double-rate presentation, working

Presents a second, extrapolated frame after each real one. On the 119.86Hz display
a 60Hz game then fills both refreshes instead of the same image being scanned out
twice. Enabled by `MODERNGEKKO_INTERPOLATE=1` (with `MODERNGEKKO_REPROJECT=delta`),
or by `out/linux/PacManWorld2-Linux64/play-interpolated.sh`. Off by default.

**Extrapolation, not interpolation.** A tween BETWEEN two real frames cannot be
shown until the later one exists, which costs a full frame of input latency.
Warping forward from the frame just rendered costs none. The trade is that the
extra frame is wrong by however much the camera's motion changed within one
frame, which at 0.02 units of frame-to-frame change (measured in step 1) is small.

**The pacing constraint, and why the feature implies dual core.** The budget is
16.7ms per guest frame; emulation needs ~10.3ms of it. Under FIFO vsync a second
present waits a full 8.3ms refresh, and in single-core mode the same thread runs
the guest, so that wait comes straight out of emulation. Measured: guest fell to
17.61ms / 56.8Hz with 43.9% of frames over 18ms, and the presented rate got WORSE
rather than doubling. With a separate video thread the guest holds 16.68ms /
59.9Hz at 0.81% over 18ms. `dolphin_runtime.cpp` therefore sets MAIN_CPU_THREAD
when the feature is on, for that run only, rather than performing badly in silence.

Note this makes dual core a cost of the feature: on the baseline it measured
worse for stutter (1.4% of frames over 18ms against 0.00% single-core).

**Cadence must be constant.** When the camera estimate is untrustworthy - a cut,
or too few draws - Warp returns null. Skipping the second present drops the
presented cadence from 120 to 60 and back, which reads as judder; presenting the
real frame again instead keeps it at 120, and a duplicate is exactly what the
display would have scanned out anyway. Before this fix the counter alternated
between 118 and 59.9; after it, median 119.9.

**Measured, via a present counter** (`MODERNGEKKO_LOG_PRESENTS`) - render_times.txt
counts guest frames and cannot answer this:
- interpolated: median 119.9 presents/sec, max 122.4, >=110/sec for 70% of seconds
  (the remainder are loading screens and 30Hz cutscenes, where the game itself is
  not producing 60 unique frames)
- default `play.sh`: unchanged, single core, no interpolation messages

Open: the extrapolated frame carries objects that move relative to the world by
the camera warp alone, and disocclusions fall back to the unwarped pixel. Whether
that reads as smoother in motion is a judgement call for the player, not
something these measurements can settle.

## Menu integration and two bugs the player found (2026-09-04)

Frame interpolation is now a checkbox in the Escape menu, backed by
`GFX_FRAME_INTERPOLATION` (`GFX.ini [Settings] FrameInterpolation`). Like the
widescreen toggle it applies on Restart, because it decides whether dual core is
enabled at boot; the menu says so rather than pretending to toggle live.
`MODERNGEKKO_INTERPOLATE` still overrides it for testing.

**Bug 1: the menu flickered.** The second present deliberately skipped ImGui, so
the menu and FPS counter appeared on only every other present - a hard 60Hz
flicker over an otherwise 120Hz image. `OnScreenUI::DrawImGui()` only reads
`ImGui::GetDrawData()` and re-uploads it, consuming nothing, so it can safely
render the same frame's draw data twice. Verified: menu present in 12/12 rapid
captures, where before it was on half of them.

**Bug 2: "the textures a bit buggy" - a real 10% depth misalignment.** The warp
samples colour from the XFB copy and depth from the EFB at the same normalized
UV. Measured, those do not cover the same region: the XFB texture here is
640x480 while the EFB is 1920x1584, i.e. 3x the GameCube's native 640x**528**.
So every depth lookup was about 10% too far down the buffer, putting silhouettes
in the wrong place - visible as artifacts around edges. Fixed with a
`depth_uv_scale` uniform of `xfb_size / (EFB_WIDTH, EFB_HEIGHT)`. Note the fix
assumes the XFB copy is top-left aligned in the EFB, which holds for this game;
a game copying from an offset would need that offset passed too.

The `xfb_rect` itself covered the whole XFB texture (0,0 640x480), so the
sub-rectangle case did not bite - but it exists and would need the same
treatment. `MODERNGEKKO_LOG_XFBRECT=1` prints the geometry once.

## The actual bug (2026-09-04): the warp ran backwards

Everything before this was chasing the wrong thing. Two errors compounded:

**1. A bogus test.** The "prediction strength zero" run set
`MODERNGEKKO_REPROJECT_SCALE=0`, but in double-rate mode the tween scale was a
hardcoded `0.5f` in `Present.cpp`; the env var only reached the single-present
test path. The user was still looking at a full 0.5 warp, so "artifact persists
at zero => the warp is innocent" proved nothing, and three conclusions built on
it (depth, void, presentation) were wrong. The tween scale is now
`Reprojection::TweenScale()`, which honours the env var, so a scale of 0 is a
genuine duplicate.

**2. The direction was inverted.** The shader is a BACKWARD-mapping resampler:
for each output pixel it computes a source coordinate and samples there. That
question - "where was this content in the source?" - is answered by the INVERSE
of the camera motion. The code fed it the FORWARD motion (where the point goes
next), so every tween was extrapolated to N-0.5 instead of N+0.5. At 120Hz the
sequence became N, N-0.5, N+1, N+0.5, ... - a 60Hz oscillation of the whole
image, present ONLY when the camera moves, which is exactly the report. Neither
the identity test nor the synthetic-shift test can catch a sign error unless
the sign is checked; they were not. Fixed by inverting the half-step as a rigid
transform (R^T, -R^T t) before uploading it.

**Verified with a known-answer test.** Synthetic mode moves objects +x in view
space, so the displayed image must shift RIGHT and a backward warp must sample
LEFT; at the left edge that runs off the texture and is clamped, repeating the
edge column. Counting columns EXACTLY identical to the edge column: left 200
(capped), right 1, across 8 frames. The left edge is the stretched one - the
direction is correct. Note the loose detector (adjacent-column diff < 1.5)
scored both edges ~1.0 because dark cave textures barely vary column to
column; a clamped edge is exactly identical, so the strict test is the one that
means anything.

Conclusions withdrawn: the "depth reads flat 0" finding and the "void" finding
were real observations but were never the cause of the reported artifact.

## Step 3, done right (2026-09-04): single-core 120Hz without dual core

The double-present no longer needs a second CPU thread, and no longer blocks.

**Why the first design starved the guest.** Under FIFO every present blocks until
a refresh. In single-core mode the presenting thread is the guest thread, so the
second present's 8.3ms wait came straight out of the 16.7ms emulation budget:
measured 56.8Hz with 44% of frames late. Forcing dual core hid that but brought
its own desync artifacts (hard-edged missing geometry during fast camera moves
- visible in the user's F9 captures, which show the REAL frame the warp never
touches).

**The fix, in two parts.**
1. `VKSwapChain.cpp`: when interpolation is on, prefer `VK_PRESENT_MODE_MAILBOX_KHR`
   over FIFO. Still tear-free, but the present returns immediately. Verified
   available on this RADV/X11 setup via vulkaninfo.
2. `Present.cpp`: the tween is not presented inline. After the real present,
   `CoreTiming::ScheduleEvent(ticks_per_second / 120, m_tween_event)` queues it half a
   guest frame later on the same thread; the callback blits the tween (or the
   real frame again when the camera estimate is untrustworthy, to keep cadence)
   and presents. `RemoveEvent` first, since only one instance may be queued.
   `dolphin_runtime.cpp` no longer forces `MAIN_CPU_THREAD`.

Measured on the final build, single core (`CPU-GPU thread`), interpolation on:
guest median 16.68ms, worst 16.83ms, 0.00% over 18ms - identical to the original
60Hz baseline. Stage counters (`MODERNGEKKO_LOG_PRESENTS`) show
scheduled == fired == presented with zero bails.

**A second bug the scheduling exposed: ImGui frame lifecycle.** `Present()` ended
with `BeginImGuiFrame` (`ImGui::NewFrame`), and `imgui.cpp:5377` sets
`DrawDataP.Valid = false` there. The scheduled tween fired AFTER it and redrew
invalidated draw data - the FPS badge vanished from every frame, and invalid
ImGui buffers drawn over the image are a plausible contributor to "textures
bugging out". Fix: `m_tween_pending` defers `BeginImGuiFrame` into the tween
present; `Present()` runs it itself if a pending tween was cancelled, so ImGui
can never stall. Badge present in 6/6 grabs afterwards.

**Reading the present counter correctly.** presents/sec = real + tween, so it
doubles the CONTENT rate: 30Hz movie sections read 60, 60Hz gameplay reads ~120
(122.4 observed). Sampling during the intro movie and concluding "not doubling"
was a measurement error made twice in this session.

## The tween was softer than the real frame (2026-09-04)

"Smooth but the textures are buggy" - timing and direction right, content wrong.
The real frame is the 640x480 XFB upscaled once. The tween was that XFB resampled
bilinearly AT 640x480 with a fractional shift, then upscaled: two passes. A
half-step tween shifts ~0.45px at that scale (camera ~1 unit/frame at depth ~350,
~0.9px/unit), and a half-texel bilinear shift is a 2-tap box filter. Measured on
IDENTICAL content offline: the two-pass tween keeps only 77% of the real frame's
Laplacian variance. Alternating sharp/soft at 120Hz reads as textures crawling.
(The in-engine cross-run sharpness comparison was inconclusive because scene
content dominates the metric far more than a filter pass - scene drift again.)

Fix: the warp renders at the on-screen blit size and samples the XFB through the
same crop the real frame uses (`src_rect` uniform), then is blitted 1:1. One
filtering pass, identical to the real path, by construction. `Warp()` now takes
`out_width/out_height/source_rc`; `Present()` computes the blit rects before
warping (they depend only on presenter state).

## Final pass (2026-09-04): the three residual symptoms, each with its mechanism

**Wobble on near objects -> rotation-only warp.** Translation reprojection needs
per-pixel depth; done at one representative depth, every object nearer or farther
than it lands wrong on the tween and snaps back on the real frame. Rotation
reprojects every pixel exactly at any depth (a homography), and this camera is
rotation-dominated (0.1-0.6 deg/frame vs ~0.16 deg angular effect from
translation at depth ~350). Translation is now off by default;
`MODERNGEKKO_INTERP_TRANSLATE=1` restores the approximation. Cost: pure forward
running gets 60Hz cadence for the translational component (no artifact, less gain).

**Edge smear on fast pans -> feathering.** Clamped sampling repeats the edge texel;
skipping the warp leaves a seam. Displacement now fades to zero across the outer
24 px of the output (`params.yz` carries the output size), so nothing is sampled
off-frame and there is no seam.

**Residual shimmer -> tween queued at 0.4 frame, representing 0.5.** Under MAILBOX
the refresh shows whatever was queued last before the vblank; queuing exactly at
the 8.3ms boundary let jitter push tweens into the next window where the next
real frame replaced them - a silently dropped tween is a 60Hz beat. Queued at
ticks/150 (6.7ms) instead: measured offsets median 6.1-6.6ms, max 7.87ms, 23 of
11324 past 8ms. Also verified the warp's sampler (`GetLinearSamplerState`) equals
the real blit's, so there is no per-frame filter mismatch.

**Ruled out, with numbers:** a MAILBOX acquire stall on the guest thread.
`PresentBackbuffer` blocked at most 1.65ms (real) / 4.86ms (tween) over 228 s, and
the 11 seconds containing a guest frame >18ms had presents blocking <=0.9ms. The
guest-pacing spread seen across runs of the SAME binary (2.57% vs 0.68% >18ms)
is the attract demo's scene variance (baseline measured 0.00-1.50%), not the
present path.

Final measured state, single core: 164/228 s at >=110 presents (peak 123.9),
guest median 16.68ms, every scheduled tween presented, FPS badge on every frame.

## Final outcome, second time (2026-09-04): reprojection removed entirely

The player's remaining complaint was that "the frames don't blend together when
moving the camera". Rotation-only warping put the tween exactly on top of the
real frame under translation, so the two frames were visibly the same image at
60Hz cadence; restoring translation needs per-pixel depth. Two things were
established while chasing that, and both are recorded because they are the
reason the approach stops here:

1. **The EFB depth is gone by the time the frame is presented.** The warp shader
   sampled the resolved EFB depth at `Present()` and read 1.0 at every pixel.
   `PeekEFBDepth` at the same point returned plausible values (0.986 at the
   centre), but it serves from the peek cache that `EndOfFrame()` refreshes -
   a pre-clear snapshot, not the live buffer. Any per-pixel-depth warp therefore
   has to capture depth at EFB-copy time, before the game's clear, which means
   a depth copy per XFB copy and a second texture carried to Present.
2. **The projection uniform was the last matrix set, not the scene's.** It read
   as all zeros on the first frames and, in general, `VertexShaderManager::
   constants.projection` after a frame is whatever the HUD set last. The
   perspective projection must be latched at the last perspective draw.

Both are fixable, but each is another round on a feature whose every previous
round produced a new class of artifact for the player. The user called it:
"Give up on the interpolation", then "Remove the interpolation code
completely". Removed: `CameraTracker`, `Reprojection`, the warp shader, the
MAILBOX present-mode switch, the CoreTiming-scheduled tween present, the
`FrameInterpolation` setting and its menu checkbox, the camera-tracker hook in
`VertexManagerBase::Flush`. The tree is back to the v1.0.3 design plus the one
thing this effort found that helps everyone: the shader cache fix below.

Two process lessons, again: (a) two full "the shader change has no effect"
rounds were a stale process - `cp` had failed with "Text file busy" - so the
md5 of the running binary is the first thing to check, not the last; (b) a
readback API that looks live may be a cache.

## The one keeper: the shader cache never persisted (2026-09-04)

Found while profiling the Clyde boss fight, which stuttered on smoke and fire.
`UICommon::CreateDirectories()` is only called from DolphinQt's `main()`, which
this port does not build, so `Cache/` never existed. `ShaderGenCommon`'s
`File::CreateDir` for `Cache/Shaders/` is non-recursive and failed on the
missing parent on every launch. Every session therefore started with "Loaded 0
cached shaders", and each effect the player had not yet seen in THAT session
drew through the ubershader while its specialised shader compiled. With SSAA
on, that is per-sample shading, so the ubershader ran once per MSAA sample on
every covered pixel - exactly the smoke-and-fire moments. One call added after
`UICommon::Init()` in `dolphin_runtime.cpp`; the cache now fills across
sessions. Shipped as patch 08.
