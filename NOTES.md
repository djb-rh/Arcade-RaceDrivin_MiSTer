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

## 8. Whole-core simulation findings (2026-10-25)

Cockpit set `racedriv` (stock, slapstic present) in the Verilator harness
with the GHDL-converted TG68K, compared write-for-write with MAME
(`mame/oracle.lua`, `RD_BUSWRITES=1`, `tools/tracediff.py`).

- **The Race Drivin' program writes the GSP host port while /GSPRES is still
  asserted.** The power-up DSK probe (0xD60-0xE52) reads 0x920000,
  0x920040/44/48/4C and compares seven words at 0x920002 with a table at
  0xD1A; nothing answers there in MAME either (open bus), so the compare
  fails, a BCD digit at 0xFF4FED is bumped and the code writes the result
  through HSTADR/HSTDATA (`c00002 00ff / c00004 9010 / c0000c 1234`) before
  releasing the GSP at 0x60401C. The imported core held the whole GSP,
  including its host interface, in a level reset and never acknowledged the
  cycle: the 68010 hung at its 27th write, 90 us after reset. MAME resets the
  chip at assertion, suspends the CPU while the line is held and keeps
  `host_w` live. The core now does the same: a 64-clock chip reset pulse at
  /GSPRES assertion (and power-up) and the held level routed into the
  processor's HLT path (`reset_hold_i` on tms34010_core/system/probe).
- **Race Drivin' has no MSP** (MAME `driver_nomsp`). At 0.39 s (sim) the
  program read-modify-writes the MSP's HSTCTL at 0xC04008: MAME reads
  0xFFFF and writes 0xFFFF back; the HD core answered from its MSP. New
  `MSP` parameter on `harddrivin_milestone` (default 1); with 0 the MSP, its
  memory, host CDC and release sync are not generated, host reads return
  0xFFFF and writes vanish. This also frees the MSP's block RAM and logic for
  the DSK board.
- **Write order inside a long**: TG68K writes the high word first, MAME's
  68000 core the low word first (MOVEM -(SP), PEA). Same memory image;
  `tracediff.py` tolerates and counts the swaps.
- **Result: the write sequence matches MAME from reset to the first DSK
  access.** 884,235 identical writes; the sim reaches that point at 1.374 s,
  MAME at 1.434 s. The deciding reads are DSK RAM at 0x905950/52/54/55 and
  0x90597A/7C (sim: open bus 0xFFFF; MAME: RAM), after which MAME starts the
  DSK initialisation (control latch 0x85C808, ASIC65 command 7 at 0x914002,
  DSK RAM writes at 0x900000+, GSP reset toggled again at 1.438 s, DUART
  programmed at 1.59 s) while the core skips to the next test routine. The
  pointer at 0xFFFF5E/60 walks the boot-test routine table (0x3B276 ->
  0x3B296 -> ...). This is M1's end point; M2 starts with DSK RAM.
- MAME timeline (cockpit, fresh NVRAM, no inputs): GSP released at 0.85 ms;
  second GSP download batch at 0.517 s; MSP latch toggled 0.526 s; first
  ASIC65 command 1.438 s; DUART init 1.590 s; input scanning (SEL latch
  polls every 4 ms) and wheel-force writes from 1.98 s.
- **68010 pacing**: with the imported 1-in-16 clock enable the GSP download
  loop (`move.w (A0)+,$C0000C; dbra`) runs 1.32x faster than MAME's 8 MHz
  68010 (231,958 writes at 0.391 s vs 0.517 s). The HD author tuned the
  divider for the Hard Drivin' boot timeline; revisit once the whole boot is
  visible (the game's bounded GSP waits scale with it).
- Reset vector of the cockpit set: SSP 0xFFFFC000, PC 0x21C, matching the
  HD core's boot check.
- MAME 0.289 Lua: `emu.register_stop` is gone; taps/logs must be reachable
  from globals or they are collected and the next tapped write segfaults
  MAME; `machine.time` inside a tap also crashed. See docs/simulation.md.

## 9. DSK board in simulation (M2, 2026-10-25)

Added to the core: `rtl/dsk/harddrivin_dsk_board.sv` (64 KiB DSK RAM, the
2816-pair zero-power RAM, control latch, ASIC65 hookup, DSP32C PIO
placeholder) and `rtl/asic65/asic65_sim.sv` (MAME's command-level ASIC65,
STANDARD map). The 256 KiB track-ROM window 0x940000-0x9FFFFF is served by
the main bus from DDR (byte offset 0x1A0000, MRA index 0), repeating every
0x20000 words like MAME's `hd68k_dsk_small_rom_r`.

- **Result: the write sequence matches MAME from reset to the slapstic.**
  930,458 identical writes (was 884,235), sim 1.494 s, MAME 1.585 s. In the
  newly covered span the program read DSK RAM 608 times, DSK ZRAM 29, the
  track ROM window 1,028, ASIC65 data 61, ASIC65 status 40, the PIO window
  3 — all answered as MAME answers them.
- **The divergence is the slapstic.** At MAME 1.585 s the program copies
  bytes from 0x0E0000-0x0E004F into DSK RAM 0x900F34 one at a time; MAME's
  137412 had switched the window to bank 1 (its data 0x32/0x3C/0x37 at
  +0/+4/+6 is bank 1 of the 200Y/210Y pair), the core reads bank 0. This is
  the boundary PLAN.md section 2.3 expected for the stock set: the user's
  cabinets run slapstic-free ROMs (`slapfree.py`), so the sim's next step is
  either the slapstic-free set on both sides (MAME would need a variant
  without the slapstic device) or an HDL 137412 (MAME `slapstic.cpp` has
  the whole state machine; it would also let stock ROM sets boot).
- **ASIC65 arithmetic verified against MAME**: `tools/sim.py asic65-test
  <run>.asic65.log` replays the logged command/parameter stream through
  `asic65_sim` and checks every result the 68010 read. The 20 s cockpit
  capture (1 RESET, 13 MATRIXMULT, 36 SIN, 36 COS; 151 results) matches
  bit for bit. SIN/COS use a 16384-entry quarter-wave table
  (`rtl/asic65/asic65_sin.hex`, generated and self-checked for all 65536
  arguments by `tools/asic65_sintab.py`); MAME truncates toward zero, so
  the negative half is the negated table and COS(p) = SIN(16384 - p). A
  result read takes three clocks (operand select, 32x16 multiplies, sum
  >> 14). TMATRIXMULT, TRANSFORM, YORIGIN and REFLECT are implemented from
  MAME's code but not yet exercised by a log (the boot sequence does not
  reach them before the slapstic).
- **ASIC65 reset semantics** (MAME `reset_line`): asserting reset (latch
  function 4 written with 0) forgets the command; releasing it re-issues the
  command written while held (indices cleared). Writes to the parameter and
  command ports are accepted while held. The game only toggles it at
  power-up and once at 1.434 s.
- **DSK zero-power RAM**: MAME's two 2816 devices start all-0xFF with no
  NVRAM file (and the capture was made with a fresh NVRAM directory), so the
  lane RAM has `INIT_ONES`. MAME ignores ZW1/ZW2 for this RAM; so does the
  core. Saving it to the MiSTer NVRAM file is still to do (the main board's
  200E/210E save already exists as index 2).
- **DSK RAM** starts zeroed in MAME (it is the tail of the `user3` ROM
  region) and in the core. The track ROM region's unused upper 128 KiB
  reads 0x00 in MAME and 0xFF from romimage.py's fill; the program has not
  touched it.
- **DSP32C timeline for M3** (MAME, cockpit): the DSP32C runs from power-up
  until the program asserts DSPRESTN at 36 us (MAME's device is not reset
  by the latch's power-up state), is released at 1.600 s and immediately
  tested through the PIO: PCR writes, PAR = 0x5432 then a PDR write, PAR
  read back expecting 0x5433 (`m_par | 1`), the same with 0x9876, then the
  upload begins (PIO reg 2 writes from 1.60027 s). The DSK board module
  answers PIO reads with 0 until M3.
- **Pacing**: the sim reaches the slapstic point 5.7% earlier than MAME
  (1.494 s vs 1.585 s) against 4.2% at the first DSK access; the DSK
  accesses themselves take two to five 48 MHz clocks.

### Slapstic 137412-117 in the core (same day)

`rtl/slapstic/harddrivin_slapstic.sv` follows MAME's `slapstic.cpp` for
the 111-118 class (chip parameters as module parameters, 117 defaults). The
main bus feeds it every CPU bus cycle it dispatches (fetch, read, write)
and maps 0x0E0000-0x0FFFFF to `{bank, A14:A1}` of the 200Y/210Y pair; the
access that switches the bank still reads the old bank, as MAME's tap does.
`SLAPSTIC=0` on `harddrivin_main_bus` gives the flat window the
slapstic-free sets need.

- **Result: the write sequence matches MAME from reset to the DSP32C PIO
  test**, 930,594 writes, sim 1.4941 s, MAME 1.5846 s. The divergence is
  now the program's test of the DSP32C parallel port: PCR (0x85C00E) =
  0x1A1A, 0x85C014 = 0x0202, 0x85C016 = 0, PAR (0x85C000) = 0x5432,
  0x85C016 = 0 again, then PAR read back expecting 0x5433 (MAME returns
  `m_par | 1`); the placeholder answers 0 and the program repeats the
  write sequence forever. This is M2's end point and M3's start. The PIO
  register index is A4:A1 (0x85C000 + 2 x reg).
- What the game does with the slapstic in the first 4 s (MAME `-log`,
  `tools/slapstic_trace.py` on the sim trace agrees event for event):
  only direct switches. An arming read of 0x0E0000, then a read of
  0x0E0010/0x0E0034/0x0E0058/0x0E007C selects bank 0/1/2/3. The boot test
  at PC 0x27D88-0x27DA4 cycles banks 0,0,...,1,1,2,2,3,3 and the byte-copy
  loop that first diverged runs with bank 1. Instruction fetches at
  addresses ending in 0xFA (e.g. 0x027EFA) match the "alt start" pattern
  (A7:A1 = 0x7D, anywhere in the map) and the next fetch breaks the
  sequence; harmless, and MAME logs the same. No alternate or additive
  commit occurs before 4 s.
- MAME quirk kept: in the additive sequence the +1 pattern (mask 0x3E62,
  value 0x1A42) also matches the exact end address 0x1A42, and MAME tests
  +1 first, so an access to 0x1A42 adds 1 instead of ending the sequence.

## 10. DSP32C core (M3, 2026-10-25)

`rtl/dsp32c/` is a DSP32C written to match MAME's model exactly; the
design and every MAME-equivalence decision are in docs/dsp32c.md. Verified
by lock-step against MAME instruction traces (`mame/dsp32-measure.patch`
`RD_DSP32TRACE`, `tools/sim.py dsp32-test`).

- **Results.** Window 1, the first 3,000,000 instructions (upload, boot and
  0.3 s of execution; 526,181 memory writes, 17,091 host PIO reads): zero
  differences. Window 2, 2,000,000 instructions from instruction 10,000,000
  inside the DAU-heavy initialisation (172k form-1/4, 11k form-2, 142k
  form-3 and 88k form-5 DAU ops; 222,840 writes, 1,690 PIO reads): zero
  differences. Every CAU register, accumulator (as double bits), both flag
  words, the DAU flags, the PIO registers and the memory write list are
  compared after every instruction.
- **MAME's multiply-add is fused.** clang contracts `yval + a * xval` into
  one `fmadd` by default (checked with a discriminating test on this Mac;
  MAME's build sets no `-ffp-contract`), and the lock-step run with half a
  million DAU operations confirms it. A separately rounded multiply then
  add would not have matched.
- **Bugs the first runs caught, all in flag and sequencing details**: the
  overflow word's `r >> 1` is an arithmetic shift in C (SystemVerilog's
  `>>>` on an unsigned vector is not); conditional execution applies only
  to register-form CAU ops (the immediate forms carry imm16 where the
  condition would be); a branch's target is applied after its delay slot
  has retired, not after the branch itself; MAME's `goto ge/lt` test N^V
  where its `condition()` codes 10/11 test N^C.
- **What the DSP does when.** In 150 s of attract mode with the calibrated
  NVRAM, all 3.72 M DAU instructions execute between 4.16 s (PCR run bit
  set after the upload) and about 6 s; afterwards the chip only polls its
  mailbox (loop at 0x6054C4). So the "16,000 DAU ops per second" of section
  7 is an average dominated by that burst; the real-time physics DAU work
  happens during play only. `mame/play.lua` (an `-autoboot_script`) drives
  a game: coin at 9 s, Key to start, Key through the track and transmission
  screens, then first gear, full throttle and a steering weave from 17 s.
  Driving, the DSP executes about 2.08 M DAU instructions per second, a
  fifth of its instruction stream. **Window 3, 2,000,000 instructions from
  instruction 250,000,000 (30 s, driving; 182k form-1/4, 11k form-2, 138k
  form-3, 85k form-5 DAU ops; 223,557 writes, 1,854 PIO reads): zero
  differences.** That is the real-time physics path covered.
- **Trace mechanics.** Records are emitted at the top of `execute_one`, so
  a record holds the previous instruction's effects, the host PIO accesses
  since, and the deferred DAU write processed at the start of this one;
  host events are stamped with the instruction count and replayed between
  instructions. A window starts only at a clean point (not in a delay slot,
  no deferred write pending, no accumulator inside the latency windows) and
  the first record carries the full state plus a memory image, so the core
  can be initialised mid-stream. `RD_DSP32TRACE_DAU=1` waits for the first
  DAU instruction.
- **Speed.** 10-16 clocks per instruction at 48 MHz, so 3-5 MIPS against
  the original's 10. The whole-core comparison still holds: with the DSP32C
  in the DSK board the 68010 write sequence matches MAME through the PIO
  test and the program upload, and the next divergence is not the DSP at
  all: at write 1,068,142 (sim 1.770 s, MAME 1.968 s) the program stores
  its first analogue input sample into DSK RAM (0x900006: MAME 0xFF from
  its default port values, the sim 0x80 from tb_core's default pot
  values). From here the comparison depends on the cabinet inputs, which
  is M4's territory; the DSK board and DSP32C are no longer the limit.
- **In the DSK board.** DSPRESTN and DSPZN from the latch drive the core's
  reset and halt inputs, the PIO window 0x85C000 is the host port (register
  = A4:A1), PIF is the 68010's interrupt level 4 (MAME `hddsk_update_pif`),
  and the RAM at 0x600000 is 128 KiB on the FPGA (`DSP32_RAM_LOG2 = 17`,
  the game never reads above 0x61FFFF) and 256 KiB in the sim to match MAME.

### M2 leftovers (2026-10-25, later)

- **MC68681** (`rtl/duart/mc68681.sv`) replaces the counter-only stand-in:
  both channels with MAME's semantics (3-deep RX FIFO plus holding slot,
  MR pointer, both baud tables, TxRDY one bit time after the start bit and
  TxEMT at the last stop bit, a THR write while TxRDY is clear is dropped,
  local loopback, break in loopback, parity/framing), ISR/IMR with the IRQ
  on the 68010's level 6, counter/timer with the start/stop command reads,
  input port with change detection (IP6 high as on MAME's board), output
  port. Verified by `mame/duart_test.lua`, which exercises the chip through
  the 68010's address space at frame spacing (loopback bytes, FIFO drain,
  break, parity on B, counter and timer, output port, TX reset) and logs
  every read; `tools/sim.py duart-test <log>` replays it against the RTL:
  47 reads, all equal (counter values within three ticks). The game itself
  only initialises the DUART (1.59 s: 8N1, 38400, RX interrupts enabled on
  both channels) and never reads it in 20 s of attract, so link traffic is
  the first real use (M5).
- **8-bit ADC**: MAME's `adc0808` powers up with 0xff in its result register
  and only updates it on a conversion (control bit 3 rising; EOC low for 64
  of its 1 MHz clocks). The core returned the live input, which is where
  the 68010 comparison first diverged (the program stores an ADC sample
  before starting any conversion). `harddrivin_main_bus` now has the same
  SAR/EOC model, and EOC drives IN0 bit 4.
- **DSK zero-power RAM in the save file**: the .nvm file grows to 8 KiB
  (MRA `<nvram index="2" size="8192"/>`, bytes 0x0000-0x0fff the main
  board's 200E/210E lanes, 0x1000-0x1fff the DSK's 10C/30C); the bridge and
  the board top carry 13-bit addresses and the DSK board has the same side
  port as the main bus. `tb_core +nvramtest` writes and reads both halves
  through the side port while the board is in reset: passes. Existing
  4 KiB .nvm files are read as the first half (the DSK half then powers up
  0xff, as a fresh chip would).
- **Self-test menu**: MAME samples the self-test switch once the boot
  tests are done (5.2375 s with the switch held from the first frame; the
  service-mode and normal runs are identical until then), and the sim does
  the same at the same program point (its own normal and service runs part
  at the same write, `fffeb8 6f4e` against `6f7a`, followed by the same DSK
  RAM and stack writes) at sim 3.760 s. From the two entry points the
  write streams agree, interrupt phase aside, through the menu's first
  screen. The test needs no navigation ("HOLD KEY TO BYPASS SELFTEST"):
  MAME's screenshots (`mach.video:snapshot()` works with `-video none`)
  show PROGRAM ROM OK at 12 s, PROGRAM RAM OK by 30 s, a white screen at
  38-50 s, **BAD GSP VRAM** (MAME's own GSP fails it) and GSP COLOR RAM OK
  by 70 s, then "DSK BOARD - 2 MINS XROM XRAM" from 90 s, "DSK BOARD OK
  XROM XRAM ASIC.61 ASIC.65" at about 150 s, then "ADSP TEST: 3 MINS". At
  5.5 ms of machine time per wall second the DSK items are seven hours of
  simulation, so the checksum run waits for hardware (or a long run on the
  Linux box); each block under that test is verified against MAME on its
  own instead (ROM window from the same DDR image, ASIC65 and DSP32C
  lock-step, DSK RAM in the write comparison).
- **Interrupt phase is now the limit of the 68010 comparison.** With the
  ADC model in place the normal run matches to write 1,069,120 (MAME
  1.968 s), where MAME's periodic level-5 interrupt lands on a different
  instruction than the sim's: the handler's stack frame and its 200-odd
  writes appear at a different point in the stream, after which both
  continue identically. `tracediff.py --resync N` skips such inserted
  blocks on either side (reporting each) and the comparison then runs on,
  with one resync every 4 ms, which is the 244 Hz interrupt: the normal run
  then agrees to write 1,336,423 (sim 2.80 s, MAME 3.60 s, 627 resyncs),
  where interrupts nest differently on the two sides, and the self-test run
  through 38,274 writes of the menu (200 ms, 211 resyncs). The sim is
  also ahead of MAME by a growing margin (1.77 s against 1.97 s at that
  point, 3.76 s against 5.24 s at the self-test sample): the 68010 runs
  about 10% fast and the boot's timed waits run short. Cycle-faithful 68010
  pacing (PLAN.md, later) is what would make the plain comparison hold
  through the attract mode.

## 11. M4: cabinet inputs (2026-10-25)

- **One input script for both machines.** `tools/inputscript.py` writes
  "time control value" events (values as the 68010 reads them; continuous
  motions sampled per frame); `mame/inputs.lua` replays them into the
  cockpit set's ports at frame boundaries and `tb_core +inputs=` at the
  exact times. MAME applies a programmatic field value at the next frame
  update, so a port read right after `set_value` still shows the old state
  (the script echoes a frame later). Digital `set_value(1)` is "active"
  whatever the field's polarity; analog `set_value(v)` is the raw value,
  which for the reversed brake pedal means the script's 12-bit ADC value is
  written as `0xfff - v`.
- **Calibrated runs.** `tools/nvram2hex.py` turns a MAME nvram directory
  into the sim's power-up images for the 200E/210E and the DSK 10C/30C
  zero RAMs (`tools/sim.py build --roms <dir>`), so a sim run can start
  from the same calibrated cabinet as a MAME run with `-nvram_directory`.
- **Cabinet I/O board link** (docs/cabinet-io.md): `rtl/io/rd_cabinet_io.sv`
  on `USER_OUT[0]`/`USER_IN[1]` at 2 Mbaud, 26-byte input frames at 1 kHz
  with CRC-8, 16-byte output frames in reply (force byte, lamps, coin
  counters, DSK LED, serial bytes). The DUART's channels stay serial lines:
  frame bytes are re-serialised onto its RX pins at the rate the game
  programmed (the DUART now exports its rates) and its TX pins are received
  at that rate into the output frames. `sim/models/sim_cabinet_io.sv` is
  the ESP32 side for simulation; `tools/sim.py cabio-test` checks inputs,
  CRC rejection, the 50 ms silence fallback, both serial directions through
  a real MC68681, and the outputs: 12 checks pass. The Quartus top gains
  OSD "Inputs: USB / Cabinet board" and falls back to USB while no board is
  sending. The ESP32 firmware and the KiCad board are not in this repo yet.
- **Output latches the core never captured**: 0xA00000 (MAME
  `hd68k_wr0_write`) is a 74LS259 whose functions 6 and 7 are the coin
  counters, 0xB00000 writes latch the force byte in the upper data byte
  (`hd68k_wr2_write`); both are now `harddrivin_main_bus` outputs. The
  lamps are the control latch's LC1/LC2 bits, the DSK LED latch function 7.
- **Zero RAM from the MRA.** The Quartus top no longer bakes the
  200E/210E images in from `generated/` hex files: MRA download index 3
  (both layouts now carry it) goes through the NVRAM bridge into the main
  board's zero RAM before any .nvm, so no ROM data enters the bitstream and
  a saved calibration still wins. The DSK zero RAM powers up as 0xff unless
  a .nvm has it.
- **68010 pacing.** `MAIN_CPU_DIV` (TG68K clock enable, one step every N
  clocks of 48 MHz) is now 18 instead of the Hard Drivin' core's 16. Against
  MAME's 8 MHz 68010 the sim's time at matching writes is then 0.86x in the
  GSP download loop, 0.99x at 0.9 s, 1.05x at 1.25 s, 1.03x at 1.78 s and
  0.99x at 2.1 s (with 16: 0.76x, 0.88x, 0.94x, 0.92x, 0.90x), and the
  exact write match reaches the same interrupt-phase point with the sim 1%
  slow instead of 10% fast (write 1,068,752, sim 1.991 s, MAME 1.968 s).
  TG68K is not cycle-exact, so no single divider matches every instruction
  mix; cycle-faithful pacing would need per-instruction cycle counts.
- **Scripted inputs, both machines.** MAME with `inputs/play.txt` (coin at
  9 s, Key, first gear, full throttle and a steering weave from 17 s, from
  the calibrated NVRAM) against the sim with the same script and
  `tools/nvram2hex.py` images. The write comparison stops where the normal
  run stops (nested interrupts at sim 2.8 s), before the first input event,
  so the check is the game's own input block in DSK RAM (oracle `RD_PHYS`
  words at 0x900D28-0x900D38 against the sim's writes there): at 20 s both
  hold throttle 0x0FCD, brake 0x1000 (released), clutch 0, key 0, and the
  wheel inside the weave's 0x01F0-0x0300 band (the two machines are at
  different phases of the sine); at 8.5 s both hold zeros. So the pedals,
  wheel and switches reach the game through MAME's exact calibration
  arithmetic. This 21 s run was at the old divider (16); the comparison
  itself needs the interrupt-alignment work before it can follow inputs.

## 12. First Quartus builds (2026-10-27)

Build host: Hetzner CPX41, Quartus Lite 24.1 (docs/toolchain.md). The AWS
account stayed "blocked and not recognized as a valid account" for two days
after an expired card was replaced, through two support cases; Hetzner had
a server up in a minute.

- **Quartus's SystemVerilog is narrower than Verilator's.** A bit-select
  on a function call result (`fifo_at(n, i)[15:8]`) is a syntax error.
  Byte-enable RAM inference accepts only the template form with the lane
  writes spelled out (`if (be[0]) ram[a][0] <= wd[0]; ...` on a
  `logic [3:0][7:0] ram[]`): the original lane part-selects and a `for`
  loop over the lanes both synthesised silently into flip-flops (1.1M
  registers, 518K ALUTs, no "uninferred RAM" message). A one-module Quartus
  project on the build host (`quartus_map`, ~10 s to 1 min) shows the RAM
  summary and the ALUT/ALM estimate for a single module; that loop is how
  each reduction below was measured.
- **The board's 256 KiB DSP32C RAM is 128 KiB in the FPGA.** MAME traces:
  at gameplay the lower 128 KiB all hold data (program and tables in the
  first 64 KiB, working data in the second), the upper 128 KiB only ever
  receive the boot-time clear (two passes of 16-bit zero writes, never read
  back). The DSK board self-test's XRAM item tests the 68010-side 64 KiB
  RAM, not this one. M10K budget after the fixes: 542 of 553 blocks.
- **Memory.** Synthesis of the flip-flop RAM needed >9 GB and was killed by
  the OOM handler on the 16 GB host; a 32 GB swap file carried the next run
  (peak 15 GB virtual, fit 24.5 GB). With the RAM inferred, synthesis peaks
  at 2.3 GB and takes 7 minutes instead of 80.
- **Logic.** First fit: 43,256 ALMs needed of 41,910 (103%), M10K 98%,
  DSP blocks 39%. Measured per module and reduced:
  - MSP off in the Quartus top (Race Drivin' has none; the sim already
    built without it): 11K ALUTs, 1 Mbit M10K.
  - rd_cabinet_io 1,304 -> ~500 ALMs (serial frame assembly, per-byte CRC,
    one FIFO write port).
  - dsp32c_core 10,911 -> 8,430 ALMs (one write port and three state-
    selected read ports on the register file, single instances of the
    DSP<->double conversions and the accumulator-history lookup, 3-bit ages
    instead of 48-bit timestamps). The write port alone was only -490: the
    ten separately indexed 32:1 read muxes were the cost.
  - dsp32c_fma 2,856 -> ~1,660 ALMs: product anchored in a 163-bit frame,
    only the 53-bit addend shifted (one right shifter plus a lost-bits mask
    for the sticky) instead of both operands through six 170-bit shifters.
    Still one rounding; 200,000 C-library fma vectors, 0 mismatches.
  Every change checked lock-step against MAME (boot 3M instructions, two
  gameplay traces of 2M) before the next build.
- **Timing (core clock 48 MHz, 20.8 ns).** First analysis: Fmax 17.9 MHz.
  The paths, in order, and what was done:
  - main_bus cockpit wheel scaling for the 8-bit ADC, a combinational
    divider (55 ns): a registered constant multiply over three clocks.
  - DSP32C int/int24 (floor, saturating int32, clamp, DSP float in one
    cycle, 38 ns): one state each. FMA leading-one count + normalise +
    round (33 ns): the count gets its own clock. CAU execute (decode, read
    mux, ALU, write, 23 ns): decode registered with the fetch, ALU in its
    own state, pointer post-increments applied a state later from the
    value read. Lock-step with MAME unchanged throughout.
  - TG68K internal paths (-2.9 ns): legitimately multicycle, the CPU
    advances on a one-in-18 clock enable; SDC declares them two-cycle.
  - After those: 42.2 MHz then -2.2 ns, all in the inherited GSP core and
    its cache fabric (decoded.iclass -> fill setup, memory fabric request
    -> gsp_memory cache valid/write queue), with 2-2.7 ns interconnect
    hops from the 96% fill. The Hard Drivin' SDC relaxes decoded -> regfile
    / memory-request / fill_row_base to two cycles (decoded is captured in
    CORE_DECODE_WAIT and used from CORE_DISPATCH on) but not these
    endpoints. The field sequencer's latches are (it latches a request the
    cycle after the core's request register goes active): added to the
    SDC. The rest (decoded.iclass -> divider, m2m_dst_addr_q, mm_rp_q,
    execute_wb_data_q, state_q) are the decode register's fan-out inside
    the GSP core, some of it genuinely single-cycle (decoded -> state_q).
  - Placement seeds, with PLACEMENT_EFFORT_MULTIPLIER 2.0, all re-timed
    under the same constraints: seed 67 -2.2 ns, 11 -2.33, 42 -2.14,
    3 -2.00, 5 -1.86, 7 -1.73, **23 -0.885 (46.0 MHz)**. Seed 23 is now
    the project's seed. The spread shows the remaining gap is routing
    congestion at 95% fill as much as logic depth. Options from here: a
    hardware trial of the seed-23 RBF (-0.9 ns, 4% of the period, slow
    100C model); taking the decode register's fan-out inside the GSP
    core off the critical path with a one-cycle-delayed copy for the
    consumers that never run in CORE_DISPATCH (divider, move/fill
    setup); or freeing 2-3K ALMs so the fitter has room (the DSP32C's
    registers are 24-bit values held in 32 bits, the two framework OSDs
    are ~1K).
