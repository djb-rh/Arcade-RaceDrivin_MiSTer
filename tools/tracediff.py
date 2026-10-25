#!/usr/bin/env python3
"""Compare the simulated core's 68010 bus trace with MAME's write log.

    tools/tracediff.py sim_trace.txt mame.writes.log [--context 8] [--skip-rom]

The sim trace comes from sim/tb_core.sv (+trace=): lines "time kind addr data
uds lds". MAME's log comes from mame/oracle.lua with RD_BUSWRITES=1: lines
"addr data mask". Only writes are compared, as an ordered sequence of
(address, data, byte-enable) tuples: the same program on both machines must
produce the same write sequence until it reads something timing-dependent.
The first mismatch is reported with context on both sides; 'W' lines from the
sim and MAME writes with a mask covering both bytes or one byte are normalised
to (addr, data, which_bytes).
"""
import argparse
import sys
from pathlib import Path


def sim_writes(path, skip_rom):
    out = []
    for line in Path(path).read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        t, kind, addr, data, uds, lds = line.split()
        if kind != "W":
            continue
        a = int(addr, 16)
        if skip_rom and a < 0x100000:
            continue
        out.append((a & 0xFFFFFE, int(data, 16), int(uds), int(lds), t))
    return out


def mame_writes(path, skip_rom):
    out = []
    for line in Path(path).read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        addr, data, mask = line.split()
        a = int(addr, 16)
        if skip_rom and a < 0x100000:
            continue
        m = int(mask, 16)
        uds = 1 if m & 0xFF00 else 0
        lds = 1 if m & 0x00FF else 0
        out.append((a & 0xFFFFFE, int(data, 16), uds, lds, ""))
    return out


def key(w):
    a, d, uds, lds, _ = w
    d = (d & 0xFF00 if uds else 0) | (d & 0x00FF if lds else 0)
    return (a, d, uds, lds)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sim_trace")
    ap.add_argument("mame_writes")
    ap.add_argument("--context", type=int, default=8)
    ap.add_argument("--skip-rom", action="store_true", help="ignore writes below 0x100000")
    args = ap.parse_args()
    s = sim_writes(args.sim_trace, args.skip_rom)
    m = mame_writes(args.mame_writes, args.skip_rom)
    print(f"sim writes: {len(s)}   mame writes: {len(m)}")
    n = min(len(s), len(m))
    for i in range(n):
        if key(s[i]) != key(m[i]):
            print(f"FIRST MISMATCH at write #{i} (sim time {s[i][4]} ps)")
            lo, hi = max(0, i - args.context), min(n, i + args.context)
            print(f"{'#':>8} {'sim addr data u l':<24} {'mame addr data u l':<24}")
            for j in range(lo, hi):
                mark = "<<" if j == i else "  "
                a, d, u, l, _ = s[j]
                b, e, v, w, _ = m[j]
                print(f"{j:8d} {a:06x} {d:04x} {u}{l}            {b:06x} {e:04x} {v}{w}   {mark}")
            sys.exit(1)
    print(f"first {n} writes identical" + ("" if len(s) == len(m) else f" (lengths differ: sim {len(s)}, mame {len(m)})"))


if __name__ == "__main__":
    main()
