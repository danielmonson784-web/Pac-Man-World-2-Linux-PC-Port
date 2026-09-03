# Feature request: retain draw calls per frame so they can be re-issued (enables transform interpolation / high framerate)

**Repo:** ExpansionPak/ModernGekko (video backend, vendored Dolphin)

## What this would enable

True high-framerate rendering for fixed-step GameCube titles, the way
Ship of Harkinian and Zelda 64: Recompiled do it — game logic keeps ticking at
60 Hz while the renderer draws real geometry at interpolated positions between
ticks. Unlike image-space frame generation, the extra frames are genuinely
rasterized, so there are no warping artifacts and no added input latency.

Crucially this does NOT require raising the VI rate, which is what makes it
viable where VI overclock is not: the guest still runs at 60, so its once-per-
frame work (notably audio buffer submission) is untouched.

## Why it isn't possible today

`VertexManagerBase::Flush()` is the single choke point where every draw
resolves, and nothing it produces is retained:

- vertex data is streamed into a recycled buffer
  (`m_base_buffer_pointer` .. `m_cur_buffer_pointer`, reset in `ResetBuffer`)
- indices come from `m_index_generator`, likewise transient
- the resolved state (pipeline object, sampler states, texture cache entries
  from `g_texture_cache->Load(i)`, shader constants) is applied and discarded

The only replay mechanism in the tree, `FifoPlayer`, works by replacing the CPU
core, so it cannot run alongside live emulation.

## The transforms themselves are already trackable

This is the encouraging part: GameCube games upload object transforms into XF
matrix memory and reference them by slot index, so a stable per-object identity
already exists in the emulator:

- `xfmem.posMatrices[]` / `xfmem.normalMatrices[]`
- `VertexShaderManager` copies them into
  `constants.transformmatrices[]` / `constants.normalmatrices[]`
- `VertexLoaderManager::position_matrix_index_cache` gives the per-draw slot

So the interpolation itself is straightforward once the draws can be re-issued:
keep frame N-1's matrix bank, lerp against frame N's, upload, redraw.

## Suggested shape

1. **Optional per-frame draw recorder.** In `Flush()`, when enabled, append a
   record: vertex bytes (copied, not referenced), index list, the vertex
   format, the resolved pipeline config, sampler states, texture cache entry
   references, and the shader constant blocks. Cleared each frame.
2. **Replay entry point** that re-issues those records with a supplied matrix
   bank, going through the existing `CommitBuffer` / `UploadUniforms` /
   `DrawCurrentBatch` path.
3. **A present path not driven by VI.** `Presenter::Present()` is already
   callable outside `VISwap`; an interpolated frame would render to an XFB-like
   target and present between real frames.
4. **Exclusion rules.** UI, particles and anything that teleports must not
   interpolate. A per-draw heuristic (orthographic projection, or matrix delta
   above a threshold) covers most cases.

The main open risk is lifetime: texture cache entries can be evicted between
capture and replay, so records need to hold references or be invalidated with
the cache.

## Context

Found while trying to run Pac-Man World 2 (GP2E) above 60 FPS on a 120 Hz
display. Every alternative was tested and eliminated:

- VI overclock: 1.5x reaches only ~73 FPS and breaks audio and the title
  screen; 2.0x crashes. Audio breaks because the guest submits audio buffers
  once per frame, so more frames means more submissions.
- Removing the guest's own vblank wait (`bl VIWaitForRetrace` at 0x800056BC,
  NOPed, module rebuilt): throughput got WORSE, 49-54 FPS, because presents are
  gated by VI scanout rather than by the guest wait.
- Scaling the guest's time base: fully solved (0x8050C3F4 is the game's global
  time scale, upstream of its dt/frames/seconds fork) but it only corrects
  speed, it cannot create frames.

Transform interpolation is the only remaining approach, and draw-call retention
is the one missing primitive.

---

## Outcome in this port

Implemented against a local Dolphin tree and then removed. Worth recording
before anyone repeats it: capture and replay were made to work, and produced
visibly smoother motion, but the replayed frames never rendered correctly in
real levels — artifacts on load, and 53 FPS where the extra render should have
filled a 30 FPS gap to 60. The port ships at a straight 60 instead.

That is not an argument against the feature request. It is an argument that
doing it *outside* the renderer, by reconstructing draw state after the fact,
is the wrong layer — which is precisely why retaining draw calls upstream would
help. Full failure log in `docs/framerate-investigation.md`.
