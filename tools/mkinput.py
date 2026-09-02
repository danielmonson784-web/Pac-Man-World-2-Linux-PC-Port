#!/usr/bin/env python3
"""
mkinput.py - generate ModernGekko/Dolphin input config for Pac-Man World 2.

Writes <user-dir>/Config/GCPadNew.ini and merges the GameCube port setting into
<user-dir>/Config/Dolphin.ini so port 1 holds a Standard Controller
(SIDEVICE_GC_CONTROLLER = 6).

Port 1 gets the gamepad as its default device and the keyboard OR'd onto every
binding, so both work at once without swapping profiles.

Device strings are `<source>/<index>/<name>`:
  gamepad   SDL/0/<SDL gamepad name>          (same source name on both OSes)
  keyboard  XInput2/0/Virtual core pointer    on Linux/X11
            DInput/0/Keyboard Mouse           on Windows
"""

import argparse
import os

# Gamepad half: the mapping ModernGekko's own GenerateControllerConfig emits.
PAD = {
    "Buttons/A": "`Button A`", "Buttons/B": "`Button B`",
    "Buttons/X": "`Button X`", "Buttons/Y": "`Button Y`",
    "Buttons/Z": "`Shoulder R`", "Buttons/Start": "Start",
    "Main Stick/Up": "`Left Y+`", "Main Stick/Down": "`Left Y-`",
    "Main Stick/Left": "`Left X-`", "Main Stick/Right": "`Left X+`",
    "C-Stick/Up": "`Right Y+`", "C-Stick/Down": "`Right Y-`",
    "C-Stick/Left": "`Right X-`", "C-Stick/Right": "`Right X+`",
    "Triggers/L": "`Trigger L`", "Triggers/R": "`Trigger R`",
    "Triggers/L-Analog": "`Trigger L`", "Triggers/R-Analog": "`Trigger R`",
    "D-Pad/Up": "`Pad N`", "D-Pad/Down": "`Pad S`",
    "D-Pad/Left": "`Pad W`", "D-Pad/Right": "`Pad E`",
    "Rumble/Motor": "`Motor L` | `Motor R`",
}

# Keyboard half, in Dolphin's long-standing default layout. Key NAMES are
# backend-specific: XInput2 reports X keysyms ("Return", "Up"), while DInput
# reports its own uppercase table from NamedKeys.h ("RETURN", "UP"). Letters
# and digits happen to coincide; the arrows and Return do not, and a name that
# does not match simply fails to bind, silently.
KEYS = {
    "Buttons/A": "X", "Buttons/B": "Z", "Buttons/X": "S",
    "Buttons/Y": "A", "Buttons/Z": "C", "Buttons/Start": "Return",
    "Main Stick/Up": "Up", "Main Stick/Down": "Down",
    "Main Stick/Left": "Left", "Main Stick/Right": "Right",
    "C-Stick/Up": "I", "C-Stick/Down": "K",
    "C-Stick/Left": "J", "C-Stick/Right": "L",
    "Triggers/L": "Q", "Triggers/R": "W",
    "D-Pad/Up": "T", "D-Pad/Down": "G",
    "D-Pad/Left": "F", "D-Pad/Right": "H",
}

# XInput2 keysym -> DInput NamedKeys.h spelling, for the ones that differ.
DINPUT_RENAME = {"Return": "RETURN", "Up": "UP", "Down": "DOWN",
                 "Left": "LEFT", "Right": "RIGHT"}

ORDER = ["Buttons/A", "Buttons/B", "Buttons/X", "Buttons/Y", "Buttons/Z",
         "Buttons/Start",
         "Main Stick/Up", "Main Stick/Down", "Main Stick/Left",
         "Main Stick/Right", "Main Stick/Calibration",
         "C-Stick/Up", "C-Stick/Down", "C-Stick/Left", "C-Stick/Right",
         "C-Stick/Calibration",
         "Triggers/L", "Triggers/R", "Triggers/L-Analog", "Triggers/R-Analog",
         "D-Pad/Up", "D-Pad/Down", "D-Pad/Left", "D-Pad/Right",
         "Rumble/Motor"]


def key_name(name, platform):
    return DINPUT_RENAME.get(name, name) if platform == "windows" else name


def build_pad_section(pad_device, key_device, platform):
    """Keyboard anchors the section; every binding names its device explicitly.

    The obvious arrangement is to make the gamepad the section Device, but a
    section whose Device names a pad that is not present leaves port 1 with no
    live device, and the game reports "PLEASE INSERT A CONTROLLER INTO
    CONTROLLER SOCKET 1". The keyboard is always there, so anchoring to it
    keeps the port alive whether or not the pad is plugged in. Everything is
    then fully qualified so nothing depends on which device is the default.
    """
    lines = [f"Device = {key_device or pad_device}"]
    for key in ORDER:
        if key.endswith("Calibration"):
            lines.append(f"{key} = 100.00")
            continue
        parts = []
        if pad_device and key in PAD:
            # PAD values may be an or-list, e.g. "`Motor L` | `Motor R`".
            parts += [f"`{pad_device}:{tok.strip().strip('`')}`"
                      for tok in PAD[key].split("|")]
        if key_device and key in KEYS:
            parts.append(f"`{key_device}:{key_name(KEYS[key], platform)}`")
        if parts:
            lines.append(f"{key} = {' | '.join(parts)}")
    return lines


def merge_ini(path, section, settings):
    """Set key=value under [section], preserving everything else."""
    blocks, current = {}, None
    order = []
    if os.path.exists(path):
        with open(path) as fh:
            for line in fh:
                s = line.strip()
                if s.startswith("[") and s.endswith("]"):
                    current = s[1:-1]
                    if current not in blocks:
                        blocks[current], _ = [], order.append(current)
                    continue
                if current is not None and s:
                    blocks[current].append(s)
    if section not in blocks:
        blocks[section] = []
        order.append(section)
    kept = [l for l in blocks[section]
            if l.split("=")[0].strip() not in settings]
    blocks[section] = kept + [f"{k} = {v}" for k, v in settings.items()]
    with open(path, "w") as fh:
        for name in order:
            fh.write(f"[{name}]\n")
            for line in blocks[name]:
                fh.write(line + "\n")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("user_dir")
    p.add_argument("--pad", help='SDL gamepad name, e.g. "Generic X-Box pad"')
    p.add_argument("--platform", choices=["linux", "windows"], default="linux")
    p.add_argument("--no-keyboard", action="store_true")
    p.add_argument("--background-input", action="store_true",
                   help="keep reading input while the window is unfocused")
    a = p.parse_args()

    pad_device = f"SDL/0/{a.pad}" if a.pad else None
    key_device = None if a.no_keyboard else (
        "DInput/0/Keyboard Mouse" if a.platform == "windows"
        else "XInput2/0/Virtual core pointer")
    if not pad_device and not key_device:
        raise SystemExit("nothing to configure: pass --pad and/or allow keyboard")

    config = os.path.join(a.user_dir, "Config")
    os.makedirs(config, exist_ok=True)

    gcpad = os.path.join(config, "GCPadNew.ini")
    with open(gcpad, "w") as fh:
        for i in range(1, 5):
            fh.write(f"[GCPad{i}]\n")
            if i == 1:
                fh.write("\n".join(
                    build_pad_section(pad_device, key_device, a.platform)) + "\n")
    print(f"wrote {gcpad}")
    print(f"  port 1 gamepad : {pad_device or '(none)'}")
    print(f"  port 1 keyboard: {key_device or '(none)'}")

    dolphin = os.path.join(config, "Dolphin.ini")
    # 6 == SIDEVICE_GC_CONTROLLER; ports 2-4 stay empty (0 == SIDEVICE_NONE).
    merge_ini(dolphin, "Core", {"SIDevice0": "6", "SIDevice1": "0",
                                "SIDevice2": "0", "SIDevice3": "0"})
    # With BackgroundInput off, Dolphin stops reading input the moment the
    # window loses focus, and the game reads that as the pad being unplugged
    # ("PLEASE INSERT A CONTROLLER INTO CONTROLLER SOCKET 1").
    if a.background_input:
        merge_ini(dolphin, "Input", {"BackgroundInput": "True"})
    print(f"wrote {dolphin}  (SIDevice0 = 6, Standard Controller"
          + (", BackgroundInput = True)" if a.background_input else ")"))


if __name__ == "__main__":
    main()
