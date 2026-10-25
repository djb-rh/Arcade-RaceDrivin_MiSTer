#!/usr/bin/env python3
"""Turn a MAME nvram directory for the cockpit set into the sim's power-up
zero-RAM images, so a run can start from a calibrated cabinet exactly as a
MAME run with -nvram_directory does.

    tools/nvram2hex.py <mame nvram dir with mainpcb_200e ...> <out dir>

Writes zram_hi.hex / zram_lo.hex (200E / 210E) and dsk_zram_hi.hex /
dsk_zram_lo.hex (DSK 10C / 30C), one byte per line, 2048 lines each.  The
contents are the user's own calibration data, not ROM; the output dir is
under sim/build and never committed.
"""
import sys
from pathlib import Path

PAIRS = [("mainpcb_200e", "zram_hi.hex"), ("mainpcb_210e", "zram_lo.hex"),
         ("mainpcb_dsk_10c", "dsk_zram_hi.hex"), ("mainpcb_dsk_30c", "dsk_zram_lo.hex")]


def main():
    src, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    for name, hexname in PAIRS:
        f = src / name
        if not f.exists():
            print(f"{f}: missing, leaving {hexname} out (the RAM powers up as fresh)")
            continue
        data = f.read_bytes()
        if len(data) != 2048:
            sys.exit(f"{f}: {len(data)} bytes, expected 2048")
        (out / hexname).write_text("".join(f"{b:02x}\n" for b in data))
        print(f"{hexname}: {len(data)} bytes from {f.name}")


if __name__ == "__main__":
    main()
