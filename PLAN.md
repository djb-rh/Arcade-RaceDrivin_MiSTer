# Race Drivin' for MiSTer — project plan

Status: draft for review, 2026-10-24. Facts behind every claim are in
[NOTES.md](NOTES.md) with file:line references into the Hard Drivin' core and
MAME. Open decisions are collected in section 8.

## 0. Goal and scope

Build a MiSTer (DE10-Nano) core that runs Race Drivin' compact (`racedrivc`,
A046901 MultiSync hardware, program rev 5) well enough to replace the Atari
board stack in the user's real compact cabinet, plus a custom I/O board that
connects the cabinet's wheel (with force feedback), pedals, shifter, key,
abort, coin door, self-test switch, coin counters and two RS-232 ports to the
core. MAME's `harddriv` driver is the behavioural oracle throughout.

In scope now: compact hardware with the user's slapstic-free ROM set, USB
controls for bench work, the I/O board. Later: stock-ROM slapstic, cockpit
variant, Panorama, link over Wi-Fi.

Hard rules: no ROM data in the repository; every tool consumes MAME-style
zips; the project is GPL-3.0-or-later (forced by the Hard Drivin' core).

## 1. What exists: the Hard Drivin' core

Source: `retrogarage/harddrivin-mister`, one commit (2026-10-24), author
Fulviuus, GPL-3.0-or-later, targets Quartus Lite 24.1, stock MiSTer Main.
Full inventory in NOTES.md section 2.

| Board / block | Implementation | State |
|---|---|---|
| 68010 main CPU | TG68K in 68010 mode on the 48 MHz GSP clock, stepped every 16 clocks (about 3 MHz step rate, tuned so the boot timeline matches MAME within 5%) | Works; not cycle-accurate; MOVEC/BKPT/MOVES unfinished in TG68K |
| Main bus | Hand-written decoder for the cockpit map; a `!HD_COCKPIT` "compact (feasibility)" build already models the compact's wheel counter at 0x400000, port 1 at 0xA80000, brake on ADC ch 6, 512x288 scanout | Compact build exists but is marked feasibility |
| GSP (TMS34010) | birdybro/TMS34010_sv (MIT), near-complete ISA, 48 MHz, I/D caches, posted writes, MAME-style shift-register copies; VRAM in SDRAM at 100 MHz | Works |
| MSP (2nd 34010) | Same core at 50 MHz with 128 KiB BRAM | Cockpit only. **Race Drivin' has no MSP** |
| Pixel expander | Cockpit 1bpp per MAME `hdgsp_vram_1bpp_w`; compact passes writes through | Compact 2bpp path unverified |
| ADSP-2100 | Clean-room core, 8 MIPS, instruction types 1-21, 23, 24, 26 | **No MSTAT mode control, interrupts, TRAP, bit-reverse, secondary bank** |
| Sound board | FX68K 68000 at 8 MHz + IKA32010 TMS32010 at 20 MHz, 12-bit DAC, samples from DDR | Works; DSP interrupt tied off |
| DUART 68681 | Counter/timer only; status always idle; no IRQ | **Stub** |
| Watchdog | Not implemented | Stub |
| ROM loading | MRA index 0 to DDR 0x30000000 (main 1 MiB, ADSP ROMs +0x100000, samples +0x150000); index 1 sound 68000 ROM to BRAM; index 2 NVRAM 4 KiB; index 254 DIPs | Works |
| ZRAM power-up | 200e/210e dumps converted to hex by `tools/prepare_nvram.py` at build time (kept out of git) | Works |
| Inputs | USB gamepad/wheel axes via `hps_io`; gearbox sequential or H-pattern; steering slewed into the compact wheel counter | Works; **no force output, no serial** |
| Tests | 3 Verilator testbenches on the GSP memory adapter only | Thin |
| FPGA fill | Comments say the cockpit build sits at about 93% | Near full |

Not in the core at all: slapstic, DSK board, DSP32C, ASIC65, 68681 channels,
coin counters, lamps, the wheel-force latch.

Code keyed to Hard Drivin' ROM addresses that must be redone: wheel
calibration detection on fetches at 0x019C64/0x01921E, boot checks expecting
reset vector 0x021C and reading 0x10E, calibration windows by fetch page,
diagnostic RAM probes (NOTES.md section 2, "Hard Drivin'-specific code").

### The Race Drivin' delta, concretely

From MAME: `RACEDRIVC_BOARD = multisync_nomsp + adsp + dsk + sound` versus
Hard Drivin' compact `multisync_msp + adsp + sound`. So:

1. Remove the MSP (the compact has none; reads at 0xC04000 return 0xFFFF).
   This frees roughly 128 KiB of block RAM and a 34010 instance.
2. The slapstic 137412-117 is present in Race Drivin' (Hard Drivin' deletes
   it with the MSP). With the slapstic-free set, 0x0E0000-0x0FFFFF decodes as
   flat ROM. Stock ROMs would need an HDL slapstic.
3. Add the DSK board: DSP32C at 40 MHz with 8 KiB + 256 KiB + 2 KiB RAM,
   reached from the 68010 only through its PIO at 0x85C000; DSK control
   latch at 0x85C800 (DSP reset, DSP halt, ASIC65 reset, LED); 64 KiB DSK
   RAM at 0x900000; DSK ZRAM (2816 pair) at 0x910000; ASIC65 at
   0x914000/0x918000; 256 KiB DSK ROM window at 0x940000; DSP32 PIF to 68010
   IRQ level 4.
4. Make the 68681 real: two channels, programmable baud, IRQ level 6, both
   TX/RX paths exposed.
5. Surface the outputs: wheel-force byte at 0xB00000, coin counters (wr0
   functions 6/7), lamps (nwr 2/3), DSK LED.
6. ROM regions: full 1 MiB main program, 5th sound serial ROM (region
   0x50000), DSK ROM 128 KiB stock (256 KiB for the Stock Car set), ADSP
   object ROMs 4 x 64 KiB.
7. ADSP program uses `ENA/DIS AR_SAT`, `M_MODE`, `TIMER`, `AV_LATCH` and 421
   `DO UNTIL` loops: MSTAT handling must be added to the ADSP core (or shown
   unnecessary by tracing which paths execute).
8. Replace every Hard Drivin' ROM-address hook with Race Drivin' equivalents
   or, better, with hardware-faithful behaviour that needs no hooks.
9. The GSP "protection" fail counter MAME zeroes at GSP 0xFFF95CD0 hints at a
   timing or consistency check in the compact GSP program; investigate in
   MAME before assuming the FPGA GSP passes it.

## 2. The hard parts and the chosen options

### 2.1 DSP32C (the DSK physics processor)

No HDL implementation exists anywhere. References: MAME `dsp32.cpp`
(BSD-3), the DS94-084 datasheet, the DSK schematic from Jed Margolin, and the
user's disassembly of the rev 5 program.

What the Race Drivin' program needs (measured, NOTES.md section 4): about
22,000 instruction words; CAU 24-bit integer ALU, loads/stores with
post-increment pointers, immediate loads, goto/call/return and conditional
branches with one delay slot; DAU floating-point multiply-add in the DSP32C
format (8-bit exponent, 24-bit two's-complement mantissa) with float, float24,
int, ifalt conversions; the PIO (PAR/PDR DMA with autoincrement, PCR, PIR,
EMR/ESR); no `do` loops, no serial I/O, no interrupts. MAME's implemented
subset is the upper bound and MAME itself models the DAU in `double`, so the
oracle is behavioural, not bit-exact.

Options:

| Option | Assessment |
|---|---|
| **A. Write a clean-room DSP32C core in SystemVerilog** (recommended) | Bounded scope (the subset above). The DAU is the only novel block: a 32-bit custom-float multiply-add pipeline on Cyclone V DSP blocks, plus conversions. Multi-cycle execution is acceptable as long as average throughput is at or above 10 MIPS; the 68010 talks to it through mailboxes and polls results, and the game re-evaluates segments every 3 frames. Verified in Verilator against instruction traces dumped from MAME. |
| B. Interpret the DSP32C program on a soft RISC-V core | 10 MIPS x roughly 50 host instructions per DSP32 instruction is about 500 MIPS, beyond a soft core on this FPGA. Rejected. |
| C. Emulate the DSP32C on the HPS ARM (Cortex-A9) | Enough compute, but PIO register accesses from the 68010 are synchronous bus cycles; bridging them to Linux user space breaks timing and the stock-Main convention. Keep only as a desperation fallback. |
| D. Translate the DSP32C program ahead of time into native FPGA code | Game data (segment tables) is uploaded at runtime and the program is data-driven; translation buys nothing over A. Rejected. |

Pre-work before HDL (cheap, de-risks A): instrument MAME's `dsp32.cpp` to log
every distinct opcode form executed, the maximum address touched in each RAM
region (does the program really use 256 KiB at 0x600000 or only about 128
KiB?), instructions per frame, and the PIO transaction pattern. This fixes
the implementation subset, the RAM budget (BRAM vs SDRAM) and the required
throughput.

### 2.2 ASIC65 (TMS32015 with undumped mask ROM)

The real chip is undumped in every Race Drivin' set, so a TMS320C1x core is
useless here. MAME's `ASIC65_STANDARD` is a software simulation: a 32-word
parameter FIFO, a command register, and result generators for REFLECT,
CHECKSUM, VERSION, RAMTEST, RESET, TMATRIXMULT, MATRIXMULT, SIN, COS,
YORIGIN, TRANSFORM; it admits the game also issues commands it does not
understand.

Chosen option: **port MAME's STANDARD simulation to HDL** as a small FSM: a
parameter RAM, a 3x3 s16 by three s32 matrix multiply (sequenced through a
couple of hardware multipliers), SIN/COS from a quarter-wave table generated
at build time from MAME's exact formula so results match MAME to the integer,
TRANSFORM multiplies and shifts, and the same answers MAME gives for unknown
commands. Verified by logging command/parameter/result streams in MAME and
replaying them through a Verilator testbench.

Fallback if MAME's simulation proves insufficient on hardware: none needed
for parity with MAME; improving on MAME would require dumping the chip,
which is out of scope (note the Morse-code anecdote on Margolin's site
suggests the part has an executable ROM that could one day be read).

### 2.3 Slapstic 137412-117

Chosen option: **slapstic-free patched ROMs first**. The user's
`rdtrack.stockcar --slapstic free` produces a compact set in which the Y
window is read linearly, the chip-probe halt is skipped and the self-test
checksums read flat windows. The core then needs plain ROM at
0x0E0000-0x0FFFFF and nothing else. The MRA will reference the patched set
with no CRC enforcement so users can build it themselves with the user's
tools. Stretch goal: an HDL 137412-117 (MAME `slapstic.cpp` has the whole
algorithm; a few hundred lines) so stock sets work; it slots into the same
ROM-window decode.

### 2.4 GSP timing and throughput

The Hard Drivin' core already runs the GSP at 48 MHz with caches and MAME-style
shift-register copies. Risks specific to Race Drivin': the 2bpp expander
window on the compact (0x02000000-0x020FFFFF; the compact core path passes
writes through and must be checked against MAME's `hdgsp_vram_2bpp_w`), the
`m_gsp_multisync` halved shift-register copies and mask table, the HEBLNK /
HSBLNK partial-update hook, and the protection fail counter. Approach:
compare frame hashes and GSP register traces with MAME on fixed input replays;
fix in the scanout and memory adapter where they differ. The compact raster is
646x308 at 12 MHz (512x288 visible), 60.3 Hz, about 18.6 kHz horizontal,
which the analog I/O board can emit natively for the cabinet monitor.

### 2.5 68010 accuracy

The existing core's "step every 16 clocks" model is tuned to Hard Drivin'. Race
Drivin' adds DSK uploads and polling. Plan: keep the model to boot, but add a
proper cycle-count-based pacing (TG68K reports bus cycles; drive it at a true
8 MHz-equivalent) once the oracle traces show where timing diverges.

### 2.6 Sound board

Already implemented. Needs the 5th serial sample ROM, Race Drivin's ROMs, and
confirmation the DSP32 PIF IRQ (level 4) does not collide with anything the
sound path uses (it does not in MAME; the sound board raises no main-CPU IRQ).

### 2.7 FPGA budget

The cockpit build is near full. Removing the MSP (128 KiB BRAM plus logic) and
the cockpit-only diagnostics pays for the DSP32C (estimate 4-8k ALMs, a dozen
DSP blocks, 8 KiB + 2 KiB BRAM) and the DSK RAM (64 KiB BRAM). The DSP32C's
256 KiB RAM region is the swing item: if MAME tracing shows the program uses
about 128 KiB, it fits in the BRAM the MSP vacates; otherwise it goes to SDRAM
beside VRAM with a small cache. DSK ROM (256 KiB) lives in DDR like the other
ROMs.

## 3. Cabinet I/O: what MiSTer offers and what to build

### 3.1 Constraints from the DE10-Nano and MiSTer

- With the SDRAM module and the **analog I/O board** fitted (needed for the
  cabinet's monitor and speakers), the only free FPGA pins are the **7
  open-drain 3.3 V user-port lines** (USB-3-shaped socket; pin 1 = 5 V,
  pin 4 = GND, D-/D+ = USER_IO[1]/[0], SS pins = USER_IO[2..5], pin 7 =
  USER_IO[6] via the IO6 jumper on I/O board 6.1+). The on-board LTC2308
  12-bit ADC is also FPGA-driven but its inputs sit under the I/O board and
  are used for audio-in.
- The Digital I/O board instead leaves all 36 GPIO_1 pins free, but gives
  no analog video or audio.
- USB HID gives 8-bit axes and buttons in, and only rumble out. There is
  no game-driven constant-force path to a USB wheel, so force feedback
  cannot be done with a USB wheel in stock Main.
- Serial: the core's `UART_*` pins reach the ARM's `/dev/ttyS1` (bridgeable
  by Main to USB serial, TCP or UDP), and the core can also drive raw async
  serial on the user port (ao486 puts COM2 there).

### 3.2 Chosen architecture

**Analog I/O board for video and sound, plus one custom "cabinet board" on
the user port.** The cabinet board carries a small MCU and all cabinet
electrical interfaces; the core talks to it over a framed serial protocol.

Pin budget on the 7 user-port lines (proposal):

| Line | Use |
|---|---|
| USER_IO[0], [1] | Full-duplex UART to the MCU at 1-2 Mbaud: input frames (switches, pedal ADC values, wheel count or raw edges, link-present) at 1 kHz; output frames (force byte, lamps, coin-counter pulses, DSK LED) |
| USER_IO[2], [3], [4] | Wheel quadrature A, B and index straight into the FPGA, so the core's 0x400000 counter is a real hardware counter like the original |
| USER_IO[5], [6] | Serial A (link, J2) TX and RX as raw TTL, through a MAX3232 on the cabinet board, so link latency is identical to the original DUART |

Serial B (J3, the side-pod stream, transmit-only in the user's patch) is
carried inside the MCU protocol frames and re-emitted by an MCU UART through
a second MAX3232. If link play over the MCU proves fine, Serial A can move
into the frames too and free two lines.

Cabinet-board functions:

- **Pedals**: gas and clutch pots and the force-brake transducer read by the
  MCU's 12-bit ADC and sent as 8-bit values matching the ADC0809 ranges
  (brake 0xF0 released to 0x20 full).
- **Shifter and switches**: four maintained gear switches, key, abort, aux
  coin, coin 1/2, self-test, DIAGN, all active low with pull-ups, debounced
  on the MCU.
- **Outputs**: two coin-counter drivers, two lamp drivers, DSK LED.
- **Force feedback**: the MCU receives the 8-bit force byte every frame.
  Option F1 (faithful): drive the cabinet's original motor-amp board through
  its latch interface, reproducing the game board's output signals (the
  cockpit amp's interface is partly documented from the 044253-01 schematic;
  the compact's must be measured in the cabinet). Option F2 (modern): a
  sign-magnitude PWM H-bridge (BTS7960-class or a Suzo-Happ 50-2000-05
  active-wheel driver) with a separate motor supply. Start with F1 if the
  cabinet's amp works, F2 as the fallback.
- **RS-232**: two MAX3232 channels for J2 and J3 with the original pinout
  (TX pin 7, RX pin 6, GND 4/5), plus the "link present" sense on pin 11.
- **Wi-Fi link bridge**: if the MCU is an ESP32-S3, the Serial A stream can
  additionally be mirrored over UDP/TCP for linked play between cabinets,
  folding the user's ESP32 bridge idea into the same board. Latency and
  jitter tolerance of the link protocol is unknown and must be measured.
- Power: 3.3 V logic from the user port's 5 V pin or the cabinet's +5 V;
  level shifting is unnecessary at 3.3 V open-drain with pull-ups.

Alternatives considered:

- Digital I/O board plus a parallel GPIO_1 cabinet board without an MCU:
  cleaner electrically, but loses analog video and audio, which the cabinet
  needs. Rejected unless the monitor is replaced.
- USB HID devices (the user's G29 works today) plus a separate link bridge:
  the bench path for milestones 1-5, never the cabinet path, because there
  is no force output and the shifter/key/coin wiring would need a USB
  encoder anyway.
- Abusing `joystick_rumble` as a torque word to a custom USB device: tens of
  milliseconds of latency through Main's poll loop; rejected.

### 3.3 Core-side plumbing

A `rd_cabinet_io` module decodes the frame protocol, presents the same signals
the USB path presents (12-bit wheel target or quadrature edges, three 8-bit
pedals, switch vector), and takes the output latches from the main bus. An OSD
option selects USB or cabinet input so the same build serves bench and
cabinet. The 68681 model exposes both channels as TX/RX pairs with baud-rate
generators, routed to the user-port lines or into the frame protocol.

## 4. Verification strategy: MAME as oracle

1. **Deterministic replays.** MAME `-record`/`-playback` or Lua-scripted
   inputs (the user already has `link2.lua`, `e2e_compact.lua`) drive the
   same input sequence into MAME and into the core.
2. **Trace dumps from MAME** via small patches or Lua: 68010 PC trace and
   bus writes to selected ranges; DSP32C PC and register deltas per
   instruction (`dsp32.cpp` hook); ASIC65 command/parameter/result stream;
   DUART register writes and TX bytes; per-frame VRAM or screen hashes;
   physics variables at 0x900C70 onward; the 0x900D28 input block.
3. **Verilator on the Mac** (native arm64, Homebrew): block-level
   testbenches first (DSP32C in lock-step with MAME traces, ASIC65 replay,
   68681 loopback), then a whole-core simulation harness with DDR/SDRAM
   models loaded from a MAME zip at run time (ROMs never enter the tree).
4. **On hardware**: the Hard Drivin' core's OSD diagnostic pages (PC, GSP
   state, illegal-opcode flags) are kept for bring-up; a "live controls"
   page already exists.
5. Each milestone states the comparison that proves it (section 5).

## 5. Roadmap

Each milestone ends in something that runs and a comparison that passes.

**M0 — Toolchain and import (no HDL changes).**
Set up Quartus (section 6), Verilator, Python tooling and CI. Import the
Hard Drivin' core into `rtl/` and `sys/` with a NOTICE recording the base
revision. Rebuild the unmodified cockpit core and run it on the user's MiSTer
to prove the toolchain. Write the MAME trace tooling in `mame/`. Done when a
locally built RBF boots Hard Drivin' and the oracle scripts produce traces.

**M1 — Compact main board runs the Race Drivin' program to its first DSK
dependency.**
Start from the compact build; drop the MSP; flat Y window; Race Drivin' MRA
for the slapstic-free compact set (main 1 MiB, ADSP ROMs, 5 sample ROMs, sound
ROM, 200e/210e); replace Hard Drivin' ROM hooks; stub DSK registers to known
values. Done when the 68010 PC trace matches MAME from reset until the first
DSK access, and the self-test menu is reachable with the service switch.

**M2 — DSK board without the DSP32C.**
DSK RAM, ZRAM, ROM window, control latch, IRQ 4 plumbing, ASIC65 simulation,
full 68681 (two channels, baud generators, IRQ 6). Done when the self-test ROM
checksums for DSK and ASIC65 pass, the ASIC65 command/result stream matches a
MAME log, and the boot sequence reaches the DSP32C upload.

**M3 — DSP32C core.**
Standalone core in Verilator, lock-step against MAME instruction traces of the
real program; then PIO integration; then on hardware. Done when the game
reaches attract with the drone cars driving, and the physics block at
0x900C70 matches MAME frame-for-frame on a scripted input replay.

**M4 — Playable with USB controls.**
Adapt the existing USB input mapping to the compact's Race Drivin' ports:
wheel counter and centre index, pedals, maintained shifter switches, key,
abort, coins, self-test, DIP/DIAGN; surface the force byte, counters and lamps
on debug pins and the OSD. Done when calibration completes and a full race
can be driven; frame hashes compared with MAME on an attract-mode replay.

**M5 — Serial.**
Link play between the core and a MAME instance (and then two cores) over a
USB-serial adapter or the user-port UART; the side-pod stream on Serial B
decoded by the user's `podlink.py`. Done when LINKED GAME 1/2 completes a race
against MAME and pod packets parse.

**M6 — Cabinet board.**
Frame protocol spec, KiCad board, MCU firmware, `rd_cabinet_io`. Bench with
the real wheel, pedals and shifter on the desk, then force feedback against
the cabinet's motor amp, then installation. Done when the cabinet plays with
every control and the coin counters count.

**M7 — Polish and stretch.**
Cycle-accurate 68010 pacing; HDL slapstic for stock sets; cockpit variant;
Panorama centre and side boards (the ADSP-only side board is small);
Wi-Fi link bridge; release packaging (RBF, MRAs, docs).

## 6. Tooling and where synthesis runs

- **Synthesis**: Quartus runs only on x86 Linux/Windows. On this Apple
  Silicon Mac the practical route is Docker Desktop with Rosetta (not yet
  installed) using a Quartus image; expect several-times-slower builds and
  give Docker 8 GB or more. An x86 Linux box or a self-hosted GitHub Actions
  runner is faster and is the recommended primary if available. Version:
  the Hard Drivin' core builds on Quartus Lite 24.1 (its qsf and PLLs are
  24.1); MiSTer's standard is 17.0 (vanishing from Intel's site but baked
  into `raetro/quartus:17.0`). Recommendation: stay on 24.1 to inherit the
  Hard Drivin' project unchanged, building our own Docker image from the
  24.1 Lite installer; revisit if timing or framework issues appear.
- **Simulation**: Verilator 5 via Homebrew (native arm64). MAME 0.289 is
  already built locally as the oracle.
- **Python 3** for MRA generation, ROM-set validation from zips, trace
  comparison, table generation (ASIC65 sine), NVRAM preparation.
- **Repo layout**:

```
PLAN.md NOTES.md README.md LICENSE NOTICE
RaceDrivin.qpf/.qsf/.sdc, RaceDrivin.sv   top-level MiSTer project (M0+)
rtl/        core RTL: imported HD blocks plus dsk/, dsp32c/, asic65/, duart/, io/
sys/        MiSTer framework (vendored, base revision in NOTICE)
sim/        Verilator testbenches and the whole-core harness
tools/      Python: MRA build, zip validation, trace diff, table generators
mame/       oracle patches and Lua scripts (trace dumps, replays)
hw/io-board/   KiCad cabinet board;  hw/firmware/  MCU firmware
docs/       protocol spec, cabinet wiring as measured, bring-up notes
releases/   RBF + MRA
```

- **Branching**: `main` always builds; milestone branches merged by PR.

## 7. Risks

| Risk | Mitigation |
|---|---|
| DSP32C DAU float semantics differ from MAME's `double` model in visible ways | Lock-step traces on real program data; accept differences only where MAME is itself approximate |
| DSP32C RAM footprint exceeds free BRAM | Measure in MAME first; SDRAM fallback with cache |
| 68010 pacing model breaks Race Drivin' boot or link timing | Cycle-based pacing in M7 if traces diverge |
| GSP protection counter or 2bpp expander path misbehaves | Investigate in MAME at M1; frame-hash comparison |
| Quartus on Apple Silicon too slow or unstable | x86 Linux box / CI runner |
| Compact motor amp interface unknown | Measure on the cabinet before board layout; F2 fallback |
| Link protocol intolerant of MCU/Wi-Fi latency | Keep Serial A on raw user-port lines; measure before moving it |

## 8. Open decisions for the user

1. **Where does Quartus run?** Docker+Rosetta on this Mac, an x86 Linux
   machine you own, or a cloud/CI runner? Do you have an x86 Linux box?
2. **Quartus version**: stay on 24.1 like the Hard Drivin' core
   (recommended) or move to MiSTer's 17.0?
3. **I/O architecture**: analog I/O board plus a user-port MCU board
   (recommended), or Digital I/O board plus a parallel GPIO_1 board with an
   external video solution?
4. **MCU**: ESP32-S3 (folds in the Wi-Fi link bridge) or RP2040/STM32
   (simpler, no radio)?
5. **Force feedback**: drive the cabinet's original motor amp (is it present
   and working? can we trace its interface?) or a modern H-bridge?
6. **Monitor**: keep the compact CRT fed natively at about 18.6 kHz from the
   analog board (needs a sync test), or an LCD via HDMI?
7. **Slapstic**: slapstic-free only (recommended now), HDL slapstic later?
8. **Scope**: compact first, cockpit (`racedriv`, which you also own ROMs
   for) later? Panorama?
9. **Upstream relationship**: fork quietly, or contact Fulviuus about a
   shared tree, since the compact and DSK work could flow back?
