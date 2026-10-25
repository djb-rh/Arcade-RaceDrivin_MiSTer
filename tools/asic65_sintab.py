#!/usr/bin/env python3
"""Generate the ASIC65 sine table (rtl/asic65/asic65_sin.hex).

MAME's ASIC65 simulation (src/mame/atari/asic65.cpp, the oracle for this
core) answers the SIN and COS commands with

    (int)(16384. * sin(pi * (s16)p / 32768.))     truncation toward zero

computed in double precision.  rtl/asic65/asic65_sim.sv reproduces that
bit-exactly from a quarter-wave table: entry a (0 <= a < 16384) holds
int(16384 * sin(pi * a / 32768)); a = 16384 is the constant 16384, the other
three quadrants come from sin(pi - x) = sin(x) and sin(-x) = -sin(x), and
COS(p) = SIN(16384 - p) (wrapped to 16 bits).  This script checks those
identities against direct evaluation for every 16-bit argument before
writing the table, so a libm whose last-bit rounding differed would be
caught here rather than in the comparison with MAME.

The table is mathematics, not ROM contents.
"""
import math
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "rtl" / "asic65" / "asic65_sin.hex"


def mame_sin(p):
    return int(16384.0 * math.sin(math.pi * p / 32768.0))


def mame_cos(p):
    return int(16384.0 * math.cos(math.pi * p / 32768.0))


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def table_sin(tab, p):
    a = abs(p)
    if a > 16384:
        a = 32768 - a
    v = 16384 if a == 16384 else tab[a]
    return -v if p < 0 else v


def main():
    tab = [mame_sin(a) for a in range(16384)]
    bad = 0
    for p in range(-32768, 32768):
        if table_sin(tab, p) != mame_sin(p):
            bad += 1
            print(f"SIN mismatch at {p}: table {table_sin(tab, p)} direct {mame_sin(p)}")
        if table_sin(tab, s16(16384 - p)) != mame_cos(p):
            bad += 1
            print(f"COS mismatch at {p}: table {table_sin(tab, s16(16384 - p))} direct {mame_cos(p)}")
        if bad > 20:
            break
    if bad:
        sys.exit(f"{bad} mismatches; the table scheme does not reproduce MAME on this libm")
    OUT.write_text("".join(f"{v:04x}\n" for v in tab))
    print(f"wrote {OUT} ({len(tab)} entries), all 65536 SIN and COS arguments verified")


if __name__ == "__main__":
    main()
