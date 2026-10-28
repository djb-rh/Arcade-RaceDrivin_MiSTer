# Race Drivin' for MiSTer

An FPGA implementation of Atari's Race Drivin' (1990) for the DE10-Nano
MiSTer. It covers the cockpit (A045988 "driver" board, `racedriv`) first;
the compact (A046901 MultiSync, `racedrivc`) is a feasibility build and
not released yet. The long-term aim is to replace the original board stack
in real cabinets, together with a custom I/O board for the cabinet's wheel,
pedals, shifter, switches and coin door.

## Status

**First hardware release, 2026-10-27.** The cockpit core fits the DE10-Nano
(93% of the logic, 75% of the block RAM), meets timing in every corner at
its real clocks, and boots on a MiSTer into the self-test, the attract
mode, the champions and credits screens and the driving demo with the
dashboard, from a standard MAME ROM zip. Gameplay with USB controls has not
had a long session yet; sound, the force-feedback wheel link and the
cabinet I/O board are untested on hardware. Expect rough edges.

What is in the core: the 68010 main CPU, the TMS34010 GSP with its display
pipeline, the ADSP-2100 and the DSK board with the DSP32C (bit-exact
against MAME's model), the ASIC65, the slapstic, the MC68681 DUART, the
ADC inputs, the sound board, NVRAM, and the cabinet I/O link.

## Installing

1. Copy `releases/RaceDrivin_cockpit_YYYYMMDD.rbf` to `/media/fat/_Arcade/cores/`.
2. Copy `releases/Race Drivin' (Cockpit, rev 5).mra` to `/media/fat/_Arcade/`.
3. Put `racedriv.zip` (the MAME set) in `/media/fat/games/mame/`.
4. Start the game from the Arcade menu. Hold the service switch at power-on
   for the self-test menu.

The slapstic-free MRA takes a zip whose main-CPU ROMs have the slapstic
removed (`tools/mkmra.py --slapstic-free`). The compact MRAs are
generated for a build that does not exist yet.

Controls are on the OSD: gamepad or wheel, pedals on sticks, buttons or
triggers, sequential or H-pattern gearbox, USB or the cabinet board.

## Building and testing

- `docs/toolchain.md`: Quartus Lite 24.1 on an x86 Linux host driven over
  SSH (`make build`, about 35 minutes).
- `docs/simulation.md`: the whole-core Verilator harness with the real
  TG68K, the lock-step DSP32C and DUART tests, and the comparison of the
  68010's write sequence against MAME (`tools/tracediff.py`).
- `make test` runs the unit regressions; `make check` the release hashes
  and source hygiene; `make mra` regenerates the MRAs.
- `NOTES.md` has the sourced findings behind every decision, section by
  section, and `PLAN.md` the roadmap.

MAME's `harddriv` driver is the behavioural reference throughout: traces
from an instrumented MAME (the small patches are in `mame/`) are compared
with the simulated core.

No ROM data is or may be committed to this repository. Tools work from
MAME-style ROM zips supplied by the user.

## Credits and licence

This project extends the Hard Drivin' MiSTer core by Fulviuus
(<https://github.com/retrogarage/harddrivin-mister>, GPL-3.0-or-later),
which provided the TMS34010, the memory fabric, the video path and the
MiSTer integration. See `NOTICE` for every third-party component and its
licence.

Licence: GPL-3.0-or-later for project code; third-party blocks keep their
own licences.
