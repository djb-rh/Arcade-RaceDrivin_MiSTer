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
| `sim/tb_asic65.sv` | replays a MAME `.asic65.log` through the ASIC65 model and checks every result (`tools/sim.py asic65-test`) |
| `tools/asic65_sintab.py` | generates and self-checks the ASIC65 SIN/COS table `rtl/asic65/asic65_sin.hex` |

Everything generated lives under `sim/build/` (gitignored). ROM images never
enter the repository.

## The 68010: TG68K through GHDL

The core's 68010 is TG68K, which is VHDL; Verilator reads only Verilog and
SystemVerilog. `tools/sim.py tg68k` converts it once with GHDL's synthesiser
into `sim/build/ghdl/tg68k_synth.v` (32k lines), with the generics fixed to
the values `harddrivin_milestone.sv` instantiates and parameters of the same
names put back on the module header so the instantiation elaborates. It
passes `--latches`: two ALU signals (`rot_rot`, `msb`) are incompletely
assigned in combinational processes, which VHDL simulates as holding their
value, so a latch is the faithful model.

GHDL on this Mac: Homebrew's cask is disabled (it fails Gatekeeper), so the
official arm64 build `ghdl-llvm-6.0.0-macos15-aarch64.tar.gz` from the GHDL
GitHub releases is unpacked under `~/Developer/tools/` (quarantine attribute
removed with `xattr -dr com.apple.quarantine`). `tools/sim.py tg68k` looks
there by default; `--ghdl` points elsewhere. `build --stub-68010` still
compiles everything else with an empty 68010 for model work.

## Usage

```bash
python3 tools/sim.py roms racedriv-cockpit ~/roms/racedriv.zip          # or --slapstic-free
python3 tools/sim.py tg68k                                              # once per TG68K change
python3 tools/sim.py build                                              # or --stub-68010
python3 tools/sim.py run --ms 50 --trace sim/build/run/trace.txt        # --service for the test menu
python3 tools/sim.py asic65-test run1.asic65.log                        # ASIC65 model vs a MAME log
```

The run prints one progress line per emulated millisecond and simulates
about 5.3 ms of machine time per wall second; `build --opt` (-O3, into
`sim/build/obj-opt`, run with `run --opt`) gives 5.7, and `--threads 2`
makes it slower, so the plain build is fine. The build is tied
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
One difference is tolerated and tallied: TG68K writes the high word of a
long first, MAME's 68000 core the low word (MOVEM, PEA); memory ends up the
same. `--timeline N` prints both machines' emulated time every N matching
writes, which is how the 68010 pacing is compared (the sim runs the GSP
download loop about 1.3x faster than MAME's 8 MHz 68010).

MAME-side gotchas (all fixed in `mame/oracle.lua`): `emu.register_stop` is
gone in 0.289 (`emu.add_machine_stop_notifier`); a tap or log referenced
only by a chunk-local is garbage-collected once the script returns and MAME
then calls the tap with a dead function (SIGSEGV in `lua_gettop` about half
a second in), so the tables are globals; querying `machine.time` from inside
a write tap also crashed, so write lines carry the last frame boundary's
time; logs are flushed every frame because `-seconds_to_run` can end the run
without the stop notifier.

## How far the comparison goes

With the stock cockpit set the write sequence matches MAME from reset to
the first read through the slapstic window (930,458 writes, MAME 1.585 s):
the DSK board's RAM, zero-power RAM, track ROM window, control latch and
ASIC65 are all in the comparison. The core has no slapstic (the cabinets
run slapstic-free ROMs), so from there MAME's bank 1 and the core's flat
ROM differ; the DSP32C upload starts 15 ms later. NOTES.md sections 8 and 9
have the details.

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
