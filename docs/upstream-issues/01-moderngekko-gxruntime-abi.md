# GXRuntime `cpu.h` is missing `cycle_budget`, so every DolRecomp module is rejected

**Repo:** ExpansionPak/ModernGekko
**Component:** `GXRuntime/include/core/cpu.h`

## Summary

`GXRuntime/include/core/cpu.h` declares `GXRUNTIME_CPU_ABI_VERSION 3u` and a
`PPCCpuState` that is missing the `cycle_budget` field which both DolRecomp's
`cpu.h` and ModernGekko's own `cpu_state.h` already have. A module built
against the GXRuntime header therefore stamps ABI **3 / sizeof 3528**, while
the runtime validates against **4 / 3536**, and the load is refused.

The result is that a perfectly good recompiled module fails to load with an ABI
mismatch, on a stock checkout.

## What it looks like

The rejection is easy to misread as a hang rather than an error, because
`--allow-interpreter` swallows it: the module is dropped, execution silently
falls back to the interpreter, and the run reports

```
native=0 cycles=0
```

with no obvious failure. Dropping `--allow-interpreter` surfaces the real ABI
mismatch message. That masking cost me a while to see through, and it might be
worth reconsidering whether a *rejected module* should be silently absorbed by
the interpreter fallback at all — a hard failure, or at minimum a warning,
would be much easier to diagnose.

## Fix

```diff
-#define GXRUNTIME_CPU_ABI_VERSION 3u
+#define GXRUNTIME_CPU_ABI_VERSION 4u
```

and add the field to `PPCCpuState`, after `downcount`:

```diff
     s64 downcount;
+    s64 cycle_budget;
     u8* exram;
```

Placement matters: it has to match the layout in DolRecomp's `cpu.h` and
ModernGekko's `cpu_state.h`, which is immediately after `downcount`.

With that applied, modules stamp 4 / 3536 and load normally.

## Suggestion

The three copies of this struct (GXRuntime `cpu.h`, DolRecomp `cpu.h`,
ModernGekko `cpu_state.h`) drifting apart is the underlying cause, and it will
happen again. A `static_assert` on `sizeof(PPCCpuState)` next to the ABI
version constant would turn a silent runtime rejection into a compile error.

## Environment

Linux (CachyOS, kernel 7.3), GCC, x86-64. Game: a GameCube title recompiled
with DolRecomp and run under ModernGekko.
