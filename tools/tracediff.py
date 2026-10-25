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
writes so the pacing of the two can be compared. Both files are streamed, so
multi-million-line captures are fine.
"""
import argparse
import sys
from collections import deque


def sim_writes(path, skip_rom):
    with open(path) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            t, kind, addr, data, uds, lds = line.split()
            if kind != "W":
                continue
            a = int(addr, 16)
            if skip_rom and a < 0x100000:
                continue
            yield (a & 0xFFFFFE, int(data, 16), int(uds), int(lds), int(t) / 1e12)


def mame_writes(path, skip_rom):
    with open(path) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            fld = line.split()
            addr, data, mask = fld[:3]
            t = float(fld[3]) if len(fld) > 3 else float("nan")
            a = int(addr, 16)
            if skip_rom and a < 0x100000:
                continue
            m = int(mask, 16)
            uds = 1 if m & 0xFF00 else 0
            lds = 1 if m & 0x00FF else 0
            yield (a & 0xFFFFFE, int(data, 16), uds, lds, t)


def key(w):
    a, d, uds, lds, _ = w
    d = (d & 0xFF00 if uds else 0) | (d & 0x00FF if lds else 0)
    return (a, d, uds, lds)


def fmt(w):
    a, d, u, l, _ = w
    return f"{a:06x} {d:04x} {u}{l}"


class Peekable:
    """Iterator with one-item lookahead."""

    def __init__(self, it):
        self.it = iter(it)
        self.buf = deque()

    def peek(self, n=0):
        while len(self.buf) <= n:
            try:
                self.buf.append(next(self.it))
            except StopIteration:
                return None
        return self.buf[n]

    def pop(self):
        v = self.peek()
        if v is not None:
            self.buf.popleft()
        return v


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sim_trace")
    ap.add_argument("mame_writes")
    ap.add_argument("--context", type=int, default=8)
    ap.add_argument("--skip-rom", action="store_true", help="ignore writes below 0x100000")
    ap.add_argument("--timeline", type=int, default=0, metavar="N",
                    help="print sim and MAME time every N matching writes")
    args = ap.parse_args()
    s = Peekable(sim_writes(args.sim_trace, args.skip_rom))
    m = Peekable(mame_writes(args.mame_writes, args.skip_rom))
    ctx_s, ctx_m = deque(maxlen=args.context), deque(maxlen=args.context)
    i = swaps = 0
    last = None
    while True:
        a, b = s.peek(), m.peek()
        if a is None or b is None:
            break
        if key(a) == key(b):
            if args.timeline and i and i % args.timeline == 0:
                print(f"  write #{i:>8}: sim {a[4]:9.6f} s   mame {b[4]:9.6f} s")
            ctx_s.append(a); ctx_m.append(b); last = (a, b)
            s.pop(); m.pop(); i += 1
            continue
        a2, b2 = s.peek(1), m.peek(1)
        if (a2 is not None and b2 is not None and key(a) == key(b2) and key(a2) == key(b)
                and abs(a[0] - a2[0]) == 2 and a[2:4] == (1, 1) == a2[2:4]):
            swaps += 1
            for _ in range(2):
                ctx_s.append(s.pop()); ctx_m.append(m.pop())
            last = (ctx_s[-1], ctx_m[-1]); i += 2
            continue
        print(f"FIRST MISMATCH at write #{i} (sim {a[4]:.6f} s, mame {b[4]:.6f} s)")
        print(f"{'#':>8} {'sim addr data u l':<24} {'mame addr data u l':<24}")
        for j, (x, y) in enumerate(zip(ctx_s, ctx_m)):
            print(f"{i - len(ctx_s) + j:8d} {fmt(x):<24} {fmt(y):<24}")
        print(f"{i:8d} {fmt(a):<24} {fmt(b):<24} <<")
        for j in range(1, args.context):
            x, y = s.peek(j), m.peek(j)
            if x is None or y is None:
                break
            print(f"{i + j:8d} {fmt(x):<24} {fmt(y):<24}")
        sys.exit(1)
    s_more = s.peek() is not None
    m_more = m.peek() is not None
    tail = "" if not (s_more or m_more) else (" (sim has more)" if s_more else " (mame has more)")
    print(f"first {i} writes identical, {swaps} long-write halves swapped{tail}")
    if last:
        print(f"  at write #{i - 1}: sim {last[0][4]:.6f} s   mame {last[1][4]:.6f} s")


if __name__ == "__main__":
    main()
