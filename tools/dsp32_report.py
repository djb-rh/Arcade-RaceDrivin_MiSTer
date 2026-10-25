#!/usr/bin/env python3
"""Summarise an RD_DSP32LOG file written by MAME with mame/dsp32-measure.patch.

    tools/dsp32_report.py dsp32.log [--ops]

Prints: instruction totals and rate (instructions per emulated second, derived
from the MARK lines), the memory footprint per DSP32C region at 1 KiB
granularity (lowest and highest page touched, pages touched, bytes), PIO
traffic counts by register, PCR reset transitions, and the executed opcode
classes decoded from the 11-bit dispatch index the way MAME's dsp32ops table
groups them. --ops also lists every 16-bit opcode prefix seen with its count.
"""
import argparse
import collections
import re
from pathlib import Path

REGIONS = [("ram0 (0x000000-0x001FFF)", 0x000000, 0x002000),
           ("ram6 (0x600000-0x63FFFF)", 0x600000, 0x640000),
           ("ramF (0xFFF800-0xFFFFFF)", 0xFFF800, 0x1000000)]


DEFAULT_OPS_HXX = Path.home() / "Developer/mame/src/devices/cpu/dsp32/dsp32ops.hxx"


def load_dispatch_table(path):
    """Return the 2048 handler names of s_dsp32ops[] in order, from MAME's dsp32ops.hxx."""
    text = path.read_text()
    start = text.index("s_dsp32ops[]")
    names = re.findall(r"&dsp32c_device::(\w+)", text[start:])
    if len(names) < 2048:
        raise SystemExit(f"only {len(names)} handlers parsed from {path}")
    return names[:2048]


def handler_family(name):
    """Group handler names into the instruction families used in NOTES.md."""
    if name == "nop":
        return "nop"
    if name == "illegal":
        return "illegal"
    if name.startswith("goto_") or name in ("goto24", "call24"):
        return "goto/call (conditional or 24-bit)"
    if name in ("dec_goto", "call", "do_i", "do_r"):
        return name
    if name.startswith("d1_"):
        return "DAU form 1 (aN = Y + aM*X)" + (" with store [r]" if name.endswith("r") else "")
    if name.startswith("d2_"):
        return "DAU form 2" + (" with store [r]" if name.endswith("r") else "")
    if name.startswith("d3_"):
        return "DAU form 3" + (" with store [r]" if name.endswith("r") else "")
    if name.startswith("d4_"):
        return "DAU form 4 (aN = Y +- X)" + (" with store [r]" if name.endswith("r") else "")
    if name.startswith("d5_"):
        return "DAU form 5: " + name[3:]
    if name.startswith(("load_", "store_")):
        return "CAU load/store " + ("immediate-address" if name.endswith("i") else "pointer")
    if name.endswith(("_ss", "_s")):
        return "CAU 16-bit ALU reg,reg"
    if name.endswith("_di"):
        return "CAU 16-bit ALU reg,imm"
    if name.endswith(("_ssE", "_sE", "_diE")):
        return "CAU 24-bit ALU"
    if name.endswith("_si") or name.endswith("_siE"):
        return "CAU add short immediate"
    return "other: " + name


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log", type=Path)
    ap.add_argument("--ops", action="store_true", help="list every 16-bit opcode prefix")
    ap.add_argument("--ops-hxx", type=Path, default=DEFAULT_OPS_HXX,
                    help="MAME dsp32ops.hxx to read the dispatch table from")
    args = ap.parse_args()
    table = load_dispatch_table(args.ops_hxx) if args.ops_hxx.exists() else None

    marks = []
    pages = {}
    op11 = {}
    op16 = {}
    pio = collections.Counter()
    pcr = []
    summary = {}
    for line in args.log.read_text().splitlines():
        if line.startswith("MARK"):
            m = re.match(r"MARK t=([\d.]+) instr=(\d+)", line)
            marks.append((float(m.group(1)), int(m.group(2))))
        elif line.startswith("PAGE"):
            m = re.match(r"PAGE ([0-9a-f]+) rd=(\d+) wr=(\d+)", line)
            pages[int(m.group(1), 16)] = (int(m.group(2)), int(m.group(3)))
        elif line.startswith("OP11"):
            _, k, v = line.split()
            op11[int(k, 16)] = int(v)
        elif line.startswith("OP16"):
            _, k, v = line.split()
            op16[int(k, 16)] = int(v)
        elif line.startswith("PIOW") or line.startswith("PIOR"):
            m = re.match(r"(PIO[WR]) t=[\d.]+ reg=(\d+)", line)
            pio[(m.group(1), int(m.group(2)))] += 1
        elif line.startswith("PCR"):
            pcr.append(line)
        elif line.startswith("SUMMARY"):
            summary = dict(kv.split("=") for kv in line.split()[1:])

    print(f"== {args.log}")
    print("instructions:", summary.get("instructions"), " reads:", summary.get("reads"),
          " writes:", summary.get("writes"), " pio_reads:", summary.get("pio_reads"),
          " pio_writes:", summary.get("pio_writes"))
    if len(marks) >= 2:
        (t0, i0), (t1, i1) = marks[0], marks[-1]
        print(f"average rate: {(i1 - i0) / (t1 - t0) / 1e6:.3f} M instr/s over {t1 - t0:.1f} s emulated "
              f"(real DSP32C at 40 MHz = 10.0 M instr/s)")
        # peak rate over any 100k-instruction interval
        best = 0.0
        for (ta, ia), (tb, ib) in zip(marks, marks[1:]):
            if tb > ta:
                best = max(best, (ib - ia) / (tb - ta))
        print(f"peak rate over a 100k-instruction window: {best / 1e6:.3f} M instr/s")
        # idle check: first and last marks
        print(f"first mark at t={t0:.3f}s, last at t={t1:.3f}s")
    for name, lo, hi in REGIONS:
        touched = sorted(p for p in pages if lo <= p < hi)
        if not touched:
            print(f"{name}: untouched")
            continue
        rd = sum(pages[p][0] for p in touched)
        wr = sum(pages[p][1] for p in touched)
        print(f"{name}: pages {touched[0]:06x}..{touched[-1] + 0x3ff:06x}, {len(touched)} KiB touched, "
              f"span {(touched[-1] + 0x400 - touched[0]) // 1024} KiB, reads {rd}, writes {wr}")
    outside = sorted(p for p in pages if not any(lo <= p < hi for _, lo, hi in REGIONS))
    if outside:
        print("accesses outside known RAM:", ", ".join(f"{p:06x}" for p in outside[:20]))
    if pio:
        print("PIO traffic by register index (raw 68010 word offset):")
        for (kind, reg), n in sorted(pio.items()):
            print(f"  {kind} reg {reg:2d}: {n}")
    if pcr:
        print(f"PCR reset transitions: {len(pcr)}")
        for line in pcr[:12]:
            print("  " + line)
    total = sum(op11.values()) or 1
    if table:
        handlers = collections.Counter()
        families = collections.Counter()
        for idx, n in op11.items():
            handlers[table[idx]] += n
            families[handler_family(table[idx])] += n
        print("instruction families executed (dynamic counts):")
        for name, n in families.most_common():
            print(f"  {n:12d} {100 * n / total:5.1f}%  {name}")
        print(f"distinct MAME handlers executed: {len(handlers)}")
        for name, n in handlers.most_common():
            print(f"  {n:12d}  {name}")
        unimpl = {h for h in handlers if h in ("do_i", "do_r", "illegal") or h.startswith("goto_ib")
                  or h.startswith("goto_ob") or h.startswith("goto_sy") or h.startswith("goto_fb")
                  or h.startswith("goto_irq")}
        if unimpl:
            print("WARNING: handlers MAME leaves unimplemented were reached:", ", ".join(sorted(unimpl)))
    else:
        print("(dispatch table not found; pass --ops-hxx to name handlers)")
        for idx, n in sorted(op11.items(), key=lambda kv: -kv[1])[:40]:
            print(f"  idx {idx:03x}: {n}")
    print(f"distinct 11-bit dispatch indexes: {len(op11)}, distinct 16-bit prefixes: {len(op16)}")
    if args.ops:
        for k, v in sorted(op16.items(), key=lambda kv: -kv[1]):
            print(f"  OP16 {k:04x} {v}")


if __name__ == "__main__":
    main()
