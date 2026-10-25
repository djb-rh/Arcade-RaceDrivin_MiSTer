# Race Drivin' for MiSTer — project plan

Status: draft for review, 2026-10-24. Facts behind every claim are in
[NOTES.md](NOTES.md) with file:line references into the Hard Drivin' core and
MAME. Open decisions are collected in section 8.

## 0. Goal and scope

Build a MiSTer (DE10-Nano) core that runs Race Drivin' on both of its main
boards: the cockpit (`racedriv`, A045988 "driver" board) and the compact
(`racedrivc`, A046901 MultiSync board), program rev 5 in both cases. Both
builds must run well enough to replace the Atari board stack in real
cabinets: the user has **four cockpit cabinets and one compact**. A custom
cabinet I/O board, with a variant or configuration for each cabinet type,
connects the wheel (with force feedback), pedals, shifter, key, abort, coin
door, self-test switch, coin counters and two RS-232 ports to the core.
MAME's `harddriv` driver is the behavioural oracle throughout.

Bench video: the user has an EGA-to-VGA converter with a VGA monitor for the
cockpit's 25 kHz raster and a CGA LCD for the compact's 18.6 kHz raster, so
both boards' native output from the analog I/O board can be checked on the
bench without HDMI.

Build order: **cockpit first, then compact.** The Hard Drivin' core's
mature, released path is the cockpit; its compact path is marked
"feasibility". Everything Race Drivin' adds (DSK board, DSP32C, ASIC65,
68681, slapstic-free window) is identical on both boards, so it is built once
on the proven cockpit base, and the compact port then touches only the main
board decode, video and inputs. The user's `slapfree.py` also has direct
support for the cockpit rev 5 set. One source tree with a cockpit/compact
build switch (as the Hard Drivin' core already does with `HD_COCKPIT`)
produces two RBFs and two MRAs.

In scope now: cockpit and compact hardware with the user's slapstic-free ROM
sets, USB controls for bench work, the cabinet I/O board for both cabinet
types, link play between cabinets (four cockpits make linked pairs the
normal case). Later: stock-ROM slapstic, Panorama, link over Wi-Fi.

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

From MAME: `RACEDRIV_BOARD = driver_nomsp + adsp + dsk + sound` versus Hard
Drivin' cockpit `driver_msp + adsp + sound`, and `RACEDRIVC_BOARD =
multisync_nomsp + adsp + dsk + sound` versus Hard Drivin' compact
`multisync_msp + adsp + sound`. The delta is the same on both boards:

1. Remove the MSP (neither Race Drivin' board has one; reads at 0xC04000
   return 0xFFFF). This frees roughly 128 KiB of block RAM and a 34010
   instance on either build.
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
   timing or consistency check in the compact GSP program (MAME applies it
   to the compact only); investigate in MAME before assuming the FPGA GSP
   passes it.

### Cockpit versus compact, concretely

What changes between the two Race Drivin' builds (all already modelled in
some form by the Hard Drivin' core, so this is a port, not new design):

| | Cockpit (`racedriv`, driver board) | Compact (`racedrivc`, MultiSync) |
|---|---|---|
| Wheel | 12-bit ADC ch 0 at 0xB80000 (0x010-0xFF0) plus an 8-bit copy on ADC0809 ch 5 that the game cross-checks before enabling force feedback | Quadrature counter at 0x400000, centre-index edge latch in port 1 bit 14, cleared at 0x408000 |
| Pedals | ADC0809 ch 0 gas, ch 1 clutch; 12-bit ADC ch 1 brake | ADC0809 ch 0 gas, ch 1 clutch, ch 6 force brake (0xF0 released to 0x20) |
| Other analog | ch 2 seat, ch 3/4 shifter Y/X, ch 6 line volts | none (gears are four maintained switches on port 1 bits 8-11) |
| Switch port | IN0 at 0x600000 | IN0 at 0x60C000 |
| Video | 16 MHz, 640x417 total, 508x384 visible, about 25 kHz, 1bpp expander at 0x02000000-0x0207FFFF, 1 MiB VRAM | 12 MHz, 646x308 total, 512x288 visible, about 18.6 kHz, 2bpp expander at 0x02000000-0x020FFFFF, 512 KiB VRAM mirrored, halved shift-register copies |
| ROMs | DSK 136077-4030/4031, ADSP 136077-2021/2023/1022/1024 | DSK 136078-1030/1031, ADSP 136077-1021/1023/1022/1024 |
| Slapstic-free set | `slapfree.py` (SHA1 table has cockpit rev 5) | `rdtrack.stockcar --slapstic free` (pattern-matched edits) |

The force-feedback output (8-bit latch at 0xB00000), coin counters, lamps,
DSK board, DUART, sound board and ADSP board are identical.

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

Pre-work done (M0, NOTES.md section 7): MAME instrumented with
`mame/dsp32-measure.patch`, 240 s of attract on both sets. Results: 63
distinct MAME handlers executed, no `do` loops, no DAU store variants, no
serial or interrupt paths; the chip spins at 10 M instr/s but 99% of that is
a mailbox polling loop and real DAU work is about 16,000 operations per
second; the 256 KiB region is only ever read below 0x620000, so **128 KiB
of block RAM suffices**. So: correctness of the subset is the whole job,
throughput is not a constraint, and the RAM fits where the MSP was.

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
256 KiB RAM region was the swing item; MAME tracing (NOTES.md section 7)
shows the program never reads above 0x61FFFF, so a 128 KiB block RAM with
writes above it dropped fits where the MSP was. DSK ROM (256 KiB) lives in
DDR like the other ROMs.

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
- Serial and network: the DE10-Nano has gigabit Ethernet and MiSTer supports
  USB Wi-Fi dongles, but both belong to the ARM (HPS), not the FPGA. The
  core reaches them only through its `UART_*` pins, which go to the ARM's
  `/dev/ttyS1`; Main's `uartmode` can redirect that one channel to a USB
  serial adapter or to TCP/UDP through MidiLink (a MIDI/modem-oriented
  bridge). One channel, and a custom ARM daemon would depart from stock
  Main. The core can also drive raw async serial on the user port (ao486
  puts COM2 there).

### 3.2 Chosen architecture

**Analog I/O board for video and sound, plus one custom "cabinet board" on
the user port.** The cabinet board carries a small MCU and all cabinet
electrical interfaces; the core talks to it over a framed serial protocol.
One board design serves both cabinet types: the MCU firmware and the core's
build switch select the cockpit or compact input set, and the wheel section
is populated for a pot (cockpit) or a quadrature encoder (compact).

Inputs by cabinet type, as the original boards see them:

| | Cockpit (four cabinets) | Compact (one cabinet) |
|---|---|---|
| Wheel | 10-turn pot: 12-bit ADC ch 0 and an 8-bit copy on ADC0809 ch 5 (the game cross-checks them before enabling force feedback). The MCU samples the pot once at 12 bits; the core presents both readings from it | Quadrature encoder with centre index: counter at 0x400000, edge latch in port 1 bit 14 |
| Brake | Pot on 12-bit ADC ch 1 | Force transducer on ADC0809 ch 6 (0xF0 released to 0x20) |
| Gas, clutch | Pots on ADC0809 ch 0, 1 | Same |
| Seat, shifter | Pots on ADC0809 ch 2 (seat), 3 (shifter Y), 4 (shifter X) | Four maintained gear switches, port 1 bits 8-11 |
| Line volts | ADC0809 ch 6 (fixed value is fine) | none |
| Switches | Key, abort, aux coin, coin 1/2, self-test, DIAGN | Same |
| Outputs | Force byte at 0xB00000, coin counters, lamps (seat lock, abort) | Same |

So the MCU needs at least eight 12-bit ADC channels, three quadrature
inputs, about ten switch inputs and five outputs plus the motor drive.

The MCU is an **ESP32-S3**, so the cabinet board is also the serial and
Wi-Fi bridge the user was already planning to build. Both 68681 channels are
tunnelled inside the user-port frame protocol; the ESP32 presents each one as
a physical RS-232 port (MAX3232, original J2/J3 pinout, for stock link cables
and existing tools) and as a Wi-Fi stream. Serial B (the side-pod data
stream enabled by the user's patch) goes out as UDP, the format `podlink.py
--udp` and the renderer already consume. Serial A (the link) becomes a
point-to-point tunnel between two cabinets' ESP32s, or a cable.

Pin budget on the 7 user-port lines (proposal):

| Line | Use |
|---|---|
| USER_IO[0], [1] | Full-duplex UART to the ESP32 at 1-2 Mbaud: input frames (switches, ADC values, link-present, Serial A/B received bytes) at 1 kHz; output frames (force byte, lamps, coin-counter pulses, DSK LED, Serial A/B transmitted bytes). Two 38400-baud channels add under 8 kB/s each way, well inside the budget |
| USER_IO[2], [3], [4] | Compact: wheel quadrature A, B and index straight into the FPGA, so the core's 0x400000 counter is a real hardware counter like the original. Cockpit: unused (the wheel pot arrives in the frames) |
| USER_IO[5], [6] | Reserved. Fallback: Serial A TX/RX as raw TTL to a MAX3232 if link play turns out to need cable-level latency |

Link latency must be measured before the board is laid out: the original is
a direct cable with byte latency of about 260 microseconds, Wi-Fi adds
milliseconds of jitter. The user's two-instance MAME link setup with the pty
bridge can have an artificial delay inserted to find the protocol's
tolerance; that result decides whether Serial A stays in the frames, goes
over Wi-Fi, or takes the reserved raw lines.

ADC note: the ESP32-S3's internal ADC is noisy and non-linear, so the pots
(especially the cockpit's 12-bit wheel pot) should go through an external
SPI or I2C 12-bit ADC on the board rather than the internal one.

Cabinet-board functions:

- **Analog inputs**: all pots (cockpit wheel, brake, gas, clutch, seat,
  shifter X/Y) and the compact's force-brake transducer read by the MCU's
  12-bit ADC and sent at 12 bits; the core scales to the 8-bit ADC0809 or
  12-bit ranges the game expects (brake transducer 0xF0 released to 0x20
  full on the compact; 0x010-0xFF0 wheel range on the cockpit).
- **Shifter and switches**: compact's four maintained gear switches; key,
  abort, aux coin, coin 1/2, self-test, DIAGN; all active low with pull-ups,
  debounced on the MCU.
- **Outputs**: two coin-counter drivers, two lamp drivers (seat lock and
  abort on the cockpit), DSK LED.
- **Force feedback**: the MCU receives the 8-bit force byte every frame.
  Option F1 (faithful): drive the cabinet's original motor-amp board through
  its latch interface, reproducing the game board's output signals. The
  cockpit amp (044253-01) is documented from Margolin's schematic apart from
  the exact strobe protocol across its opto barrier, and with four cockpits
  it is the primary target; the compact's amp must be measured in the
  cabinet. Option F2 (modern): a sign-magnitude PWM H-bridge (BTS7960-class
  or a Suzo-Happ 50-2000-05 active-wheel driver) with a separate motor
  supply. Start with F1 on a cockpit, F2 as the fallback and for any
  cabinet with a dead amp.
- **RS-232**: two MAX3232 channels for J2 and J3 with the original pinout
  (TX pin 7, RX pin 6, GND 4/5), plus the "link present" sense on pin 11,
  fed from the tunnelled 68681 channels.
- **Wi-Fi**: Serial B broadcast as UDP pod packets; Serial A tunnelled
  between two cabinets for linked play, subject to the latency measurement
  above. The ESP32 also gives a convenient path for firmware updates and a
  status page.
- Power: 3.3 V logic from the user port's 5 V pin or the cabinet's +5 V;
  level shifting is unnecessary at 3.3 V open-drain with pull-ups.

Alternatives considered:

- MiSTer's own network for the link: the core's single ARM-side UART
  redirected to TCP/UDP by Main. One channel only and non-stock bridging;
  kept as a fallback for a single serial port, not the design.
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

**M1 — Cockpit main board runs the Race Drivin' program to its first DSK
dependency.**
Start from the released cockpit build; drop the MSP; flat Y window; Race
Drivin' MRA for the slapstic-free cockpit set (main 1 MiB, ADSP ROMs, 5
sample ROMs, sound ROM, 200e/210e); replace Hard Drivin' ROM hooks; stub DSK
registers to known values. Done when the 68010 PC trace matches MAME from
reset until the first DSK access, and the self-test menu is reachable with
the service switch.
  *Progress 2026-10-25:* in simulation, with the real TG68K and two core
  changes (GSP host port reachable while /GSPRES is held; `MSP=0` makes the
  MSP absent), the program's write sequence matches MAME exactly from reset
  to the first DSK RAM read (884,235 writes, 1.37 s of machine time). Still
  to do for M1: Race Drivin' ROM hooks/MRA in the Quartus top, the self-test
  menu check, and the same on hardware (NOTES.md section 8).

**M2 — DSK board without the DSP32C.**
DSK RAM, ZRAM, ROM window, control latch, IRQ 4 plumbing, ASIC65 simulation,
full 68681 (two channels, baud generators, IRQ 6). Done when the self-test ROM
checksums for DSK and ASIC65 pass, the ASIC65 command/result stream matches a
MAME log, and the boot sequence reaches the DSP32C upload.
- Progress 2026-10-25: DSK RAM, zero-power RAM, track ROM window, control
  latch and the ASIC65 simulation are in the core (`rtl/dsk/`,
  `rtl/asic65/`). The stock cockpit set's write sequence now matches MAME
  for 930,458 writes, up to the point where the program reads through the
  slapstic (MAME bank 1, core flat ROM) at MAME 1.585 s, 15 ms before the
  DSP32C upload. The ASIC65 model reproduces all 151 results in a 20 s MAME
  log (`tools/sim.py asic65-test`). Still to do for M2: IRQ 4 plumbing, the
  full 68681, DSK zero-power RAM save, self-test checksums; and to see the
  DSP32C upload in the comparison, either the slapstic-free set on both
  sides or an HDL 137412 (NOTES.md section 9).

**M3 — DSP32C core.**
Standalone core in Verilator, lock-step against MAME instruction traces of the
real program; then PIO integration; then on hardware. Done when the game
reaches attract with the drone cars driving, and the physics block at
0x900C70 matches MAME frame-for-frame on a scripted input replay.

**M4 — Cockpit playable with USB controls.**
Adapt the existing cockpit USB mapping to Race Drivin': 12-bit wheel with the
matching 8-bit copy on ADC channel 5, pedals, seat and shifter pots, key,
abort, coins, self-test, DIP/DIAGN; surface the force byte, counters and
lamps on the OSD. Done when calibration completes and a full race can be
driven; frame hashes compared with MAME on an attract-mode replay. First
release candidate: `RaceDrivin_cockpit.rbf` plus MRA.

**M5 — Serial.**
Full 68681 model with both channels exposed to the frame protocol and, for
bench use before the board exists, to the user-port lines through a cheap
TTL-to-RS-232 adapter. Link play between the core and a MAME instance, then
two cores; the side-pod stream on Serial B decoded by the user's
`podlink.py`. Includes the link-latency tolerance measurement in MAME. Done
when LINKED GAME 1/2 completes a race against MAME, pod packets parse, and
the latency budget for the ESP32 tunnel is known.

**M6 — Compact port.**
Switch the build to the MultiSync main board: compact decode (IN0 at
0x60C000, wheel counter at 0x400000 with centre-index latch, port 1 gears,
force brake on channel 6), multisync video (12 MHz, 646x308, 2bpp expander,
halved shift-register copies, verified against MAME `scanline_multisync`
and `hdgsp_vram_2bpp_w`), compact ROM set and MRA, the GSP protection
counter question. Done when the compact set reaches the same M4/M5 bar as
the cockpit on a MAME replay, and native 18.6 kHz output has been checked
against the cabinet monitor. Second release candidate:
`RaceDrivin_compact.rbf` plus MRA.

**M7 — Cabinet board.**
Frame protocol spec, KiCad board, MCU firmware, `rd_cabinet_io`, cockpit and
compact input sets. Bench with real controls on the desk, then force feedback
against a cockpit's motor amp, then installation in the first cockpit
cabinet; then the compact (quadrature wheel, force brake, compact amp). Done
when a cockpit and the compact each play with every control and the coin
counters count. Linked play between two cockpit cabinets through the boards'
J2 ports is part of this milestone's acceptance.

This milestone can start its hardware design in parallel with M3-M6, since
the board does not depend on the DSK work; only the final integration does.

**M8 — Polish and stretch.**
Cycle-accurate 68010 pacing; HDL slapstic for stock sets; Panorama centre and
side boards (the ADSP-only side board is small); Wi-Fi link bridge; release
packaging (both RBFs, MRAs, docs).

## 6. Tooling and where synthesis runs

- **Synthesis**: Quartus runs only on x86 Linux/Windows. Decided: the
  user's x86 Linux machine is the build host, running Quartus Lite 24.1
  (the version the Hard Drivin' core's qsf and PLLs target). Builds are
  driven from the Mac over SSH by a `make build` wrapper that rsyncs the
  tree and fetches `output_files/*.rbf` and the timing reports back. A
  self-hosted GitHub Actions runner on the same machine is an optional
  later step. Fallback if the box is unavailable: Docker Desktop with
  Rosetta on the Mac (several times slower, 8 GB or more for Docker).
  MiSTer's official 17.0 is not used.
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
| DSP32C RAM footprint exceeds free BRAM | Measured: 128 KiB suffices for rev 5 (NOTES.md section 7); SDRAM fallback only if another revision needs more |
| 68010 pacing model breaks Race Drivin' boot or link timing | Cycle-based pacing in M8 if traces diverge |
| GSP protection counter or 2bpp expander path misbehaves on the compact | Investigate in MAME before M6; frame-hash comparison |
| Linux build box unavailable | Docker with Rosetta on the Mac as fallback |
| Compact motor amp interface unknown | Measure on the cabinet before board layout; F2 fallback |
| Link protocol intolerant of MCU/Wi-Fi latency | Measure in MAME with an artificially delayed pty bridge at M5; two user-port lines are reserved for raw Serial A if needed |

## 8. Decisions

Decided 2026-10-24 with the user:

1. **Quartus host**: an x86 Linux machine the user owns is the build host
   (details to be recorded in `docs/toolchain.md` at M0: hostname, distro,
   RAM, SSH access). Builds are driven from the Mac over SSH; a self-hosted
   GitHub Actions runner on that machine is optional later. Docker-on-Mac is
   the fallback only.
2. **Quartus version**: Lite 24.1, as the Hard Drivin' core uses.
3. **I/O architecture**: analog I/O board for video and sound plus the
   user-port cabinet board (section 3.2). Assumed; no alternative chosen.
4. **MCU**: ESP32-S3, carrying both serial channels and the Wi-Fi link/pod
   bridge (section 3.2).
5. **Force feedback**: drive the cabinets' original motor amps first, by
   reproducing the game board's 8-bit latch signals; the cockpit amp's
   strobe protocol is traced from the 044253-01 schematic and checked on a
   working amp before layout. Modern H-bridge is the fallback.
6. **Monitors**: cabinets keep their monitors, fed natively from the analog
   board (cockpit about 25 kHz, compact about 18.6 kHz), one sync test per
   monitor type. Bench viewing: EGA-to-VGA converter (cockpit), CGA LCD
   (compact).
7. **Slapstic**: slapstic-free sets only for now; HDL slapstic is an M8
   stretch goal. Assumed.
8. **Scope**: both boards, cockpit first then compact; Panorama is a
   stretch goal.
9. **Upstream**: fork quietly for now under GPL-3.0-or-later with full
   attribution; revisit contacting the author once something runs.

Still open: nothing gating M0. Before M7: measure the compact motor amp
interface and the cockpit amp's strobe protocol; the link-latency result
from M5.
