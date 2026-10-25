# Toolchain

## Simulation (Mac, native)

- Verilator 5.052 from Homebrew (`brew install verilator`).
- Gotcha: Verilator's `verilator` command is a perl script and this Mac has an
  x86-only MacPorts perl at `/opt/local/bin/perl` ahead of the system perl in
  PATH, which fails with "Bad CPU type in executable". `make test` prepends
  `/usr/bin` to PATH; do the same for manual runs.
- `make test` runs the Verilator regressions (currently the three GSP-memory
  testbenches inherited from the Hard Drivin' core, under `sim/hd_tests/`).
  All three pass on the imported tree (2026-10-24).

## Synthesis (x86 Linux build host)

Decided: Quartus Prime Lite 24.1 on the user's own x86 Linux machine, which
is not yet available (expected within days of 2026-10-24). To fill in when it
arrives:

- Hostname / SSH user:
- Distro and RAM:
- Quartus install path and `quartus_sh` on PATH:
- `make.local` on the Mac with `BUILD_HOST=user@host` and `BUILD_DIR=...`.

`make build` rsyncs the tree there, runs `quartus_sh --flow compile RaceDrivin`
and copies `output_files/` back. The imported project still needs
`generated/zram_cockpit_200e.hex` and `_210e.hex` (from
`tools/hd/prepare_nvram.py <harddriv.zip>`) until M1 replaces the baked ZRAM
image with the MRA index-3 download.

Fallback if the box is unavailable: Docker Desktop with Rosetta on the Mac
(Rosetta is not installed here yet), using an image with Quartus Lite 24.1.

## MAME oracle

MAME 0.289 built from source at `~/Developer/mame` as the `hd` subtarget
(`./hd`). See `mame/README.md` for the measurement patch, the PCH gotcha and
the run commands.

## Python tools

- `tools/mame_machines.py`: ROM/CPU/display facts from `mame -listxml` into
  `tools/data/machines.json` (names, sizes, CRCs only).
- `tools/romset.py`: validate a zip or directory against those facts, with a
  `--slapstic-free` mode for the patched program ROMs.
- `tools/mkmra.py`: generate the MRAs; regenerating the Hard Drivin' cockpit
  MRA reproduces the upstream file byte for byte (regression check).
- `tools/dsp32_report.py`: summarise an `RD_DSP32LOG` run.
