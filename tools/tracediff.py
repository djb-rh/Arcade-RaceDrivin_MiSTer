#!/usr/bin/env python3
"""Compare the simulated core's 68010 bus trace with MAME's write log.

    tools/tracediff.py sim_trace.txt mame.writes.log [--context 8] [--skip-rom] [--timeline 50000]

The sim trace comes from sim/tb_core.sv (+trace=): lines "time kind addr data
uds lds". MAME's log comes from mame/oracle.lua with RD_BUSWRITES=1: lines
"addr data mask [time]". Only writes are compared, as an ordered sequence of
(address, data, byte-enable) tuples: the same program on both machines must
produce the same write sequence until it reads something timing-dependent.

Tolerated difference: the two word halves of one long write may come in
either order (TG68K writes the high word first, MAME's 68000 core the low
word first for MOVEM/PEA); both leave the same memory, so an adjacent pair of
writes to A and A+2 that matches the other side swapped counts as equal and
is only tallied.

The first real mismatch is reported with context on both sides, and with
--timeline the emulated time of both machines is printed every N matching
writes so the pacing of the two can be compared.
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
        out.append((a & 0xFFFFFE, int(data, 16), int(uds), int(lds), int(t) / 1e12))
    return out


def mame_writes(path, skip_rom):
    out = []
    for line in Path(path).read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        f = line.split()
        addr, data, mask = f[:3]
        t = float(f[3]) if len(f) > 3 else float("nan")
        a = int(addr, 16)
        if skip_rom and a < 0x100000:
            continue
        m = int(mask, 16)
        uds = 1 if m & 0xFF00 else 0
        lds = 1 if m & 0x00FF else 0
        out.append((a & 0xFFFFFE, int(data, 16), uds, lds, t))
    return out


def key(w):
    a, d, uds, lds, _ = w
    d = (d & 0xFF00 if uds else 0) | (d & 0x00FF if lds else 0)
    return (a, d, uds, lds)


def fmt(w):
    a, d, u, l, _ = w
    return f"{a:06x} {d:04x} {u}{l}"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sim_trace")
    ap.add_argument("mame_writes")
    ap.add_argument("--context", type=int, default=8)
    ap.add_argument("--skip-rom", action="store_true", help="ignore writes below 0x100000")
    ap.add_argument("--timeline", type=int, default=0, metavar="N",
                    help="print sim and MAME time every N matching writes")
    args = ap.parse_args()
    s = sim_writes(args.sim_trace, args.skip_rom)
    m = mame_writes(args.mame_writes, args.skip_rom)
    print(f"sim writes: {len(s)}   mame writes: {len(m)}")
    n = min(len(s), len(m))
    swaps = 0
    i = 0
    while i < n:
        if key(s[i]) == key(m[i]):
            if args.timeline and i % args.timeline == 0 and i:
                print(f"  write #{i:>8}: sim {s[i][4]:9.6f} s   mame {m[i][4]:9.6f} s")
            i += 1
            continue
        # one long write, halves in the other order
        if (i + 1 < n and key(s[i]) == key(m[i + 1]) and key(s[i + 1]) == key(m[i])
                and abs(s[i][0] - s[i + 1][0]) == 2 and s[i][2:4] == (1, 1) == s[i + 1][2:4]):
            swaps += 1
            i += 2
            continue
        print(f"FIRST MISMATCH at write #{i} (sim {s[i][4]:.6f} s, mame {m[i][4]:.6f} s)")
        lo, hi = max(0, i - args.context), min(n, i + args.context)
        print(f"{'#':>8} {'sim addr data u l':<24} {'mame addr data u l':<24}")
        for j in range(lo, hi):
            mark = "<<" if j == i else "  "
            print(f"{j:8d} {fmt(s[j]):<24} {fmt(m[j]):<24} {mark}")
        sys.exit(1)
    tail = "" if len(s) == len(m) else f" (lengths differ: sim {len(s)}, mame {len(m)})"
    print(f"first {n} writes identical, {swaps} long-write halves swapped{tail}")
    if n:
        print(f"  at write #{n - 1}: sim {s[n - 1][4]:.6f} s   mame {m[n - 1][4]:.6f} s")


if __name__ == "__main__":
    main()
