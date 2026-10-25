#!/usr/bin/env python3
"""Build and run the whole-core Verilator simulation.

    tools/sim.py build [--stub-68010] [--trace-waves] [--opt] [--threads N]
    tools/sim.py run --roms sim/build/roms/racedriv --ms 50 --trace sim/build/run/trace.txt [--service]
    tools/sim.py roms racedriv-cockpit ~/roms/racedriv.zip [--slapstic-free]   (wraps tools/romimage.py)
    tools/sim.py tg68k [--ghdl /path/to/ghdl]                                (VHDL -> Verilog, once)

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
import re
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


TG68K_GENERICS = {"SR_Read": 0, "VBR_Stackframe": 1, "extAddr_Mode": 0, "MUL_Mode": 0,
                  "DIV_Mode": 0, "BitField": 0, "BarrelShifter": 1, "MUL_Hardware": 1}
GHDL_DEFAULT = Path.home() / "Developer/tools/ghdl-llvm-6.0.0-macos15-aarch64/bin/ghdl"


def cmd_tg68k(args):
    """Convert the VHDL TG68K to Verilog with GHDL's synthesiser.

    The generics are fixed to the values harddrivin_milestone.sv instantiates
    (TG68K_GENERICS); the module header is then given parameters of the same
    names so that instantiation still elaborates (Verilator ignores the
    overrides, which equal the baked-in values).
    """
    ghdl = args.ghdl or (str(GHDL_DEFAULT) if GHDL_DEFAULT.exists() else shutil.which("ghdl"))
    if not ghdl:
        sys.exit("ghdl not found: pass --ghdl (see docs/simulation.md)")
    out_dir = BUILD / "ghdl"
    out_dir.mkdir(parents=True, exist_ok=True)
    src = [str(ROOT / "rtl" / "tg68k" / f) for f in ("TG68K_Pack.vhd", "TG68K_ALU.vhd", "TG68KdotC_Kernel.vhd")]
    std = ["--std=08", "-fsynopsys", "-frelaxed"]
    env = dict(os.environ, PATH=SIM_PATH)
    subprocess.run([ghdl, "-a"] + std + src, cwd=out_dir, env=env, check=True)
    # --latches: two ALU signals (rot_rot, msb) are incompletely assigned in
    # combinational processes; VHDL keeps the old value, so a latch is faithful.
    cmd = [ghdl, "--synth"] + std + ["--latches", "--out=verilog"]
    cmd += [f"-g{k}={v}" for k, v in TG68K_GENERICS.items()] + ["TG68KdotC_Kernel"]
    res = subprocess.run(cmd, cwd=out_dir, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    (out_dir / "synth.log").write_text(res.stderr)
    if res.returncode != 0:
        print(res.stderr[-3000:])
        sys.exit("ghdl --synth failed")
    params = ",\n   ".join(f"parameter integer {k} = {v}" for k, v in TG68K_GENERICS.items())
    text, n = re.subn(r"^module TG68KdotC_Kernel\n", f"module TG68KdotC_Kernel\n  #({params})\n", res.stdout,
                      count=1, flags=re.M)
    if n != 1:
        sys.exit("unexpected GHDL output: module header not found")
    out = out_dir / "tg68k_synth.v"
    out.write_text(text)
    print(f"wrote {out} ({text.count(chr(10))} lines); warnings in {out_dir / 'synth.log'}")


def obj_dir(args):
    return BUILD / ("obj-opt" if args.opt else "obj")


def cmd_build(args):
    OBJ = obj_dir(args)
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
           f"-DZRAM_HI_FILE=\"{hi}\"", f"-DZRAM_LO_FILE=\"{lo}\"",
           f"-DASIC65_SIN_FILE=\"{ROOT / 'rtl' / 'asic65' / 'asic65_sin.hex'}\""]
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
    exe = obj_dir(args) / "Vtb_core"
    if not exe.exists():
        sys.exit(f"build first: tools/sim.py build{' --opt' if args.opt else ''}")
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


def cmd_asic65_test(args):
    """Replay a MAME .asic65.log through asic65_sim and check every result."""
    out = BUILD / "asic65"
    out.mkdir(parents=True, exist_ok=True)
    stim = out / "asic65_stim.txt"
    lines = ["R 1", "R 1", "R 0"]   # control latch fn 4: 0 at power-up, 0 then 1 at 1.434 s
    counts = {"cmd": 0, "param": 0, "result": 0}
    for line in Path(args.log).read_text().splitlines():
        f = line.split()
        if line.startswith("#") or len(f) < 4:
            continue
        kind, val = f[2], f[3]
        code = {"cmd": "C", "param": "P", "result": "X"}.get(kind)
        if code:
            lines.append(f"{code} {val}")
            counts[kind] += 1
    stim.write_text("\n".join(lines) + "\n")
    print(f"stimulus: {counts}")
    sin = ROOT / "rtl" / "asic65" / "asic65_sin.hex"
    cmd = ["verilator", "--binary", "--timing", "-Wno-fatal", "--Mdir", str(out / "obj"),
           "--top-module", "tb_asic65", f"-DSIN_FILE=\"{sin}\"",
           str(ROOT / "rtl" / "asic65" / "asic65_sim.sv"), str(ROOT / "sim" / "tb_asic65.sv")]
    (out / "build.log").write_text(subprocess.run(cmd, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                                                  stderr=subprocess.STDOUT, env=dict(os.environ, PATH=SIM_PATH)).stdout)
    sys.exit(subprocess.run([str(out / "obj" / "Vtb_asic65"), f"+stim={stim}"], cwd=out).returncode)


def cmd_dsp32_test(args):
    """Lock-step dsp32c_core against a MAME RD_DSP32TRACE file."""
    out = BUILD / "dsp32"
    out.mkdir(parents=True, exist_ok=True)
    srcs = [str(ROOT / "rtl" / "dsp32c" / f) for f in ("dsp32c_pkg.sv", "dsp32c_fma.sv", "dsp32c_ram.sv", "dsp32c_core.sv")]
    cmd = ["verilator", "--binary", "--timing", "-Wno-fatal", "-Wno-WIDTH", "--Mdir", str(out / "obj"),
           "--top-module", "tb_dsp32", "-CFLAGS", "-O2"] + srcs + [str(ROOT / "sim" / "tb_dsp32.sv")]
    r = subprocess.run(cmd, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       env=dict(os.environ, PATH=SIM_PATH))
    (out / "build.log").write_text(r.stdout)
    if r.returncode != 0:
        print(r.stdout[-4000:])
        sys.exit("verilator failed (sim/build/dsp32/build.log)")
    trace = Path(args.trace).resolve()
    plus = [f"+trace={trace}", f"+mem={args.mem or str(trace) + '.mem'}", f"+max={args.max_mismatch}"]
    sys.exit(subprocess.run([str(out / "obj" / "Vtb_dsp32")] + plus, cwd=out).returncode)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--roms", default=str(BUILD / "roms" / "current"))
    b.add_argument("--stub-68010", action="store_true")
    b.add_argument("--trace-waves", action="store_true")
    b.add_argument("--opt", action="store_true", help="-O3 into sim/build/obj-opt (slower build, faster sim)")
    b.add_argument("--threads", type=int, default=1)
    b.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 1))
    b.set_defaults(func=cmd_build)
    r = sub.add_parser("run")
    r.add_argument("--roms", default=str(BUILD / "roms" / "current"))
    r.add_argument("--ms", type=int, default=100)
    r.add_argument("--trace")
    r.add_argument("--vcd")
    r.add_argument("--service", action="store_true")
    r.add_argument("--opt", action="store_true", help="run the -O3 build")
    r.set_defaults(func=cmd_run)
    m = sub.add_parser("roms")
    m.add_argument("layout")
    m.add_argument("romset")
    m.add_argument("--parent", action="append", default=[])
    m.add_argument("--slapstic-free", action="store_true")
    m.set_defaults(func=cmd_roms)
    t = sub.add_parser("tg68k")
    t.add_argument("--ghdl")
    t.set_defaults(func=cmd_tg68k)
    a = sub.add_parser("asic65-test", help="replay a MAME .asic65.log through the ASIC65 model")
    a.add_argument("log")
    a.set_defaults(func=cmd_asic65_test)
    d = sub.add_parser("dsp32-test", help="lock-step the DSP32C core against a MAME RD_DSP32TRACE file")
    d.add_argument("trace")
    d.add_argument("--mem", help="memory image (default <trace>.mem)")
    d.add_argument("--max-mismatch", type=int, default=20)
    d.set_defaults(func=cmd_dsp32_test)
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
