# NOTES — findings log for the Race Drivin' MiSTer core

Working notes. Facts here are sourced; opinions and decisions live in PLAN.md.
Nothing in this repository may contain ROM data. Addresses are 68010 byte
addresses unless marked otherwise.

## 0. Environment (2026-10-24)

- Mac: Apple Silicon (arm64), macOS 27.0.1, 8 cores, 24 GiB RAM.
- Installed: python3 3.14, tclsh. **Not installed**: Quartus, Verilator,
  Icarus, Yosys, Docker/Podman/Colima, QEMU/UTM.
- MAME 0.289 built locally at `~/Developer/mame` (binary `mame`, user patches
  uncommitted in `harddriv.cpp`, `harddriv_m.cpp`, `bus/rs232/pty.cpp`,
  `mame.lst`).
- Reference core cloned as a sibling: `~/Developer/harddrivin-mister`
  (retrogarage/harddrivin-mister, single commit ae9fe0d "Initial Hard Drivin'
  cockpit release", GPL-3.0-or-later; core author Fulviuus).

## 1. The user's own research (racedrivin-tools, rdp-fullscreen)

Source: `~/Developer/racedrivin-tools` and `~/Developer/rdp-fullscreen`
(summarised by reading; see those repos for detail).

### Cabinet and program revision
- Cabinet: Race Drivin' **compact** on **A046901 MultiSync** boards. Runs
  `racedrivc` rev 5 program (136078-5001..5004 R/S pairs etc.). Slapstic-free
  compact + Stock Car set ran on real A046901 hardware on 2026-10-04.
- NVRAM: 200E = MK48T02B-15, 210E = MK48Z02B-15 (two 2 KB "zero power" RAMs,
  byte lanes). MAME ships these as `racedrivc.200e/.210e`-style dumps.
- Video (compact): 308 lines, 60.3 Hz, ~18.6 kHz horizontal. Cockpit is 25 kHz.
  Side-pod program timing table gives VTOTAL 307, HTOTAL 322.
- 3D render rate measured ~18 Hz (cockpit).

### Slapstic (137412-117 / -115)
- Banks the 128 KB window 0x0E0000-0x0FFFFF (the 200Y/210Y ROM pair).
- `slapfree.py` (racedrivin-tools) removes banking: bank n sits flat at ROM
  offset n*0x8000; two code edits (pointer mask `andi.l #$FFFE7FFF` ->
  `#$FFFFFFFF`; `bne.b` -> `bra.b` skipping the "BAD IC 137412-XXX" halt),
  12 self-test `lea` edits, y2k, and one checksum fill byte per EPROM.
  Only the R and S pairs change; Y pair is burned stock.
- Compact edits are found by byte pattern in `rdtrack/stockcar_edits.py`
  (`rdtrack.stockcar --slapstic free`); `slapfree.py`'s SHA1 table only
  covers cockpit rev 5 and the two Panorama sets.
- **Consequence for the core: the Y window must decode as plain flat ROM.
  No slapstic logic needed if the slapstic-free set is used.** The power-up
  probe still runs and simply finds no chip.

### DSK board (from the main-program side)
- DSK ROM mapped at 0x940000 (30E even / 10E odd, 128 KB stock, 256 KB with
  2x27C010 for the Stock Car set). Track records, placements, cells,
  segments, route nodes, drone tables. Self-test sums only the first 64 KB.
- **The DSP32C program is NOT in the DSK ROM.** It lives in the main
  program's 200Y/210Y pair (slapstic window), stored 32-bit-reversed, with a
  boot stub at 0x0E8C28. The 68010 uploads it, and later the segment table,
  through the DSP32C PIO at 0x85C000 (PCR at 0x85C016 = 0x61, PAR 0x4000),
  segment table to DSP address 0x614000 (capacity 727 segments, to 0x61F600).
- Physics results come back to main RAM at 0x900C70 (current segment at
  +0x58). Physics inputs at 0x900D28 wheel, 0x900D2A brake, 0x900D2C clutch,
  0x900D32 throttle, 0x900D38 key. Segment changes evaluated every 3 frames.
- Boot order (LED notes): reset vector at $21C; touch ADSP ($818060), sound
  ($840000, $84C000), DSK ($85C8xx); self-test bit; GSP init (~0.5 s); jump
  via vector table at $20000 into the T pair; clear RAM and DSK RAM, read
  DSK ROMs; interrupts on ~1.7 s after reset. Watchdog: 30 Hz counter
  cleared by writes to $608000, bites ~0.26 s after the last kick.

### ADSP (object/geometry) side
- Window mapping: ADSP data word = (68010 address - 0x808000)/2. Mover block
  at 0x809400 (27 x 25 words), gather buffer 0x809946, viewpoint 0x80BFCE.
  Output stream to shared memory at 0x810000, copied by the 68010 to the GSP.
- Object ROM catalogue format and model layout documented in
  rdp-fullscreen WORLD.md.

### Inputs (compact)
- Wheel: quadrature **encoder counter at 0x400000**, centre index at bit 6 of
  0xA80000. 8-bit ADC (ADC0809): ch0 gas, ch1 clutch, ch6 force brake
  (reads 0xF0 released, falls to 0x20 at full pressure). IN0 at 0x60C000.
  Write-enable latches at 0x6040xx. Brake calibration in ZRAM 0xFF4400..28.
- J6 (coin door): 1 COIN1, 2 COIN2, 3 SELF-TEST, 4/8 GND, 5 key, 6/7 coin
  counters, 9 DIAGN; all active low. J5 (controls): 8 key/engine start,
  9 abort/game start, 7 aux coin, 10/11 GND. J1 power: +5, +15, GND, -rail.
- **Wheel, pedal and shifter wiring, sound output and video connector are
  not documented in multisync-a046901.md** (to be measured on the cabinet).

### Serial
- J2 = Serial A (DUART ch A), J3 = Serial B (ch B); same pinout: 7 TX, 6 RX,
  4/5 GND, 9 switched copy of TX, 10 = +12 V via 10 ohm, 11 = +12 V via
  220 ohm switched, read back as "link present". Both channels 38400 8N1
  at boot. Stock game never uses Serial B.
- Link cable: null modem, only TX/RX/GND matter; neither program reads the
  DUART input port outside self-test. Link mode selected by GAME TYPE =
  LINKED GAME 1/2 in the operator menu.
- Side-pod patch (`docs/pod-stream-serial-b.md`): compact rev 5 has an unused
  channel-B transmitter path (IRQ handler 0x4D8CC, putcB 0x4DAEA, ring
  0x90149C). Packet framing `BA type body checksum`; type 01 roster, type 02
  pose. ~12 packets/s racing on the compact.
- No ESP32 / Wi-Fi bridge material exists in either repo yet (only
  `podlink.py --udp` and a MAME pty mirror).

### MAME patches the user relies on
- `serial-b.patch`: adds an `rs232b` slot on DUART channel B in
  `driver_nomsp`. `racedrivcs` clone, `linkplay` replay device,
  `link_mirror.patch`. Lua: `link2.lua` (two linked compacts), `e2e_compact.lua`,
  `e2e_pod.lua`. Driven with a G29 wheel.

## 2. Inventory of retrogarage/harddrivin-mister (reference core)

Paths relative to `~/Developer/harddrivin-mister`. Release build defines
`HD_ARCH_MILESTONE HD_FUNCTIONAL_ADSP HD_SOUND_BOARD HD_LEAN HD_COCKPIT`
(`HardDrivin.qsf:45-51`). Board-level top is `rtl/harddrivin_milestone.sv`
(the name is historical; it is the real top). Targets **Quartus Lite 24.1**.
A `!HD_COCKPIT` "Compact (feasibility)" build exists in the same sources and
already models the compact's wheel counter at 0x400000, brake on 8-bit ADC
channel 6, port 1 at 0xA80000 with gears/key/abort, 512x288 scanout.

### Main CPU
- TG68K (`TG68KdotC_Kernel`, `CPU=2'b01` 68010 mode, VBR stack frames, HW
  multiply; `milestone.sv:2103-2116`). TG68K TODO: MOVEC, BKPT, MOVES not
  finished for 68010 (`tg68k/TG68KdotC_Kernel.vhd:74-77`).
- Runs on the 48 MHz `clk_gsp`, stepped every 16 clocks (~3 MHz step rate)
  tuned so the boot timeline matches MAME within ~5%. **Not cycle-accurate.**
- IRQs (autovectored): L5 periodic 244.14 Hz (cleared by write to 0x60C000),
  L3 GSP HINT, L2 ADSP DIRQ, L1 MSP HINT. No watchdog implemented.
- Address map (`rtl/harddrivin_main_bus.sv:209-245`):
  0x000000-0x0FFFFF program ROM from DDR; 0x400000/0x408000 compact wheel
  counter / edge-latch reset; 0x600000 cockpit switches; 0x604000 LS259 latch
  (ZP1, ZP2, GSP reset, MSP reset); 0x608000 watchdog; 0x60C000 switches +
  IRQ clear; 0x800000-0x83FFFF ADSP board; 0x840000/0x844000/0x84C000 sound
  data/status/reset; 0xA80000 port 1; 0xB00000 8-bit ADC; 0xB80000 12-bit ADC
  + control; 0xC00000/0xC04000 GSP/MSP host regs; 0xFF0000-1F DUART (**timer
  only**: 230.4 kHz tick, status always idle, no IRQ); 0xFF4000-FFF ZRAM
  2Kx16 (writes need ZP1=0, ZP2=1); 0xFF8000-FFFFFF main RAM 16Kx16.
- **No slapstic.** No DSK, DSP32, ASIC65 anywhere (grep confirmed).

### GSP / MSP (TMS34010, birdybro/TMS34010_sv, MIT, ~12.8k lines)
- Near-complete instruction set incl. all PIXBLT forms, FILL, LINE, DRAV,
  field sequencer for 1-32 bit fields. Sticky `illegal_opcode_o` flag.
- GSP at 48 MHz, `FAST_BLIT=1`, no DRAM refresh; video clock 4 MHz cockpit /
  6 MHz compact. 64-line I-cache and D-cache, posted writes, write combining;
  VRAM shift-register transfers done as background block copies MAME-style.
- MSP (cockpit only, 50 MHz, `PIXEL_OPS=0`) with 64Kx16 BRAM (128 KiB) at
  3 wait states. **Race Drivin' compact has no MSP: removing it frees ~128 KiB
  of M10K and logic.**
- GSP memory (`harddrivin_gsp_memory.sv:372-379`, bit addrs): 0xF4000000/
  0xF4800000 control regs; 0xF5000000/0xF5800000 palette (2x 1Kx16);
  0xFF800000+ VRAM; 0x020xxxxx pixel-expander window. Cockpit expander
  follows MAME `hdgsp_vram_1bpp_w`; compact passes writes straight through.
  No separate TMS34012 model.
- VRAM in SDRAM at 100 MHz (burst arbiter + 4-word bursts); 512K words
  cockpit, 256K words compact. Scanout generates its own raster: cockpit
  508x384 visible / 640x417 total at 16 MHz pixel; compact 512x288 at 12 MHz.

### ADSP board (`adsp2100_core.sv`, clean-room, GPL-3)
- Real execution core: instruction types 1-21, 23, 24, 26. **Missing:
  interrupts, TRAP, bit-reverse addressing, secondary register bank, MSTAT
  mode control, instruction cache.** Unsupported -> NOP + `illegal_o`.
  6 clocks/instruction at 48 MHz = 8 MIPS. MAME lock-step switches.
- Board map: 0x800000 program RAM 8Kx24; 0x808000 data RAM 8Kx16 (TDP);
  0x810000 output buffer 2x8Kx16 (BCON); 0x818000 LS259 (ADSPRES, ADSPHALT,
  ADSPBR, BCON, clear GINT); 0x838000 status. ADSP I/O 0x2000-0x2007 (ROM
  read/counter, output write/counter, XFLAG, GINT, MPAGE). Serial object ROMs
  streamed from DDR at byte 0x30100000.

### Sound board
- FX68K 68000 at 8 MHz; IKA32010 (BSD-2) TMS32010 at 20 MHz; program ROM
  32Kx16 BRAM (ioctl index 1); work RAM 8Kx16; DSP program RAM 4Kx16; COM RAM
  512x16; sample ROMs from DDR at byte 0x30150000. 12-bit DAC, 20 kHz pacing.
  DSP interrupt tied off.

### Memory / loading
- MRA index 0 -> DDR 0x30000000 (main ROM 1 MiB, ADSP ROMs at +0x100000,
  samples at +0x150000); index 1 -> sound 68000 ROM (BRAM); index 2 -> NVRAM
  4096 bytes; index 254 -> DIP bytes. DDR read-only client with 2-line cache
  (adapted from Genesis core), arbitrated between main ROM, ADSP, samples.
- ZRAM power-up image comes from the set's 200e/210e dumps via
  `tools/prepare_nvram.py` -> `generated/*.hex` (not in git).
- NVRAM bridge auto-saves ~3 s after a ZRAM write.

### Inputs
- Steering from left-stick X -> 12-bit (deadzone, clamp 0x010-0xFF0); compact
  bus slews the wheel counter toward the target by <=0x7F per read
  (`main_bus.sv:160-184`). Pedals from sticks/buttons/wheel axes; brake mapped
  into transducer range 0xF0..0x20. Gearbox sequential or H-pattern.
  **No force-feedback output. No serial.** `USER_OUT='1'`, UART pins unused.

### Clocks / CDC
- PLL from 50 MHz: 48 (GSP, 68010, ADSP, sound), 50 (MSP), 100 (SDRAM),
  4 or 6 (GSP video). Four clocks declared asynchronous in the SDC.
  Mailbox CDCs for host->MSP and GSP->VRAM.

### Tests / tools
- `tools/test.py`: 3 Verilator ROM-free testbenches, GSP memory adapter only.
  Nothing tests 68010 bus, ADSP, MSP, sound. Comments reference testbenches
  not in the repo (MSP cosim, `prepare_roms.py`).
- `validate_timing.py` (4-corner timing check), `check_release.py` (source
  list via Tcl, hashes, MRA, private-path scan).

### Hard Drivin'-specific code that must be redone for Race Drivin'
- Wheel calibration mode keyed on fetches at 0x019C64 / 0x01921E
  (`main_bus.sv:530-541`).
- Boot checks expect reset vector words FFFF/C000/0000/021C and look at
  0x10E (`main_bus.sv:566-576`).
- Calibration windows detected by fetch-address pages 0x01A3/0x0193/0x0197/
  0x019D and 0x019AA6 (`milestone.sv:1879-1889`).
- Diagnostics assume VBR 0x15000, 0x0188C4, RAM vars 0xFF9134 etc.

### Resource usage
- No fit reports in repo. Comments: "sound revisions at 93% fill",
  "MSP VIDEO=0 saved ~150 ALMs", "no-barrel TG68K saves a few hundred ALMs";
  qsf uses maximum router timing optimisation and a fixed SEED. **Assume the
  cockpit build is near full on the 5CSEBA6; the compact build without MSP
  is the realistic base for adding the DSK board.**
- Project RTL ~9.5k lines (+583 top); third-party: TMS34010 12.8k, FX68K
  5.7k, TG68K 5.7k, IKA32010 2.3k.

### Licences
- Project GPL-3.0-or-later; TMS34010 MIT; TG68K LGPL-3.0+; FX68K GPL-3.0;
  IKA32010 BSD-2; sdram/ddr pieces GPL-2.0+/GPL-3.0+. A derived Race Drivin'
  core must be GPL-3.0-or-later.

## 3. Race Drivin' delta from MAME (src/mame/atari/harddriv*.cpp, 0.289 + user patches)

Line numbers refer to the user's patched tree (harddriv.cpp is ~+368 lines
versus upstream).

### Machine configs
- `HARDDRIV_MASTER_CLOCK` = 32 MHz, `HARDDRIV_GSP_CLOCK` = 48 MHz.
- `driver_nomsp` (:1551): 68010 @ 8 MHz; periodic IRQ 244.14 Hz; **slapstic
  137412-117 banked at 0xE0000-0xE7FFF mirror 0x18000** (32 KB window, 4
  banks of 0x8000 from ROM 0xE0000); watchdog; ADC0809; GSP 48 MHz pixel
  clock 4 MHz x4; M48T02 (200e) + 2816 (210e); MC68681 @ 3.6864 MHz;
  1024-entry palette; screen 16 MHz, 640x417 total, 508x384 visible.
- `multisync_nomsp` (:1636): as above with `multisync_68k_map`/`gsp_map`;
  GSP pixel clock 6 MHz x2; `hdgsp_io_w` hook; screen 12 MHz, 646x308
  total, 512x288 visible.
- `adsp` (:1693): ADSP-2100 @ 8 MHz. (Not ADSP-2101; `ds3` is for other games.)
- `dsk` (:1743): **DSP32C @ 40 MHz**, two 2816 EEPROMs (dsk_10c, dsk_30c),
  **ASIC65 in `ASIC65_STANDARD` mode** (software simulation).
- **RACEDRIV_BOARD = driver_nomsp + adsp + dsk + sound.
  RACEDRIVC_BOARD = multisync_nomsp + adsp + dsk + sound.**
  Hard Drivin' boards are `driver_msp`/`multisync_msp` + adsp + sound, which
  *remove* the slapstic. So RD vs HD = {no MSP, slapstic present, DSK added}.
- `racedrivc_init_common` (:5490): init_dsk, slapstic bank, DSP32 sync hooks,
  GSP protection hack (`hdgsp_protection_w` zeroing a fail counter at GSP
  0xFFF95CD0 for rev 4/5; 0xFFF7ECD0 for rev 1/2), ADSP speedup, GSP speedup
  at 0xFFF76F60 (PC 0xFFF43A00). Speedups/hacks are MAME-only; the FPGA
  needs none, but the protection hack hints at a GSP-side timing check.
- `racedriv1/b1/g1`: init maps `rddsp_unmap_r` over DSP32 0x002000-0x5FFFFF
  and 0x640000-0xFFF7FF because those revisions clear DSP32 RAM and release
  the DSP32 from reset (would crash MAME). Rev 5 does not.

### 68010 memory map (compact; cockpit noted where different)
```
000000-0FFFFF  ROM (slapstic window 0E0000-0E7FFF mirror 18000 -> 4x32KB banks)
400000-400001  R  hdc68k_wheel_r        (compact only; init_multisync(1))
408000-408001  W  hdc68k_wheel_edge_reset_w (compact only)
600000-603FFF  R  hd68k_port0_r         (cockpit only; compact has no 600000)
604000-607FFF  W  hd68k_nwr_w  (LS259: 0/1 CR2/CR1, 2 LC1 lamp, 3 LC2 lamp,
                                4 ZP1, 5 ZP2, 6 /GSPRES, 7 /MSPRES)
               R  hd68k_sound_reset_r (compact; JSA only, returns ~0)
608000-60BFFF  W  watchdog
60C000-60FFFF  W  hd68k_irq_ack_w (level 5)   R port0 (compact)
800000-807FFF  RW ADSP program RAM      808000-80BFFF RW ADSP data RAM
810000-813FFF  RW ADSP buffer (SOM)     818000-81801F W ADSP control (LS259)
818060-81807F  W  ADSP IRQ clear        838000-83FFFF R ADSP IRQ state
840000  RW sound data   844000 R sound status   84C000 W sound reset
85C000-85C7FF  RW hd68k_dsk_dsp32_r/w   ("ASIC61" = DSP32C PIO registers)
85C800-85C81F  W  hd68k_dsk_control_w (LS259: 0 DSPRESTN, 1 DSPZN(halt),
                                       2 ZW1, 3 ZW2, 4 ASIC65 reset, 7 LED)
900000-90FFFF  RW DSK RAM (64 KB, usr3+0x40000)
910000-910FFF  RW DSK ZRAM (2816 pair: dsk_10c on FF00, dsk_30c on 00FF)
914000-917FFF  W  asic65 data_w (even=param, odd=command)  R asic65 read
918000-91BFFF  R  asic65 io_r (returns 0x4000 in STANDARD mode)
940000-9FFFFF  R  DSK ROM (128K words = 256 KB, repeating)
A00000-A7FFFF  W  hd68k_wr0_write (1-4 SEL1-4, 6/7 coin counters)
A80000-AFFFFF  R  port1 (compact: hdc68k_port1_r)  W wr1 (data>>8 -> SELn latch)
B00000-B7FFFF  R  ADC0809 data (odd byte)  W wr2: m_wheel = data>>8 (WHEEL LATCH)
B80000-BFFFFF  R  12-bit ADC  W ADC control
C00000-C03FFF  RW GSP host regs (offset = (offset/2)^1)
C04000-C07FFF  RW MSP host regs (reads 0xFFFF, no MSP)
FF0000-FF001F  RW MC68681 DUART, upper byte (umask 0xFF00), IRQ level 6
FF4000-FF4FFF  RW ZRAM (200e upper byte, 210e lower; write needs ZP1=0,ZP2=1)
FF8000-FFFFFF  RAM 32 KB
```
- Latch-style registers: `(offset>>3)&1` is the value, `offset&7` the
  function (word offsets): function f set to 1 is at `base + f*2 + 0x10`.
- IRQ levels: 1 MSP (absent), 2 ADSP GINT, 3 GSP, **4 DSP32 PIF**
  (`hddsk_update_pif`), 5 periodic (ack by write to 0x60C000), 6 DUART.
  VBLANK is not an IRQ; it is IN0 bit 2.

### Inputs/outputs
- IN0 (0x60C000 compact) = (SW1<<8)|IN0: bit0 DIAGN jumper, 1 HBLANK, 2
  VBLANK, 3 EOC12 (forced 1), 4 EOC8, 5 self-test, 6 COIN2, 7 COIN1.
- Compact 0xA80000 (`hdc68k_port1_r`): bit0 Abort, 1 Key, 2 aux coin,
  8-11 gear 1-4 buttons (falling edge toggles between that gear and
  neutral in MAME's model; real hardware: maintained switches), bit 14 wheel
  centre-edge latch. 8-bit ADC: 0 gas, 1 clutch, 6 force brake (0x20-0xF0
  reversed; rest 0xF0). Wheel via 0x400000: `(wheel<<8)|0xFF`, low 8 bits of
  the 12-bit value; edge latch set when `last/0xF00 != new/0xF00`; write to
  0x408000 clears it.
- Cockpit: 0xA80000 bits 0-2 only; 8-bit ADC 0 gas, 1 clutch, 2 seat, 3
  shifter Y, 4 shifter X, 5 wheel 8-bit, 6 line volts; 12-bit ADC 0 wheel
  (0x010-0xFF0), 1 brake.
- ADC control (0xB80000 W): bits 0-2 8-bit mux, 3 start, 6 latch 12-bit
  channel in bits 4-5, 7 selects which byte of the 12-bit result is read.
- **Force feedback: the only motor-related output is `hd68k_wr2_write`
  (0xB00000 W): `m_wheel = data>>8`, exposed as output "wheel" (Steering
  Wheel Latch).** 8-bit motor command. The user's racedrivcs input ports
  patch models the compact with cockpit-style ADC 2-5.
- Coin counters: wr0 functions 6/7. Lamps: nwr 2/3.

### DUART
- MC68681 @ 3.6864 MHz at 0xFF0000 upper byte; IRQ 6. Upstream wires only
  channel A to an rs232 slot. Baud rate is programmed by the game (38400
  8N1 observed on hardware). The user's `serial-b.patch` adds channel B.

### DSK board internals
- DSP32C address map (`dsk_dsp32_map` :759): 0x000000-0x001FFF RAM (8 KB),
  0x600000-0x63FFFF RAM (256 KB, "dsp32_ram"), 0xFFF800-0xFFFFFF RAM (2 KB).
  Byte-addressed, 32-bit little-endian data.
- 68010 reaches DSP32 memory **only through the PIO** (PAR/PARE/PDR/PDR2/
  PIR/PCR/EMR/ESR/PCW/PIOP registers; PAR/PDR accesses do DMA with
  autoincrement 2 or 4 per PCR_DMA32). PCR bit 0 (RESET) also holds the
  DSP32; a 0->1 transition resets it. Three hold mechanisms: reset line,
  halt line (DSPZN), PCR bit 0.
- MAME sync hooks at DSP32 addresses 0x613C00 and 0x613E00 (deferred
  writes) — these are the main<->DSK mailbox regions.
- No direct DSK<->ADSP path; everything goes through the 68010.
- DSK "(SLAPSTICK?)" DIP20 socket exists on the PCB (137412-115 listed for
  the DSK board) but MAME does not instantiate it; the user's build guides
  call the DSK 30F/10F + 15A sockets an abandoned protection scheme.

### ASIC65 (`asic65.cpp`), STANDARD mode as used by Race Drivin'
- Interface: 0x914000 even word = parameter push (up to 32), odd word =
  command (resets indices); 0x914xxx read = result; 0x918000 io_r = 0x4000.
  Reset via DSK control bit 4 (going into reset sets command=-1; leaving
  reset replays the latched command).
- Commands: 01 REFLECT, 02 CHECKSUM (0x0027), 03 VERSION (0x0013), 04
  RAMTEST (0), 07 RESET, 0E TMATRIXMULT, 10 MATRIXMULT (3x3 s16 matrix x
  three s32 vectors, results >>14 as hi,lo words), 14 SIN, 15 COS
  (16384*sin(pi*p/32768)), 16 YORIGIN, 17 TRANSFORM (perspective; result
  depends on param count: 2 -> (p0*p1)>>8-1 clamp; 3 -> (p0*p2)>>15+0xA8;
  4 -> yorigin-3*((p0*p3)>>10)). yorigin default 0x1800.
- Trace comment (:652-688) shows the game also issuing 08-0D, 0F, 11-13,
  18-24 which MAME treats as unknown — **MAME's simulation is admittedly
  incomplete; the FPGA port must replicate MAME's behaviour (the oracle),
  including the unknowns returning whatever MAME returns.**
- ROMBASED mode (other games) runs a TMS320C10 @ 20 MHz with a 4K-word ROM;
  Race Drivin's 136077-1027.30j is NO_DUMP in every set.

### ROM regions (racedrivc)
- `maincpu` 0x100000: 16 x 64 KB LOAD16_BYTE pairs (full 1 MB populated;
  harddrivc has only 8 ROMs).
- `asic65cpu` 0x2000 NO_DUMP. `soundcpu` 0x20000 (1032.70n/1033.45n).
- `user1` (ADSP object ROMs) 0x60000, 4 x 64 KB used (1021/1023/1022/1024).
- `user3` (DSK) 0x50000: 1030.30e even / 1031.10e odd, 64 KB each (128 KB);
  RAM at +0x40000.
- `serialroms` 0x50000: 5 x 64 KB (5th = 1017.45c; harddrivc has 4).
- `200e`, `210e` 0x800 each.
- Cockpit `racedriv`: same layout, DSK 4030/4031, ADSP 2021/2023/1022/1024.

### Video (harddriv_v.cpp)
- Compact: VRAM 0xFF800000-0xFFBFFFFF mirror 0x400000 (512 KB), 2bpp
  expander at 0x02000000-0x020FFFFF, `scanline_multisync` (rowaddr<<10,
  coladdr<<3 - 7 + finescroll&7), `m_gsp_multisync` halves shift-register
  copy and changes mask table. 12 MHz, 646x308 total, 512x288 visible.
- Palette 1024 entries in 4 banks; lo word = R(hi byte),G(lo byte); hi = B.
- Nothing Race Drivin'-specific in harddriv_v.cpp.

### Sound board (harddriv_a.cpp)
- 68000 @ 8 MHz, TMS320C10 @ 20 MHz (clock/4), AM6012 DAC, `(data>>4)^0x800`.
- Identical device for HD and RD; only ROM contents and the 5th serial ROM
  differ. BIO pacing 250 cycles.

### CPU cores in MAME
- **DSP32C** (`devices/cpu/dsp32/`): ~4.8k lines. One 24-bit byte-addressed
  space, 32-bit LE data. CAU r0-r22 (24-bit), PC, pin/pout/ivtp; DAU a0-a3
  (as doubles) + DAUC; PIO regs; SIO regs. 4 clocks/instr (10 MIPS @ 40 MHz),
  one branch delay slot, 4-entry deferred write buffer, multiplier sees
  accumulators 2 instructions late, DAU flags 3 late. **Header says "rather
  incomplete", implemented just far enough for Race Drivin' and Airborne;
  46 `unimplemented()` fatalerror sites** (interrupts, do loops, carry-
  reverse adds, DAU `*r` variants, ic/oc/ieee/dsp, serial I/O, some branch
  conditions, conditional load/store). So the subset Race Drivin' executes
  is bounded and knowable: everything MAME implements is the upper bound.
- **ADSP-2100** (`devices/cpu/adsp2100/`): ~4.7k lines, 1 instr/cycle.
- **TMS320C1x**: C10 144 words RAM, C15 256 words; 12-bit program address.

## 4. Instruction-set usage of the Race Drivin' DSP programs (from the user's listings)

Measured from the disassembly text in `~/Developer/rdp-fullscreen`
(`dsp32_hi.dasm`, `dsp32_lo.dasm`, `adsp_program.dasm`). No ROM bytes copied.

### DSP32C program (compact rev 5 image uploaded by the 68010)
- ~22,000 non-NOP instruction words. 11 words the MAME disassembler cannot
  decode ("Unexpected", e.g. 1A000088, 1B6A39D1), probably data.
- Class histogram: 5,951 conditional branches; 3,503 CAU ALU reg,reg; 2,919
  CAU load-immediate; 2,005 goto/call/return; 1,824 DAU ops with a memory
  operand; 1,573 DAU stores; 1,589 CAU loads; 1,038 CAU stores; 327 CAU
  shift/mul2/div2; 283 register-only DAU ops; 76 special-register writes
  (obuf, ioc, dauc, pcw...); 4 DAU special (float/int/round forms beyond the
  common ones); **no `do` loops observed**, which matches MAME leaving them
  unimplemented.
- DAU forms used heavily: `aN = *p * *q`, `aN = (*p * aN)`, `aN = aN * *p`,
  `aN = float24(*p)`, `aN = ifalt(*p)`, `aN = -*p`, `aN = aM + aK`,
  `aN = aM - (*p * *q)`, `aN = float(*p)`, `aN = a3 = *p + a1 * *q`, and
  the postincrement pointer forms (`*r14++`, `*r1++r19`, etc.).
- **Consequence: the DSP32C core needs the CAU (24-bit integer), the DAU
  floating-point multiply-add path with DSP32C float format (8-bit
  exponent, 24-bit two's-complement mantissa) plus float/float24/int/ifalt
  conversions, the PIO (host DMA), and no serial I/O, no interrupts, no `do`
  loops.** MAME's implemented subset is the upper bound and it models the DAU
  in `double`, so MAME is not bit-exact to silicon either; the oracle is
  behavioural, not bit-exact.

### ADSP-2100 program (runtime dump of program RAM)
- 421 `DO ... UNTIL` loop instructions; conditions used: EQ (619), LT, NOT,
  NE, GT, GE, LE, AC. Vectors 0-3 are bare `RTI` (interrupts effectively
  unused). `IF EQ TOGGLE FL1` present.
- **Mode-control instructions present: `ENA/DIS AR_SAT`, `ENA/DIS M_MODE`,
  `ENA/DIS TIMER`, `DIS AV_LATCH`.** The HD core's ADSP-2100 does **not**
  implement MSTAT mode control. AR_SAT (ALU saturation) and M_MODE
  (integer vs fractional multiply) change arithmetic results, so the ADSP
  core must gain MSTAT handling for Race Drivin' (or be shown unnecessary by
  tracing in MAME whether those paths execute). No `SEC_REG`, no bit-reverse.

## 5. External research (web, 2026-10-24)

### Open HDL cores
- **DSP32C / DSP32: no HDL implementation exists.** Only MAME `dsp32.cpp`
  (BSD-3, Aaron Giles; "sufficiently complete to run Race Drivin' and
  Airborne"), the C assembler LegalizeAdulthood/asm32, and pappadf's
  DSP3210 SDK/Sail spec (MIT; successor ISA, methodology reference).
- TMS320C1x: ika-musume/IKA32010 (BSD-2, FPGA-proven, ~600 ALMs; used by the
  HD core), srg320/TMS320C1X (no licence), birdybro/TMS32010_sv (MIT, WIP).
- ADSP-2100: birdybro/adsp-2100_sv (MIT, WIP, "not instruction-complete");
  the HD core's own clean-room core (GPL-3). nikeemda/ADSP2100 unusable.
- birdybro also has TMS34010_sv (MIT; the HD core vendors it).
- No other FPGA Hard/Race Drivin' effort found.

### DSP32C documentation
- bitsavers: DS94-084 DSP32C datasheet (Nov 1996), DSP32C AT/PC User's
  Guide (Symmetric Research 1992), AP88-08 DTMF app note with DSP32 code.
  **The WE DSP32C Information Manual is not online.** Jed Margolin hosts
  the DSK board schematic (`dsk600.pdf`), main board, ADSP board, sound
  board, motor amp (`mamp600.pdf`), link cable schematic, TM-327/TM-329
  manuals: https://jmargolin.com/schem/schems.htm

### Quartus on Apple Silicon
- No native Quartus. Options: Docker Desktop + Rosetta with `raetro/quartus`
  images (17.0 = `:mister`, up to 23.1; ~6 GB; no end-to-end M-series report
  found, expect several-x slowdown); ARM Linux VM + QEMU user-mode x86
  ("fragile", ~4x slower, give the VM one core); remote x86 Linux box or
  GitHub Actions (raetro workflow; hosted runners' 7 GB RAM is tight for a
  110K-LE design; self-hosted runner safer). **Rosetta is not installed on
  this Mac.**
- MiSTer standard is Quartus 17.0.x; 17.0 Lite has vanished from Intel's
  download pages (Docker images bake it in). The HD core builds on **Quartus
  Lite 24.1** with stock Main, proving the current framework works there.

### MiSTer I/O facts
- User port: 7 open-drain 3.3 V LVTTL lines (`USER_IO[6:0]`, weak pull-up),
  USB-3-shaped socket: pin 1 +5 V, pin 4 GND, D-/D+ = USER_IO[1]/[0]
  (TX/RX convention), SS pins = USER_IO[2..5], pin 7 = USER_IO[6] via the
  IO6 jumper on I/O board >= 6.1. Bits 2/4/5 double as HDMI I2S when SW[1].
- Pin ownership with SDRAM + analog I/O board: GPIO_0 + Arduino IO0-2 =
  SDRAM; GPIO_1 + Arduino IO3-15 = I/O board. **Only the 7 user-port lines
  are free.** The Digital I/O board leaves all 36 GPIO_1 pins free.
- On-board LTC2308 (8-ch 12-bit, 500 ksps) is FPGA-driven via `ADC_BUS`;
  inputs on the Arduino analog header (0-4.096 V); the analog I/O board
  uses it for audio-in. `sys/ltc2308.sv` exists in the HD core's sys/.
- Two serial paths: (1) `UART_*` emu ports -> HPS UART1 = Linux
  `/dev/ttyS1`, re-targeted by `uartmode` (PPP/console/MIDI/MidiLink TCP/UDP/
  USB serial); core gets `uart_mode`/`uart_speed`. (2) `USER_IN/OUT` raw.
  ao486 puts COM2 on the user port: `USER_OUT = {1,1,dtr,1,rts,tx,1}`,
  `rx = USER_IN[0]`.
- USB HID: `joystick_l/r_analog_N` 8-bit signed per axis (4 axes/player),
  `paddle_N[7:0]`, `spinner_N[8:0]`; wheels (G25/G27/G29, Fanatec,
  Thrustmaster) get QUIRK_WHEEL scaling. **Output: only
  `joystick_N_rumble[15:0]` (rumble) and Main-side FF_AUTOCENTER/FF_SPRING
  at startup. No game-driven constant-force path exists.** No prior art for
  a motorised/FF wheel on MiSTer.
- Spinner/paddle only arrive via USB (mr.Spinner "MiSTer-S1"/"MiSTer-A1",
  mice); no spinner-over-SNAC protocol.

### Force-feedback motor amp (cockpit, Atari 044253-01 "Motor Amp PCB")
- Game side: 8-bit force word written at 0xB00000 (`hd68k_wr2_write`);
  the cockpit cross-checks the 12-bit wheel ADC against the 8-bit copy on
  ADC0809 ch5 and disables FF if they disagree (Margolin).
- Amp: J6 D0-D7 + 5 V/GND from the game board; LS244 buffer -> six TIL115
  optos -> two 74HC174 "FORCE LATCH" -> DAC-08 -> uA741 -> TL595 PWM ->
  IRF9640/IRF630 half-bridges from an off-line rectified mains bus
  (~160 VDC, not isolated). Exact latch/strobe protocol across the 6-opto
  barrier **not fully traced** (read `mamp600.pdf` sheet 1).
- Modern substitutes: Happ/Suzo-Happ 50-2000-05 active-wheel driver (24 V,
  opto inputs: 4 torque bits + direction), or MCU + H-bridge (BTS7960,
  Cytron MD, VESC) as in DIY FFB wheels.
- **The compact's motor amp and wheel/pedal wiring are undocumented in our
  sources; measure on the cabinet.**

## 6. The user's hardware (stated 2026-10-24)

- Cabinets: **four Race Drivin' cockpit cabinets and one compact.** Both
  cabinet types are deployment targets for the core and the cabinet board.
- Bench video: an EGA-to-VGA converter board with a VGA monitor for the
  cockpit (about 25 kHz), and a CGA LCD for the compact (about 18.6 kHz). So
  both boards' native output from the analog I/O board can be viewed on the
  bench without HDMI.
- Local ROM sets: cockpit `racedriv` rev 5 (136077-5001..5006 plus the
  Y2K 200r variant) and a slapstic-free cockpit set; compact rev 5 referenced
  by the tools.

## 7. DSP32C dynamic measurement in MAME (2026-10-24)

Method: `mame/dsp32-measure.patch` on MAME 0.289, `hd` subtarget, 240
emulated seconds of attract mode (demo driving) per set, headless. Cockpit
`racedriv` rev 5 with the user's calibrated NVRAM; compact `racedrivc` from
the Stock Car folder (patched R/S pairs and track; same DSP32C program).
Full reports in `docs/measurements/`. Both sets give the same profile.

### Throughput
- The DSP32C never halts after boot: 2.36 G instructions in 238 s, average
  9.9 M instr/s, peak 10.0 M (MAME charges 4 clocks per instruction at 40 MHz).
- **Almost all of it is an idle loop.** 29.4% `nop`, and the top handlers
  are the polling loop: `adde_si` 415 M, `load_er` 276 M, `load24` 140 M,
  `store_er` 138 M, `load_r` 138 M, `adde_ss` 138 M, `cmpe_di` 138 M,
  `goto_eq` 138 M, `goto_lt` 138 M. It spins reading the mailbox page at
  0x613C00 (138 M reads) and the 2 KiB RAM at 0xFFF800 (277 M reads, 139 M
  writes).
- **Real work is small: about 3.9 M DAU operations in 238 s, roughly
  16,000 per second.** `d3_aMpp` 1.16 M, `d1_0px` 0.79 M, `d1_1pp` 0.25 M,
  `d1_1pm` 0.22 M, `d1_0mx` 0.17 M, `d3_aMpm` 0.12 M, `d2_aMpp` 0.10 M,
  `d5_float` 0.28 M, `d5_ifalt` 0.15 M, `d5_float24` 0.12 M, `d5_int24`
  0.09 M, `d5_int` 0.09 M, `d5_seed` 0.04 M, `d5_round` 0.04 M.
- 63 distinct MAME handlers executed in total (full list in the reports).
  No `do` loops, no `d4` forms, no `*r` store variants of DAU forms 1-3, no
  `ic/oc/ieee/dsp`, no interrupt or serial branch conditions.
- **Consequence for the FPGA core:** correctness of the CAU/DAU subset
  matters far more than raw speed. A core that executes an instruction every
  4-5 clocks at 48 MHz matches the original; even a several-times slower
  core would keep up with the physics work, it would merely poll less often.
  Mailbox response latency (command posted by the 68010 to result available)
  is the real constraint and can be measured from the PIO timestamps.

### Memory footprint
- 8 KiB RAM at 0: fully used. 2 KiB RAM at 0xFFF800: fully used (stack and
  loop variables).
- 256 KiB RAM at 0x600000: **every page is written once (boot-time clear)
  but reads occur only in 0x600000-0x6003FF, 0x611400-0x612BFF,
  0x613C00-0x61ABFF and 0x61F400-0x61FFFF.** Nothing above 0x61FFFF is ever
  read. So a 128 KiB RAM (0x600000-0x61FFFF) with writes above it ignored is
  functionally sufficient for rev 5, and it fits in the block RAM the MSP
  vacates. (Instruction fetches are not counted here; the program lives in
  the same region, uploaded over the PIO.)
- Hot pages: 0x613C00 (mailbox: 138 M reads, 0.85 M writes), 0x612800,
  0x611C00, 0x611400, 0x619800, 0x611800.
- Stray accesses to 0x005400, 0x009800, 0x009C00 (unmapped in MAME, read as
  0): probably a boot-time memory probe; the FPGA should return 0 there too.

### PIO usage (raw 68010 word offsets into the 0x85C000 window)
- Writes: reg 2 (980 k, the data register used for program and segment-table
  upload and mailbox writes), reg 0 (400 k), reg 11 (398 k), reg 7 (7, the
  PCR: first write 0x1A1A, later 0x1F1F), reg 10 (5).
- Reads: reg 7 (792 k, PCR/flag polling), reg 0, 8, 11 (197 k each), reg 2
  (28 k).
- PCR reset bit toggles 4 times at boot (two short pulses), then stays set.
  The 68010 touches the DSK at t = 1.6 s (cockpit) / 1.3 s (compact) after
  reset, matching the boot-order notes.
- So the PIO model needs: PAR/PARE address registers with DMA autoincrement,
  PDR data register, PCR, PIR and EMR, in the register mode the game selects
  via PCR bits 1 and 9. No serial I/O.
