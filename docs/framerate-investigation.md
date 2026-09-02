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
