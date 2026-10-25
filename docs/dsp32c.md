# The DSP32C core

`rtl/dsp32c/` is the DSK board's physics processor, an AT&T DSP32C, written
to behave exactly like MAME's model of it (`src/devices/cpu/dsp32`, BSD-3,
Aaron Giles). MAME is the project's oracle: no HDL of this chip exists, the
chip's own floating-point behaviour is only approximately documented, and
the game is known to play correctly on MAME's model. So the core reproduces
MAME, including the ways MAME differs from silicon, and is checked against
MAME instruction by instruction.

## Files

| File | Role |
|---|---|
| `dsp32c_pkg.sv` | instruction classification from opcode bits 31:21 (MAME's dispatch table), MAME-exact conversions between the DSP32C 32-bit float and IEEE double, int/float helpers |
| `dsp32c_fma.sv` | double-precision fused multiply-add, one rounding (round to nearest even), three clocks |
| `dsp32c_core.sv` | CAU, DAU sequencer, pipeline-effect buffers, parallel host port (PIO) |
| `dsp32c_ram.sv` | 8 KiB + 128/256 KiB + 2 KiB RAM at MAME's addresses, little-endian 32-bit words |
| `sim/tb_dsp32.sv` | lock-step test against a MAME trace (`tools/sim.py dsp32-test`) |

## What "exactly like MAME" means

- **Accumulators are IEEE doubles.** MAME converts every DSP32C float to a
  double when it is read from memory (`dsp_to_double`), computes in doubles,
  and truncates back to the 24-bit mantissa on store (`double_to_dsp`). The
  accumulators therefore carry 53-bit mantissas between instructions. The
  core does the same; the DSP32C format only exists in memory. The real
  chip has 40-bit accumulators, so neither is bit-exact to silicon.
- **One rounding per multiply-add.** MAME writes `yval + a * xval` in C++;
  clang on this Mac (and by default on arm64 and x86-64 with FMA) contracts
  that into a fused multiply-add. `dsp32c_fma` computes the exact 106-bit
  product, aligns the addend into a 170-bit field with a sticky bit and
  rounds once. Verified against the C library's `fma` on 200,000 random
  operand sets, and by the lock-step run (half a million DAU operations).
  The `0`/`1` forms (`a = y`, `a = y + x`) use a multiplier of 1.0, which
  gives IEEE addition exactly.
- **Flush and saturate.** After every flagged DAU result MAME sets `|res| <
  5.87747e-39` to +0 (U flag if it was not zero) and clamps `|res| >
  3.40282e38` to that value (V flag). The core uses the same two doubles,
  bit for bit (`37ffffff5fc5cfec`, `47effffdbd19d02c`); note the first is
  slightly below 2^-127, so a value between the two is kept as a tiny
  double even though it stores as 0.
- **Signed zeros matter.** `a = -y` with y = 0 is -0.0 in MAME, and an
  accumulator written as a DAU Z operand keeps the sign; the flag path
  turns it into +0. The core copies and negates where MAME does instead of
  going through the adder.
- **Pipeline effects.** MAME delays three things, by cycle count, and the
  core keeps the same bookkeeping in instruction counts: a DAU memory write
  lands four instructions later (`mbuf`, four slots, processed when the
  slot index comes round); an accumulator read as a multiplier operand
  returns its value from before the writes of the previous two
  instructions (`abuf`, four entries, walked newest to oldest); DAU flags
  tested by conditional branches come from before the previous three
  instructions' writes. `ifalt/ifaeq/ifagt` test the undelayed flags, as
  MAME does.
- **Branches.** One delay slot; the target register is read after the slot
  has executed (so a slot that changes it changes the target). `call`
  stores the address after the slot. A taken branch inside a delay slot
  executes one more instruction and then the outer target wins, which is
  what MAME's recursion does; the program never does this.
- **CAU details copied from MAME**, with the trace as witness: `goto ge/lt`
  test N xor V while condition codes 10/11 in conditional CAU ops test N xor
  C; immediate forms are never conditional (bits 15:12 are immediate); the
  overflow word is `a ^ b ^ r ^ (r >> 1)` on signed 32-bit ints, shifted
  left 8 for the 16-bit forms, and the whole 32-bit word is compared; `r22`
  is the 32-bit constant -1 as in MAME; `load_hi` and `load_hr` differ
  (MAME's `load_hi` does not shift the byte).
- **Host port.** MAME's three register maps (DSP32 compatible, DSP32C 8-bit,
  DSP32C 16-bit) selected by PCR bits 1 and 9, byte lanes by the map entry,
  PAR reads return `par | 1`, PDR accesses trigger the DMA load/store/
  increment exactly as `pio_r`/`pio_w` do, a PCR write that raises bit 0
  resets the chip (PC 0, PCR 1, EMR 0xffff, ESR 0, r0/r16 0, r22 -1, r23 1,
  buffers cleared, other registers untouched). Host accesses are served
  between instructions, as MAME's scheduler interleaves them.
- **Reset and halt lines.** DSPRESTN (DSK latch function 0) low holds the
  core; its rising edge is a device reset. DSPZN (function 1) low stops
  execution. PCR bit 0 clear also stops execution. The host port works in
  all three states.
- Unmapped DSP32C addresses read 0xffffffff (`unmap_value_high`), as for the
  cockpit set in MAME; writes vanish.

## Lock-step verification

`mame/dsp32-measure.patch` adds `RD_DSP32TRACE=<file>` to MAME's DSP32C.
At the top of every `execute_one` it writes the state changes since the
previous record (registers, accumulators as double bits, flag words, PIO
registers, `lastp`, memory writes performed) and the instruction about to
run; host PIO accesses and device resets are logged between records. At the
first record it dumps the 266 KiB memory image to `<file>.mem`.
`RD_DSP32TRACE_FROM=<n>` and `RD_DSP32TRACE_COUNT=<n>` pick a window; a
window starts only where the core can be initialised from the record (not in
a delay slot, no deferred write pending, no accumulator inside the latency
windows), and `RD_DSP32TRACE_DAU=1` waits for the first DAU instruction so
the window lands in a physics burst rather than the idle loop.

```bash
cd /tmp/dsp && SDL_VIDEODRIVER=dummy RD_DSP32TRACE=$PWD/dsp.trace RD_DSP32TRACE_COUNT=3000000 \
  ~/Developer/mame/hd racedriv -rompath "<dir with racedriv.zip>" -nvram_directory nvram -cfg_directory cfg \
  -video none -sound none -nothrottle -seconds_to_run 6 -skip_gameinfo
python3 tools/sim.py dsp32-test /tmp/dsp/dsp.trace
```

`tb_dsp32` loads the memory image, steps the core one instruction at a time
(`step_hold_i`), and at each fetch compares every CAU register, the four
accumulators, both flag words, the DAU flags, the nine PIO registers and
`lastp` with MAME, compares the memory writes of the step as a list, and
checks each host PIO read's result. Results on 2026-10-25: the first
3,000,000 instructions of the cockpit set (upload, boot, 0.3 s of
execution, 526,181 memory writes, 17,091 PIO reads) and 2,000,000
instructions from instruction 10,000,000 inside the DAU-heavy
initialisation (325,000 DAU operations, 222,840 writes) both match with
zero differences. All of the chip's floating-point work in attract mode
happens in that initialisation burst (4.2 s to 6 s); gameplay physics
needs a trace with inputs injected into MAME, still to do.

## Speed

The core takes about 10 to 16 clocks per instruction at 48 MHz, 3 to 5
MIPS against the original's 10. NOTES.md section 7 measured that 99% of the
chip's time is a mailbox polling loop and real work is about 16,000 DAU
operations per second, so this is enough for the game; it changes when the
68010 sees results, which is why the whole-core comparison with MAME is
expected to diverge at the first result the 68010 reads. Pipelining the
sequencer is the lever if latency ever matters.
