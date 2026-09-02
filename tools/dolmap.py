#!/usr/bin/env python3
"""
dolmap.py - Gekko/PowerPC DOL analyzer and DolRecomp symbol-map generator.

Pac-Man World 2 has no public decompilation, so there is no real .map file.
DolRecomp's --map input dramatically improves output (named symbols instead of
bare addresses, and DOLRECOMP_SYMBOL_<name> constants usable from ModernGekko
code mods). This tool recovers function boundaries directly from the binary and
emits a map in the 3-column form DolRecomp's parser accepts:

    <hex address> <hex size> <name>

Entry points are recovered from four independent sources:
  1. the DOL entry point
  2. every `bl` target (a call proves a function starts there)
  3. instructions following a terminator + alignment padding
  4. word-aligned pointers into .text found in data sections
     (vtables, jump/handler tables, callback arrays)

Subcommands:
  sections <dol>              print the DOL section table
  scan     <dol>              recover functions and print statistics
  map      <dol> -o <f.map>   write a DolRecomp-compatible symbol map
  smc      <dol>              report cache ops that suggest self-modifying code
"""

import argparse
import struct
from collections import defaultdict

# --- PowerPC encodings -----------------------------------------------------
OP_BC = 16       # bc / bca / bcl / bcla
OP_B = 18        # b / ba / bl / bla
OP_XL = 19       # bclr / bcctr live here
XO_BCLR = 16
XO_BCCTR = 528

BLR = 0x4E800020
BCTR = 0x4E800420

# Cache/sync ops that imply the game rewrites its own instructions.
# DolRecomp cannot translate SMC, so these regions need manual patches.
SMC_OPS = {
    (31, 982): "icbi", (31, 54): "dcbst", (31, 86): "dcbf",
    (31, 1014): "dcbz", (31, 470): "dcbi",
}


def sx(value, bits):
    """Sign-extend `value` from `bits` wide."""
    sign = 1 << (bits - 1)
    return (value ^ sign) - sign


class Dol:
    """A DOL is 7 text + 11 data sections, then bss addr/size and entry point."""

    NUM_TEXT, NUM_DATA = 7, 11
    NUM_SECTIONS = NUM_TEXT + NUM_DATA

    def __init__(self, path):
        with open(path, "rb") as fh:
            self.blob = fh.read()
        if len(self.blob) < 0x100:
            raise SystemExit(f"{path}: shorter than a DOL header")
        h = self.blob
        self.sections = []
        for i in range(self.NUM_SECTIONS):
            off = struct.unpack_from(">I", h, i * 4)[0]
            addr = struct.unpack_from(">I", h, 0x48 + i * 4)[0]
            size = struct.unpack_from(">I", h, 0x90 + i * 4)[0]
            if off and size:
                self.sections.append({
                    "index": i, "name": f"text{i}" if i < self.NUM_TEXT else f"data{i - self.NUM_TEXT}",
                    "offset": off, "addr": addr, "size": size, "text": i < self.NUM_TEXT,
                })
        self.bss_addr = struct.unpack_from(">I", h, 0xD8)[0]
        self.bss_size = struct.unpack_from(">I", h, 0xDC)[0]
        self.entry = struct.unpack_from(">I", h, 0xE0)[0]
        if not self.sections:
            raise SystemExit(f"{path}: no sections -- not a DOL?")

    def text_sections(self):
        return [s for s in self.sections if s["text"]]

    def in_text(self, addr):
        return any(s["addr"] <= addr < s["addr"] + s["size"] for s in self.text_sections())

    def words(self, sec):
        """Yield (vaddr, instruction) for a section."""
        base, off, size = sec["addr"], sec["offset"], sec["size"]
        blob = self.blob
        for i in range(0, size & ~3, 4):
            yield base + i, struct.unpack_from(">I", blob, off + i)[0]


def analyze(dol):
    """Recover function entry points. Returns (entries:set, stats:dict)."""
    entries = set()
    stats = defaultdict(int)
    terminators = set()   # addresses of blr/bctr/unconditional-b

    if dol.in_text(dol.entry):
        entries.add(dol.entry)

    for sec in dol.text_sections():
        for pc, insn in dol.words(sec):
            op = insn >> 26
            stats["instructions"] += 1

            if op == OP_B:
                aa, lk = (insn >> 1) & 1, insn & 1
                target = sx((insn >> 2) & 0xFFFFFF, 24) << 2
                if not aa:
                    target += pc
                target &= 0xFFFFFFFF
                if lk and dol.in_text(target):
                    entries.add(target)          # `bl` proves a function start
                    stats["bl_targets"] += 1
                elif not lk:
                    terminators.add(pc)          # unconditional b == tail call/end

            elif op == OP_BC:
                lk = insn & 1
                if lk:
                    aa = (insn >> 1) & 1
                    target = sx((insn >> 2) & 0x3FFF, 14) << 2
                    if not aa:
                        target += pc
                    target &= 0xFFFFFFFF
                    if dol.in_text(target):
                        entries.add(target)
                        stats["bl_targets"] += 1

            elif op == OP_XL:
                xo = (insn >> 1) & 0x3FF
                bo = (insn >> 21) & 0x1F
                # BO with both bits set == unconditional (blr / bctr)
                if xo in (XO_BCLR, XO_BCCTR) and (bo & 0x14) == 0x14 and not (insn & 1):
                    terminators.add(pc)

    # Source 3: a terminator followed by padding, then real code, starts a function.
    for sec in dol.text_sections():
        base, size = sec["addr"], sec["size"]
        for pc, insn in dol.words(sec):
            if pc not in terminators:
                continue
            nxt = pc + 4
            while nxt < base + size:
                w = struct.unpack_from(">I", dol.blob, sec["offset"] + (nxt - base))[0]
                if w != 0:
                    break
                nxt += 4          # skip alignment padding
            if base <= nxt < base + size and nxt not in entries:
                entries.add(nxt)
                stats["after_terminator"] += 1

    # Source 4: pointers into .text stored in data (vtables, handler tables).
    for sec in dol.sections:
        if sec["text"]:
            continue
        for _, word in dol.words(sec):
            if word % 4 == 0 and dol.in_text(word) and word not in entries:
                entries.add(word)
                stats["data_pointers"] += 1

    stats["terminators"] = len(terminators)
    return entries, stats


def function_ranges(dol, entries):
    """Turn entry points into (addr, size) by walking to the next entry."""
    out = []
    for sec in dol.text_sections():
        lo, hi = sec["addr"], sec["addr"] + sec["size"]
        pts = sorted(a for a in entries if lo <= a < hi)
        for i, addr in enumerate(pts):
            end = pts[i + 1] if i + 1 < len(pts) else hi
            out.append((addr, end - addr))
    return out


def cmd_sections(dol, _):
    print(f"entry point : 0x{dol.entry:08X}")
    print(f"bss         : 0x{dol.bss_addr:08X} size 0x{dol.bss_size:X}")
    print(f"\n{'section':<8} {'file off':>10} {'vaddr':>12} {'size':>12}  {'range':>25}")
    print("-" * 74)
    for s in dol.sections:
        print(f"{s['name']:<8} 0x{s['offset']:08X} {'':>0} 0x{s['addr']:08X} "
              f"{s['size']:>12,}  0x{s['addr']:08X}-0x{s['addr'] + s['size']:08X}")
    code = sum(s["size"] for s in dol.text_sections())
    print(f"\nexecutable code: {code:,} bytes  ({code // 4:,} instructions)")


def cmd_scan(dol, _):
    entries, stats = analyze(dol)
    ranges = function_ranges(dol, entries)
    print(f"instructions scanned : {stats['instructions']:,}")
    print(f"  bl call targets    : {stats['bl_targets']:,}")
    print(f"  after terminator   : {stats['after_terminator']:,}")
    print(f"  data ptr into text : {stats['data_pointers']:,}")
    print(f"  flow terminators   : {stats['terminators']:,}")
    print(f"\nfunctions recovered  : {len(ranges):,}")
    if ranges:
        sizes = sorted(s for _, s in ranges)
        total = sum(sizes)
        print(f"  median size        : {sizes[len(sizes) // 2]:,} bytes")
        print(f"  largest            : {sizes[-1]:,} bytes")
        print(f"  covered            : {total:,} bytes")


def load_names(path):
    """Parse a `<hex addr> = <name>` file of hand-recovered symbol names."""
    names = {}
    if not path:
        return names
    with open(path) as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            if "=" not in line:
                raise SystemExit(f"{path}:{lineno}: expected `addr = name`")
            addr, name = (part.strip() for part in line.split("=", 1))
            names[int(addr, 16)] = name
    return names


def cmd_map(dol, a):
    entries, _ = analyze(dol)
    named = {dol.entry: "__start"}
    named.update(load_names(a.names))
    # A known symbol is a function start even if the scan missed it.
    entries.update(addr for addr in named if dol.in_text(addr))
    ranges = function_ranges(dol, entries)
    with open(a.out, "w") as fh:
        fh.write(".text section layout\n")
        for addr, size in ranges:
            name = named.get(addr, f"fn_{addr:08X}")
            fh.write(f"{addr:08x} {size:08x} {name}\n")
    known = sum(1 for addr, _ in ranges if addr in named)
    print(f"wrote {a.out}: {len(ranges):,} symbols ({known} named, "
          f"{len(ranges) - known:,} auto-generated fn_ADDR)")
    print(f"pass to DolRecomp with:  --map {a.out}")


def cmd_smc(dol, _):
    hits = defaultdict(list)
    for sec in dol.text_sections():
        for pc, insn in dol.words(sec):
            if insn >> 26 == 31:
                key = (31, (insn >> 1) & 0x3FF)
                if key in SMC_OPS:
                    hits[SMC_OPS[key]].append(pc)
    if not hits:
        print("No icbi/dcbf/dcbst/dcbz/dcbi found -- no obvious self-modifying code.")
        return
    for name, addrs in sorted(hits.items()):
        print(f"{name:<6} {len(addrs):>5} site(s)")
        for addr in addrs[:12]:
            print(f"         0x{addr:08X}")
        if len(addrs) > 12:
            print(f"         ... and {len(addrs) - 12} more")
    if "icbi" in hits:
        print("\nicbi means the instruction cache is being invalidated: the game writes")
        print("code at runtime. DolRecomp cannot translate that; those sites need")
        print("hand-written replacements via dolrecomp_dispatch_replacement.")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name, fn, needs_out in [("sections", cmd_sections, False), ("scan", cmd_scan, False),
                                ("map", cmd_map, True), ("smc", cmd_smc, False)]:
        s = sub.add_parser(name)
        s.add_argument("dol")
        if needs_out:
            s.add_argument("-o", "--out", required=True)
            s.add_argument("--names", help="file of `<hex addr> = <name>` overrides")
        s.set_defaults(fn=fn)
    a = p.parse_args()
    a.fn(Dol(a.dol), a)


if __name__ == "__main__":
    main()
