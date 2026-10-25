#!/usr/bin/env python3
"""Build and run the whole-core Verilator simulation.

    tools/sim.py build [--stub-68010] [--trace-waves]
    tools/sim.py run --roms sim/build/roms/racedriv --ms 50 --trace sim/build/run/trace.txt [--service]
    tools/sim.py roms racedriv-cockpit ~/roms/racedriv.zip [--slapstic-free]   (wraps tools/romimage.py)

Build: collects the core's sources from the Quartus project (via
tools/hd/list_sources.tcl), swaps in the simulation models under sim/models/,
uses the GHDL-converted TG68K (sim/build/ghdl/tg68k_synth.v) or, with
--stub-68010, an empty stub so the rest of the design can be compiled, and
produces sim/build/obj/Vtb_core. The ZRAM power-up hex files are compile-time
parameters of the core, so `build` takes --roms too (default
sim/build/roms/current) and the binary is tied to that set's 200E/210E.

Run: executes the binary in the ROM directory with the chosen plusargs.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "sim" / "build"
OBJ = BUILD / "obj"
SIM_PATH = "/usr/bin:" + os.environ.get("PATH", "")   # Verilator's perl wrapper vs the x86 MacPorts perl

DEFINES = ["HD_ARCH_MILESTONE", "HD_FUNCTIONAL_ADSP", "HD_SOUND_BOARD", "HD_LEAN", "HD_COCKPIT"]
EXCLUDE = ("compact_gsp_vram.sv", "harddrivin_pll.sv", "RaceDrivin.sv")
WARN_OFF = ["WIDTH", "UNUSED", "DECLFILENAME", "PINCONNECTEMPTY", "UNOPTFLAT", "IMPLICITSTATIC",
            "MULTIDRIVEN", "BLKANDNBLK", "TIMESCALEMOD", "COMBDLY", "CMPCONST", "ALWCOMBORDER", "PINMISSING"]


def core_sources():
    out = subprocess.run(["tclsh", "tools/hd/list_sources.tcl"], cwd=ROOT, check=True, text=True,
                         stdout=subprocess.PIPE).stdout
    files = []
    for row in out.splitlines():
        kind, value = row.split("\t", 1)
        if kind not in {"VERILOG_FILE", "SYSTEMVERILOG_FILE"}:
            continue
        if "/sys/" in value or value.endswith(EXCLUDE):
            continue
        files.append(value)
    return files


def cmd_build(args):
    roms = Path(args.roms).resolve()
    hi, lo = roms / "zram_hi.hex", roms / "zram_lo.hex"
    if not (hi.exists() and lo.exists()):
        sys.exit(f"missing {hi} / {lo}: run tools/sim.py roms first")
    sources = core_sources()
    models = sorted(str(p) for p in (ROOT / "sim" / "models").glob("*.sv") if p.name != "tg68k_stub.sv")
    tg68k = BUILD / "ghdl" / "tg68k_synth.v"
    if args.stub_68010:
        models.append(str(ROOT / "sim" / "models" / "tg68k_stub.sv"))
        print("NOTE: building with the 68010 STUB; the main CPU will not execute anything")
    elif tg68k.exists():
        models.append(str(tg68k))
    else:
        sys.exit(f"{tg68k} not found: convert the TG68K with GHDL (see docs/simulation.md) or pass --stub-68010")
    OBJ.mkdir(parents=True, exist_ok=True)
    cmd = ["verilator", "--binary", "--timing", "-j", str(args.jobs), "--Mdir", str(OBJ),
           "--top-module", "tb_core", "-Wno-fatal", "--no-assert-case",
           "-Irtl", "-Irtl/ika32010", "-Irtl/tms34010",
           f"-DZRAM_HI_FILE=\"{hi}\"", f"-DZRAM_LO_FILE=\"{lo}\""]
    cmd += [f"-Wno-{w}" for w in WARN_OFF]
    cmd += [f"-D{d}" for d in DEFINES]
    if args.trace_waves:
        cmd += ["--trace", "--trace-depth", "4"]
    if args.opt:
        cmd += ["-O3", "-CFLAGS", "-O2"]
    else:
        cmd += ["-CFLAGS", "-O1"]
    if args.threads > 1:
        cmd += ["--threads", str(args.threads)]
    cmd += sources + models + [str(ROOT / "sim" / "tb_core.sv")]
    (BUILD / "verilator_cmd.txt").write_text(" ".join(cmd) + "\n")
    print(f"verilator: {len(sources)} core sources, {len(models)} models")
    env = dict(os.environ, PATH=SIM_PATH)
    with (BUILD / "verilator_build.log").open("w") as log:
        rc = subprocess.run(cmd, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT).returncode
    if rc != 0:
        log_text = (BUILD / "verilator_build.log").read_text()
        errors = [l for l in log_text.splitlines() if l.startswith("%Error")]
        print("\n".join(errors[:30]))
        sys.exit(f"verilator failed ({rc}); full log in sim/build/verilator_build.log")
    print(f"built {OBJ / 'Vtb_core'}")


def cmd_run(args):
    exe = OBJ / "Vtb_core"
    if not exe.exists():
        sys.exit("build first: tools/sim.py build")
    roms = Path(args.roms).resolve()
    plus = [f"+ddr={roms / 'ddr.bin'}", f"+snd={roms / 'index1.bin'}", f"+ms={args.ms}"]
    if args.trace:
        Path(args.trace).parent.mkdir(parents=True, exist_ok=True)
        plus.append(f"+trace={Path(args.trace).resolve()}")
    if args.service:
        plus.append("+service=1")
    if args.vcd:
        plus.append(f"+vcd={Path(args.vcd).resolve()}")
    cmd = [str(exe)] + plus
    print(" ".join(cmd))
    # FX68K reads its microcode (microrom.mem, nanorom.mem) relative to the
    # working directory, so run from its source directory.
    sys.exit(subprocess.run(cmd, cwd=ROOT / "rtl" / "fx68k").returncode)


def cmd_roms(args):
    out = BUILD / "roms" / args.layout.split("-")[0]
    cmd = [sys.executable, str(ROOT / "tools" / "romimage.py"), args.layout, args.romset, "-o", str(out)]
    if args.slapstic_free:
        cmd.append("--slapstic-free")
    for p in args.parent:
        cmd += ["--parent", p]
    subprocess.run(cmd, check=True)
    current = BUILD / "roms" / "current"
    if current.is_symlink() or current.exists():
        current.unlink()
    current.symlink_to(out.name)
    print(f"{current} -> {out.name}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--roms", default=str(BUILD / "roms" / "current"))
    b.add_argument("--stub-68010", action="store_true")
    b.add_argument("--trace-waves", action="store_true")
    b.add_argument("--opt", action="store_true", help="-O3 (slower build, faster sim)")
    b.add_argument("--threads", type=int, default=1)
    b.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 1))
    b.set_defaults(func=cmd_build)
    r = sub.add_parser("run")
    r.add_argument("--roms", default=str(BUILD / "roms" / "current"))
    r.add_argument("--ms", type=int, default=100)
    r.add_argument("--trace")
    r.add_argument("--vcd")
    r.add_argument("--service", action="store_true")
    r.set_defaults(func=cmd_run)
    m = sub.add_parser("roms")
    m.add_argument("layout")
    m.add_argument("romset")
    m.add_argument("--parent", action="append", default=[])
    m.add_argument("--slapstic-free", action="store_true")
    m.set_defaults(func=cmd_roms)
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
