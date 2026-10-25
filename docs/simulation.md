# Whole-core simulation

`sim/` simulates the board-level top (`harddrivin_milestone`, the same module
the MiSTer `emu` wrapper instantiates) under Verilator with behavioural
memories, real ROM images built from the user's MAME set at run time, and a
68010 bus trace that is compared against MAME. It needs no FPGA and no
Quartus, so milestones M1-M3 can be verified on the Mac.

## Pieces

| Path | Role |
|---|---|
| `sim/tb_core.sv` | testbench top: clocks, reset, sound-EPROM download, inputs, bus trace, progress |
| `sim/models/harddrivin_pll.sv` | replaces the Altera PLL: 48 / 50 / 100 MHz and the 4 or 6 MHz video clock, generated with `--timing` |
| `sim/models/altddio_out.sv` | the DDIO primitive the SDRAM controller uses for its clock pin |
| `sim/models/sim_sdram.sv` | 32 MB SDR SDRAM chip: CAS 2, burst 4, DQM masks, commands sampled on the inverted clock the controller drives |
| `sim/models/sim_ddr.sv` | MiSTer DDR service port holding the 2 MiB MRA index-0 image at 0x30000000, burst reads with latency and random BUSY |
| `sim/models/tg68k_stub.sv` | empty 68010 for build checks only (`--stub-68010`) |
| `tools/romimage.py` | builds `ddr.bin`, `index1.bin`, `zram_hi/lo.hex`, `dips.bin` from a MAME zip using the MRA layout in `tools/mkmra.py` |
| `tools/sim.py` | `roms` / `build` / `run` front end |
| `tools/tracediff.py` | compares the sim's 68010 write sequence with MAME's (`mame/oracle.lua`, `RD_BUSWRITES=1`) |

Everything generated lives under `sim/build/` (gitignored). ROM images never
enter the repository.

## The 68010 problem

The core's 68010 is TG68K, which is VHDL; Verilator reads only Verilog and
SystemVerilog. The plan is to convert it once with GHDL's synthesiser:

```bash
ghdl -a --std=08 -fsynopsys -frelaxed rtl/tg68k/TG68K_Pack.vhd rtl/tg68k/TG68K_ALU.vhd rtl/tg68k/TG68KdotC_Kernel.vhd
ghdl --synth --std=08 -fsynopsys -frelaxed --out=verilog -gSR_Read=0 -gVBR_Stackframe=1 -gextAddr_Mode=0 -gMUL_Mode=0 -gDIV_Mode=0 -gBitField=0 -gBarrelShifter=1 -gMUL_Hardware=1 TG68KdotC_Kernel > sim/build/ghdl/tg68k_synth.v
```

(generics fixed to the values the core instantiates). GHDL's Homebrew cask
is disabled on macOS (fails the Gatekeeper check); the official arm64 build is
`ghdl-llvm-6.0.0-macos15-aarch64.tar.gz` on the GHDL GitHub releases page.
Until it is installed, `tools/sim.py build --stub-68010` compiles everything
else so the models and the rest of the core can be exercised.

## Usage

```bash
python3 tools/sim.py roms racedriv-cockpit ~/roms/racedriv.zip          # or --slapstic-free
python3 tools/sim.py build                                              # or --stub-68010
python3 tools/sim.py run --ms 50 --trace sim/build/run/trace.txt        # --service for the test menu
```

The run prints one progress line per emulated millisecond. The build is tied
to one ROM set because the core takes the 200E/210E power-up ZRAM images as
compile-time parameters (the Hard Drivin' core bakes them into the bitstream;
M1 moves them to a download index).

## Comparing with MAME

```bash
SDL_VIDEODRIVER=dummy RD_LOG=run1 RD_BUSWRITES=1 ~/Developer/mame/hd racedriv -rompath ... -autoboot_script ~/Developer/rd-mister/mame/oracle.lua -video none -sound none -seconds_to_run 5
python3 tools/tracediff.py sim/build/run/trace.txt run1.writes.log
```

Writes are the comparison signal: the same program produces the same ordered
sequence of (address, data, byte enables) on both machines until it reads
something timing-dependent (an input port, a status flag), which is exactly
where the FPGA differs from MAME and is what the comparison is for. Fetch
addresses in the sim trace include prefetch and are not compared directly.

## Gotchas found so far

- Verilator's wrapper is a perl script; `/opt/local/bin/perl` on this Mac is
  x86 and fails, so `tools/sim.py` and the Makefile put `/usr/bin` first.
- FX68K mixes blocking and non-blocking assignments to its decoded nanocode
  struct; Verilator's BLKANDNBLK check must be disabled (it then simulates
  correctly, only slower per the Verilator manual).
- FX68K reads `microrom.mem` / `nanorom.mem` relative to the working
  directory; `tools/sim.py run` runs from `rtl/fx68k/`.
- Verilator 5.052 checks `unique case` statements at run time and the FX68K
  ALU trips one at time zero before its first clock; `--no-assert-case`.
- `IKA32010.sv` includes `IKA32010_mnemonics.sv` by bare name: `-Irtl/ika32010`.
- The unused `compact_gsp_vram.sv` (altsyncram) and the Altera PLL wrapper
  are excluded from the sim file list.
