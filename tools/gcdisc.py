#!/usr/bin/env python3
"""
gcdisc.py - GameCube disc (GCM/ISO) inspector and extractor.

Works on plain GCM/ISO dumps. Also works on NKit-processed images for anything
that lives before the scrubbed region (disc header, apploader, main.dol, FST) --
run `verify` to see how much of the FST is actually reachable in the file.

Subcommands:
  info     <iso>                 disc header summary
  ls       <iso>                 list the filesystem (FST)
  verify   <iso>                 report FST entries whose data is out of range
  dol      <iso> -o <out.dol>    extract main.dol
  apploader <iso> -o <out.bin>   extract the apploader
  extract  <iso> -o <dir>        extract the whole filesystem
  dolphin-dir <iso> -o <dir>     extract to Dolphin's extracted-disc layout
                                 (sys/boot.bin, sys/bi2.bin, sys/apploader.img,
                                  sys/main.dol, sys/fst.bin, files/...), which
                                 ModernGekko's port tool boots directly
"""

import argparse
import os
import struct
import sys

DISC_MAGIC = 0xC2339F3D
HDR_DOL_OFF = 0x420
HDR_FST_OFF = 0x424
HDR_FST_SIZE = 0x428
HDR_FST_MAX = 0x42C
APPLOADER_OFF = 0x2440


def u32(buf, off):
    return struct.unpack_from(">I", buf, off)[0]


class Disc:
    def __init__(self, path):
        self.path = path
        self.size = os.path.getsize(path)
        self.f = open(path, "rb")
        self.hdr = self.f.read(0x2440)
        if len(self.hdr) < 0x440:
            raise SystemExit(f"{path}: too small to be a GameCube image")
        if u32(self.hdr, 0x1C) != DISC_MAGIC:
            raise SystemExit(
                f"{path}: missing GameCube magic 0xC2339F3D at 0x1C "
                f"(found 0x{u32(self.hdr, 0x1C):08X}) -- not a GCM/ISO?"
            )
        self.game_id = self.hdr[0:6].decode("ascii", "replace")
        self.disc_num = self.hdr[6]
        self.version = self.hdr[7]
        self.title = self.hdr[0x20:0x400].split(b"\0")[0].decode("ascii", "replace")
        self.dol_off = u32(self.hdr, HDR_DOL_OFF)
        self.fst_off = u32(self.hdr, HDR_FST_OFF)
        self.fst_size = u32(self.hdr, HDR_FST_SIZE)
        self.fst_max = u32(self.hdr, HDR_FST_MAX)
        # NKit stamps its marker right after the 0x200-byte header block.
        self.nkit = self.hdr[0x200:0x208] == b"NKIT v01"
        self._fst = None

    def read(self, off, size):
        self.f.seek(off)
        return self.f.read(size)

    # -- main.dol -----------------------------------------------------------
    def dol_size(self):
        """A DOL has no length field; its size is max(offset+size) over sections."""
        h = self.read(self.dol_off, 0x100)
        if len(h) < 0x100:
            raise SystemExit("DOL header runs past end of file")
        end = 0x100
        for i in range(18):  # 7 text + 11 data
            off = u32(h, i * 4)
            size = u32(h, 0x90 + i * 4)
            if off and size:
                end = max(end, off + size)
        return end

    def extract_dol(self, out):
        n = self.dol_size()
        data = self.read(self.dol_off, n)
        if len(data) != n:
            raise SystemExit(
                f"main.dol truncated: wanted {n} bytes at 0x{self.dol_off:X}, "
                f"got {len(data)} (image is scrubbed/incomplete?)"
            )
        with open(out, "wb") as fh:
            fh.write(data)
        return n

    def extract_apploader(self, out):
        h = self.read(APPLOADER_OFF, 0x20)
        size = u32(h, 0x14) + u32(h, 0x18)
        data = self.read(APPLOADER_OFF, 0x20 + size)
        with open(out, "wb") as fh:
            fh.write(data)
        return len(data)

    # -- FST ----------------------------------------------------------------
    def fst(self):
        """Parse the FST into a list of (path, is_dir, offset, length)."""
        if self._fst is not None:
            return self._fst
        raw = self.read(self.fst_off, self.fst_size)
        if len(raw) < 12:
            raise SystemExit("FST unreadable (image scrubbed past the FST?)")
        count = u32(raw, 8)
        table_end = count * 12
        if table_end > len(raw):
            raise SystemExit(
                f"FST claims {count} entries ({table_end} bytes) but only "
                f"{len(raw)} bytes are present"
            )
        strings = raw[table_end:]

        def name(off):
            end = strings.find(b"\0", off)
            return strings[off:end if end >= 0 else None].decode("ascii", "replace")

        out = []
        # (end_index, dir_path) stack; the root spans every entry.
        stack = [(count, "")]
        i = 1
        while i < count:
            e = raw[i * 12:(i + 1) * 12]
            is_dir = e[0] == 1
            name_off = int.from_bytes(e[1:4], "big")
            a, b = u32(e, 4), u32(e, 8)
            while len(stack) > 1 and i >= stack[-1][0]:
                stack.pop()
            path = f"{stack[-1][1]}/{name(name_off)}" if stack[-1][1] else name(name_off)
            if is_dir:
                out.append((path, True, 0, 0))
                stack.append((b, path))  # b = index of the first entry after this dir
            else:
                out.append((path, False, a, b))
            i += 1
        self._fst = out
        return out


def cmd_info(d, _):
    print(f"file         : {d.path}")
    print(f"size         : {d.size:,} bytes")
    print(f"game id      : {d.game_id}  (disc {d.disc_num}, rev {d.version})")
    print(f"title        : {d.title}")
    print(f"NKit image   : {'YES - scrubbed/reduced' if d.nkit else 'no'}")
    print(f"main.dol @   : 0x{d.dol_off:08X}  size {d.dol_size():,}")
    print(f"FST @        : 0x{d.fst_off:08X}  size {d.fst_size:,} (max {d.fst_max:,})")
    h = d.read(d.dol_off, 0x100)
    print(f"entry point  : 0x{u32(h, 0xE0):08X}")
    print(f"bss          : 0x{u32(h, 0xD8):08X}  size 0x{u32(h, 0xDC):X}")


def cmd_ls(d, _):
    files = dirs = 0
    total = 0
    for path, is_dir, off, ln in d.fst():
        if is_dir:
            dirs += 1
            print(f"  <dir>                      {path}/")
        else:
            files += 1
            total += ln
            print(f"  0x{off:08X}  {ln:>10,}  {path}")
    print(f"\n{files:,} files, {dirs:,} dirs, {total:,} bytes of file data")


def cmd_verify(d, _):
    bad = []
    total = 0
    rels = []
    for path, is_dir, off, ln in d.fst():
        if is_dir:
            continue
        total += 1
        if off + ln > d.size:
            bad.append((path, off, ln))
        if path.lower().endswith(".rel"):
            rels.append(path)
    print(f"image size        : {d.size:,}")
    print(f"files in FST      : {total:,}")
    print(f"out of range      : {len(bad):,}")
    if rels:
        print(f".rel modules      : {len(rels)}  -> {', '.join(rels[:8])}"
              + (" ..." if len(rels) > 8 else ""))
    else:
        print(".rel modules      : none (statically linked -- everything is in main.dol)")
    for path, off, ln in bad[:20]:
        print(f"  MISSING 0x{off:08X} +{ln:<10,} {path}")
    if len(bad) > 20:
        print(f"  ... and {len(bad) - 20:,} more")
    if bad:
        print("\nThese need the image restored to a plain GCM before they can be read.")
    else:
        print("\nAll file data is present in this image; direct extraction will work.")


def cmd_dol(d, a):
    n = d.extract_dol(a.out)
    print(f"wrote {a.out} ({n:,} bytes) from 0x{d.dol_off:08X}")


def cmd_apploader(d, a):
    n = d.extract_apploader(a.out)
    print(f"wrote {a.out} ({n:,} bytes)")


def cmd_extract(d, a):
    n = skipped = 0
    for path, is_dir, off, ln in d.fst():
        dest = os.path.join(a.out, path)
        if is_dir:
            os.makedirs(dest, exist_ok=True)
            continue
        if off + ln > d.size:
            skipped += 1
            continue
        os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
        with open(dest, "wb") as fh:
            remaining = ln
            d.f.seek(off)
            while remaining:
                chunk = d.f.read(min(1 << 20, remaining))
                if not chunk:
                    break
                fh.write(chunk)
                remaining -= len(chunk)
        n += 1
    print(f"extracted {n:,} files to {a.out}" + (f" ({skipped:,} skipped, out of range)" if skipped else ""))


def cmd_dolphin_dir(d, a):
    """Write the layout Dolphin (and ModernGekko) boots from a directory."""
    sysdir = os.path.join(a.out, "sys")
    filesdir = os.path.join(a.out, "files")
    os.makedirs(sysdir, exist_ok=True)
    os.makedirs(filesdir, exist_ok=True)

    def put(name, data):
        with open(os.path.join(sysdir, name), "wb") as fh:
            fh.write(data)
        print(f"  sys/{name:<16} {len(data):>12,} bytes")

    put("boot.bin", d.read(0, 0x440))
    put("bi2.bin", d.read(0x440, 0x2000))
    d.extract_apploader(os.path.join(sysdir, "apploader.img"))
    print(f"  sys/{'apploader.img':<16} "
          f"{os.path.getsize(os.path.join(sysdir, 'apploader.img')):>12,} bytes")
    d.extract_dol(os.path.join(sysdir, "main.dol"))
    print(f"  sys/{'main.dol':<16} "
          f"{os.path.getsize(os.path.join(sysdir, 'main.dol')):>12,} bytes")
    put("fst.bin", d.read(d.fst_off, d.fst_size))

    a.out = filesdir
    cmd_extract(d, a)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name, fn, needs_out in [
        ("info", cmd_info, False), ("ls", cmd_ls, False), ("verify", cmd_verify, False),
        ("dol", cmd_dol, True), ("apploader", cmd_apploader, True), ("extract", cmd_extract, True),
        ("dolphin-dir", cmd_dolphin_dir, True),
    ]:
        s = sub.add_parser(name)
        s.add_argument("iso")
        if needs_out:
            s.add_argument("-o", "--out", required=True)
        s.set_defaults(fn=fn)
    a = p.parse_args()
    a.fn(Disc(a.iso), a)


if __name__ == "__main__":
    main()
