# MAME as the oracle

MAME's `harddriv` driver is the behavioural reference for this core. This
directory holds what we add to a local MAME tree to extract traces from it.
Nothing here contains ROM data.

## Contents

- `dsp32-measure.patch`: adds opt-in measurement to `src/devices/cpu/dsp32/`.
  When the environment variable `RD_DSP32LOG` names a file, the DSP32C core
  logs there: a histogram of executed opcodes (11-bit table index and 16-bit
  prefix), the memory footprint at 1 KiB granularity per region with
  read/write counts, an instruction-count mark every 100,000 instructions
  with the emulated time, every PIO register access from the 68010, and
  every reset-bit transition in PCR. Written out at exit. Used to bound the
  FPGA DSP32C's instruction subset, RAM size and required throughput.
- `oracle.lua`: autoboot script that taps the 68010 bus for ASIC65 traffic,
  DSK control and PIO accesses, DUART registers, output latches (wheel force,
  coin counters, lamps), a per-frame physics/input snapshot from DSK RAM, and
  periodic screen CRCs. Streams are selected by environment variables listed
  at the top of the file.

## Building MAME with the patch

Against MAME 0.289 (the user's tree at `~/Developer/mame`, which also carries
their own Race Drivin' patches):

```bash
cd ~/Developer/mame && git apply ~/Developer/rd-mister/mame/dsp32-measure.patch
```

```bash
cd ~/Developer/mame && make -j8 SUBTARGET=hd SOURCES=src/mame/atari/harddriv.cpp REGENIE=0
```

The `hd` subtarget builds only the Hard/Race Drivin' driver and links as
`./hd`. If Xcode's clang changed since the last build, delete the stale
precompiled headers first or every compile fails with "PCH file built from a
different branch":

```bash
find ~/Developer/mame/build/osx_clang/obj -name "*.gch" -delete
```

## Running a measurement

Headless, as fast as possible, 240 emulated seconds of attract mode. On
macOS `-video none` alone still lets SDL open a window that steals focus;
`SDL_VIDEODRIVER=dummy` in the environment prevents that (the recipe from the
user's rdp-fullscreen notes):

```bash
SDL_VIDEODRIVER=dummy RD_DSP32LOG=dsp32.log ~/Developer/mame/hd racedriv -rompath "<dir with racedriv set>" -nvram_directory <copy of calibrated nvram> -cfg_directory <cfg copy> -video none -sound none -nothrottle -seconds_to_run 240 -skip_gameinfo
```

Use a copy of the calibrated NVRAM (MAME rewrites it at exit) so the game
skips calibration and runs its attract demo. `tools/dsp32_report.py` turns the
log into the summary recorded in NOTES.md.

For bus traces add `-autoboot_script ~/Developer/rd-mister/mame/oracle.lua`
with the `RD_*` variables set. Deterministic input for comparisons: record
with `-record name.inp` and replay with `-playback name.inp`, or script inputs
in Lua as the user's `link2.lua` does.

## DSP32C instruction traces

The same patch adds `RD_DSP32TRACE=<file>` (with `RD_DSP32TRACE_FROM`,
`RD_DSP32TRACE_COUNT`, `RD_DSP32TRACE_DAU=1`): per-instruction state deltas,
memory writes and host PIO events for the lock-step test of the FPGA core,
`tools/sim.py dsp32-test <file>`. Format and method: docs/dsp32c.md.

`mame/play.lua` is an `-autoboot_script` that plays a game with scripted
inputs (coin, Key, first gear, full throttle, steering weave from 17 s) so
the DSP32C runs its real-time physics; `RD_PLAY_T0` moves the timeline and
`RD_PLAY_ORACLE=1` loads oracle.lua as well.

`mame/duart_test.lua` exercises the MC68681 through the 68010's address space
(loopback, FIFO, break, parity, counter/timer, output port) and logs every
read to `RD_DUART_LOG`; `tools/sim.py duart-test <log>` replays it against
the RTL model.
