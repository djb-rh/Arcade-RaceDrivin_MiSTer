# Cabinet interface board: plan

A custom PCB that makes the Race Drivin' core plug-and-play in a real
cockpit and in a real compact cabinet. Video and sound come from the
standard MiSTer analog I/O board; this board adds everything else (wheel,
pedals, shifter, cabinet switches, coin door, force feedback, the two RS-232
ports, lamps and counters) and talks to the core through the I/O board's
user port, the cabinet link that `rtl/io/rd_cabinet_io.sv` and
`docs/cabinet-io.md` already implement.

The design principle that falls out of the sources: **the new board carries
the original main board's cabinet-facing connectors, with the original pin
numbering**, so every cabinet harness plugs straight in. The original main
board (cockpit A045988/A044425 "driver" board, compact A046901 MultiSync)
talks to the cabinet through one 12-pin power header, two ribbon cables (a
26-pin to the shifter PCB, a 16-pin to the motor amplifier) and a row of
11-pin 0.1" headers. That is exactly the "two ribbon-cable plugs and a set
of 0.1" header plugs" the user described.

## 0. Sources and how to read this document

Documented means read from an Atari drawing or manual; inferred means
deduced from those plus MAME or the game program; unverified means a guess
that a measurement must confirm before layout. Every unverified item is
collected in section 5 with the measurement that settles it.

Primary sources used (all scans; page numbers are the printed ones):

- **SP-327** Hard Drivin' Schematic Package, 1st printing 1989
  (jmargolin.com `HardDrivinSchem.pdf`): sheet 1 main wiring diagram, sheet
  2 power, sheet 9 ADCs and the J8/J9/J11/J14/J15 connectors, sheets 12-13
  APU and brake PCB, sheet 14 shifter PCB A043932, sheet 15 power supply
  and coin door. The cockpit cabinet; Race Drivin' cockpits use the same
  cabinet wiring and the same main-board connector set (Race Drivin'
  operator's manual parts list, p. 4-34: J1 12-circuit .250", J2-J6 and
  J8-J11 11-circuit .100", J12 9-circuit .250", J14 26-circuit dual row,
  J15 16-circuit dual row).
- **Atari 044253-01 Motor Amp PCB** schematic sheets 1-2 and the 044250-01
  driver PCB (jmargolin.com `mamp600.pdf`, `large_Motor Amp PCB.pdf`): the
  cockpit force-feedback amplifier.
- **TM-329** Hard Drivin' Compact operator's manual, 2nd printing (jmargolin
  .com `HDC_TM-329_2nd.pdf`): pedals (p. 3-7, 3-13), shifter switches
  (p. 3-14), steering assembly (p. 3-16 to 3-26, 4-9/4-10), cabinet parts
  (p. 4-4), compact main PCB connector list (p. 4-29) and silkscreen (fig.
  4-10), compact motor amplifier A046640-01 parts (p. 4-35), encoder and
  centring disk PCBs (p. 4-36). The Race Drivin' compact is the same cabinet
  and board family; no Race Drivin' compact manual was found.
- **Race Drivin' Operator's Manual** (crazykong `RaceDrivinCPit.man.pdf`,
  1990): parts lists for the main, APU, shifter and brake PCBs (p. 4-34 to
  4-41), voltage table 3-3.
- **Race Drivin' Linking Schematic R2** (Cavern Arcader / Margolin, 2023):
  the J2 to DB-25 link cable.
- `~/Developer/racedrivin-tools/docs/multisync-a046901.md`: the user's bench
  reading of the SP-338 (STUN Runner) drawing of the A046901 board: J1, J2,
  J3, J5, J6 pinouts, link cable.
- MAME `src/mame/atari/harddriv.cpp` and `harddriv_m.cpp`: only for what the
  game software sees at each port (bit positions, polarity, ADC widths,
  which switch is which). MAME says nothing about connectors or voltages
  and is not used for them.
- This repository: `docs/cabinet-io.md`, `rtl/io/rd_cabinet_io.sv`,
  `rtl/harddrivin_main_bus.sv` (output latches), `RaceDrivin.sv` (user-port
  wiring), `PLAN.md` sections 3 and 8, `NOTES.md` sections 1, 3, 5, 11.

Not available: the SP-338 schematic package itself (it draws the compact
board; the user has read it), any Race Drivin' compact manual, the compact
motor amplifier schematic, the compact cabinet wiring diagram. Everything
about the compact's wheel, pedal and shifter wiring beyond the manual's
tables is therefore inferred or unverified.

## 1. Signal inventory

### 1.1 Cockpit (A045988 / A044425 main board; four cabinets)

All switch inputs are contacts to ground with a 4.7 k pull-up to +5 V on the
main board (RN1/RN2 470 x 9 SIP on the parts list are the series resistors,
the 4.7 k network RN6 the pull-ups; polarity from MAME: active low).

Connector numbering is the main board's. "Link" is what the cabinet link
protocol (`docs/cabinet-io.md`) carries for the signal today.

| Signal | Connector, pin | Electrical type | Source | Link today |
|---|---|---|---|---|
| +5 V in | J1-2, 3, 10, 11 | 5 V from the Hitron 5 V 15 A supply | SP-327 sheet 2, sheet 15 | n/a |
| GND | J1-1, 5, 8, 12 | | sheet 2 | n/a |
| +15 V in | J1-4, 9 | +15 V regulated from the APU; the main board makes +12 V from it with a 7812 | sheet 2; manual table 3-3 | n/a |
| -22 V in | J1-6, 7 | unregulated negative rail from the APU; the main board makes -5 V from it and passes it to the shifter PCB | sheet 2 | n/a |
| Coin 1 | J6-1 | switch to ground (coin door left switch) | sheet 1, 15; MAME IN0 bit 7 | bit 0 |
| Coin 2 | J6-2 | switch to ground (right switch) | sheet 1, 15; IN0 bit 6 | bit 1 |
| Self-test | J6-3 | switch to ground (slide switch behind the coin door) | sheet 1; IN0 bit 5 | bit 3 |
| GND | J6-4, J6-8 | | sheet 1 | |
| keying pin | J6-5 | no contact (the drawings label the polarising pin "KEY"; it is not the key switch) | sheet 1 | |
| Coin counter 2 | J6-6 | open-collector sink; coil's other end on +14 V "+CC" from the APU (JCCC-3/5, 14 V via 10 ohm) | sheet 9 LS259 Q7 "CC2", sheet 12 APU; driver transistors inferred to be Q1/Q2 2N6044 | out bit 3 |
| Coin counter 1 | J6-7 | as above | sheet 9 "CC1" | out bit 2 |
| DIAGN | J6-9 | jumper to ground = diagnostics; not wired on the cockpit harness | sheet 1 (no wire); MAME IN0 bit 0 | bit 6 |
| Seat control (LC1) | J6-10 | open-collector output to the APU J10-1 "SEAT CNTRL" which drives the seat-lock/seat-adjust stage (APU Q6 TIP33, Q7 MPS-U07) | sheet 1 wiring, sheet 12/13; MAME nwr function 2 "seat locking"; drive level unverified | out bit 0 |
| LED 2 (LC2) | J6-11 | open-collector output to the control panel (abort button lamp) | sheet 1 "LED 2"; MAME nwr function 3 "abort lamp"; lamp voltage unverified | out bit 1 |
| keying pin | J5-4 | | sheet 1 | |
| Aux coin | J5-7 | switch to ground (auxiliary coin switch on the component bracket) | sheet 1; MAME a80000 bit 2 | bit 2 |
| Engine start (key switch) | J5-8 | switch to ground; the ignition key | sheet 1 "ENGINE"; a80000 bit 1 "Key" | bit 4 |
| Game start / abort | J5-9 | switch to ground; the lit abort button | sheet 1 "GAME START"; a80000 bit 0 "Abort" | bit 5 |
| GND | J5-10, 11 | | sheet 1 | |
| Pot supply | J9-1, 2, 3 | +5 V to the pedal and seat pots | sheet 9 | |
| Seat position | J9-4 | pot wiper, 0-5 V, to ADC0809 IN2 via 100 ohm (R6) | sheet 1 "SEAT", sheet 9; MAME 8BADC.2 | byte 11 |
| Clutch | J9-5 | pot wiper to ADC0809 IN1 (R5) | sheet 1, 9; 8BADC.1 | byte 10 |
| Gas | J9-6 | pot wiper to ADC0809 IN0 (R4) | sheet 1, 9; 8BADC.0 | byte 9 |
| keying / GND | J9-7 key (wiring) or J9-8 (schematic); J9-9, 10, 11 GND | the two drawings disagree on the key position | sheet 1 vs sheet 9 | |
| Wheel pot supply | J11-1, 2, 3 | from +15 V through R167 91 ohm on the schematic; the wiring diagram labels the same pin +5 V. Voltage unverified | sheet 9 vs sheet 1 | |
| Steering wheel | J11-7 | 10-turn pot wiper to the 12-bit AD7582 IN0 (R159/R64 5.6 k, C91) and, through R155 0 ohm, to the 8-bit ADC0809 IN5 (R3) with CR18 clamping it to +5 V | sheet 9; 12BADC.0 and 8BADC.5 | bytes 5-6 (12 bits; the core derives the 8-bit copy) |
| Brake SGA | J11-6 | amplified strain-gauge voltage from the Brake PCB 044817 (OPA111, +10 V supply) to AD7582 IN1; high when released (game reads 0xFFF released) | sheet 1 "BRAKE SGA", sheet 13; 12BADC.1 PORT_REVERSE | bytes 7-8 |
| 12-bit spare inputs | J11-4 (IN3), J11-5 (IN2) | unused | sheet 9 | |
| GND | J11-8, 10, 11; J11-9 keying | | sheet 1 | |
| Pots A header | J8-4 (= wheel, tied to J11-7), J8-5 (SLR, shifter X, IN4), J8-7 (SUD, shifter Y, IN3); J8-1..3 +5 V; J8-9..11 GND; J8-8 key | not plugged on the cockpit harness; the same nets arrive on J14 | sheet 9 | |
| Shifter ribbon | J14 (26) | see 1.3 | sheet 9, 14 | partly |
| Motor amp ribbon | J15 (16) | see 1.4 | sheet 9, 044253-01 | byte 3 |
| Serial A | J2 | see 1.5 | multisync doc, link schematic | bytes 15, 17-20 / 5, 7-10 |
| Serial B | J3 | see 1.5 | same | bytes 16, 21-24 / 6, 11-14 |
| DSK LED | DSK board, not a cabinet signal | | | out bit 4 |
| Video | J10 (R, G, B, composite sync, GND) to the 25 kHz monitor | from the MiSTer analog I/O board instead | sheet 1 | n/a |
| Sound | J12 power and P2/P12 to the sound PCB; speakers on the APU | from the MiSTer analog I/O board instead | sheet 1 | n/a |
| Coin door lamps | +5 V AC from the power transformer, not through the main board | | sheet 15 | n/a |

Compact main board input not present on the cockpit: none. Cockpit inputs
that the compact does not have: seat, shifter pots, shift force, 12-bit
wheel and brake.

### 1.2 Compact (A046901 MultiSync; one cabinet)

The compact board carries the same connector set (TM-329 p. 4-29: J1
12-circuit .250", J2-J6 11-circuit .100", J8-J10 and J13 11-circuit
.100", J12 9-circuit .250", J14 26-circuit, J15 16-circuit dual row, plus
BCLK/VCLK/SPEED test headers). Silkscreen on fig. 4-10 reads J8 POTS A,
J9 POTS B, J14 SHIFTER, J15 STEERING WHL, J4 SW A, J5 SW B, J6 COIN DOOR,
J3 SERIAL B, J2 SERIAL A. There is no 12-bit ADC on this board (MAME marks
the 12-bit ports fake) and no J11.

| Signal | Connector, pin | Electrical type | Source | Link today |
|---|---|---|---|---|
| Power | J1: 2, 3, 10, 11 +5 V; 1, 5, 8, 12 GND; 4, 9 +15 V; 6, 7 negative rail | as cockpit | multisync doc | n/a |
| Coin 1, Coin 2, Self-test, DIAGN | J6-1, 2, 3, 9 | switch to ground | multisync doc | bits 0, 1, 3, 6 |
| Coin counters | J6-6, J6-7 | open-collector sinks (compact main parts list also has Q1/Q2 2N6044) | multisync doc; inferred | out bits 2, 3 |
| Key switch / engine start | J5-8 | SPDT switch, black = common, white = NO (p. 3-7) | multisync doc, TM-329 | bit 4 |
| Abort / game start | J5-9 | switch to ground | multisync doc | bit 5 |
| Aux coin | J5-7 | switch to ground | multisync doc | bit 2 |
| Gear switches 1-4 | **unverified**: J5-1..6 or J4 "SW A" | four maintained microswitches, N.O. contacts brown/orange/yellow/green, black common (table 3-9); the game reads them at a80000 bits 8-11, active low | TM-329 p. 3-14; MAME | bits 9-12 |
| Steering encoder A, B | **unverified**: J4 "SW A" or J13 | Encoder Disk PCB A046689-01: dual slotted opto-sensor, NPN output, R1 150 ohm LED resistor, 4-circuit .156" locking connector; 8-bit count per revolution (self-test: "changes to zero once every turn") into the counter at 0x400000 | TM-329 p. 4-36, p. 2-12; MAME hdc68k_wheel_r | planned on USER_IO[2..4]; not in frames |
| Steering centre index | same harness | Centering Disk PCB A046691-01: single slotted opto, NPN, R1 220 ohm, 4-circuit .156"; sets a80000 bit 14 "center edge" when crossing centre | TM-329 p. 4-36; MAME | USER_IO[4] planned |
| Gas | J9-6 (inferred from the cockpit J9) | 5 k pot (119008-1001), red top / white centre / black bottom (table 3-7), to ADC0809 IN0 | TM-329 p. 3-13, 4-15 | byte 9 |
| Clutch | J9-5 (inferred) | 5 k pot, red / yellow / black, to ADC0809 IN1 | same | byte 10 |
| Force brake | **unverified** pin | 350 ohm strain gauge bonded to the brake pedal (table 3-7 text, p. 3-13); amplified somewhere (the compact motor amp parts list has an ADOP07CN and the cockpit's separate Brake PCB is absent from the compact parts list) and read on ADC0809 IN6: 0xF0 released, 0x20 full | TM-329; MAME 8BADC.6 | byte 14 |
| Motor amp ribbon | J15 (16) to A046640-01 J6 "Motor Ribbon Cable Assembly A046336-01" | see 1.4; same connector and OPT1 jumper block as the cockpit amp | TM-329 p. 4-4, 4-35 | byte 3 |
| Shifter ribbon J14 | present on the board, not used by the compact harness | | TM-329 fig. 4-10 | |
| Serial A, B | J2, J3 | as cockpit | multisync doc | as cockpit |
| Volume | 10 k pot on the component bracket into the APU | not ours | TM-329 p. 4-4 | n/a |
| Video, sound | 18.6 kHz monitor, APU speakers | from the MiSTer analog I/O board | | n/a |

### 1.3 The shifter ribbon J14 (cockpit only)

26-conductor ribbon from main J14 to the shifter PCB A043932 J6, 1:1. Read
from SP-327 sheet 9 (main side) and sheet 14 (shifter side).

| J14 pin | Main-board net | Direction | What it is |
|---|---|---|---|
| 1, 2, 3, 4 | SEL1..SEL4 | out, TTL via 100 ohm | 74LS259 (65C) outputs Q1..Q4, set and cleared by writes to 0xA00000 functions 1-4 (MAME `hd68k_wr0_write`). On the shifter PCB JP2 picks SEL1 or SEL2 as the clock of latch IC9 (74LS374 feeding a DAC-08) and JP1 picks SEL3 or SEL4 as the clock of latch IC7 (74LS374 feeding two 74LS163 counters that PWM the clutch coil through Q1 IRF630). |
| 5, 7, 9, 11, 12, 13, 14, 16 | D0..D7 | out, TTL via 100 ohm, 1 nF to ground | 74LS374 (85C) latched by /WR1 = upper byte of a write to 0xA80000 (MAME `hd68k_wr1_write`, "Shifter Interface Latch"). |
| 6, 8, 10 | not connected | | |
| 15 | +5 V | power | shifter logic (through L1 3.3 uH on the shifter PCB) |
| 17 | -22 V | power | shifter PCB 7905 (-V) through R27 4.7 ohm 1 W |
| 19 | +12 V | power | shifter PCB 7805 (+V) through R28 4.7 ohm 1 W; +12 V is made on the main board by a 7812 from +15 V |
| 18 | GND | | |
| 20, 22, 24 | GNDA | analog ground | |
| 21 | STRAINOB | in, analog | shifter strain-gauge amplifier (ADOP07 IC11, TL082 IC10, JP3 position B) to ADC0809 IN7 via R55 100 ohm: MAME harddriv "shift force" (8BADC.7), unused by Race Drivin' (IPT_UNUSED). |
| 23 | STRAINOA | in, analog | same amplifier, JP3 position A, to ADC0809 IN6 via R56. On the cockpit MAME calls IN6 "line volts". |
| 25 | SLR | in, analog 0-5 V | shifter X pot wiper (shifter PCB J4, pot fed from its +V) to ADC0809 IN4: 8BADC.4 "Shifter Lever X" |
| 26 | SUD | in, analog 0-5 V | shifter Y pot wiper (J5) to ADC0809 IN3: 8BADC.3 "Shifter Lever Y" |

The shifter's clutch-coil supply comes through the cabinet harness into the
shifter PCB's own J1 (CR2 1N5401, C5 4700 uF), not through the ribbon, so
the new board needs nothing for it.

Race Drivin' does use this path. The MAME trace shows, at every 244 Hz
interrupt, a write of the shifter interface latch followed by SEL3 driven
low then high (wr1 data, wr0 function 3 value 0, wr0 function 3 value 1,
two microseconds apart): a rising edge on SEL3 clocks the data into the
shifter PCB's IC7 latch (JP1 in its SEL3 position), the register that sets
the clutch-coil PWM. The data is 0x00 almost always and 0xB9 for about 0.4
s around the transmission-selection screen of the scripted race, so the
coil (the shifter's detent magnet) is engaged briefly then. SEL1, SEL2 and
SEL4 are never written.

### 1.4 The motor-amp ribbon J15 and what the amplifier expects

16-conductor ribbon from main J15 to the motor amp 044253-01 J6, 1:1. The
force byte is the upper byte of the game's write to 0xB00000 (MAME
`hd68k_wr2_write`, output "wheel"); the main board latches it in a 74LS374
(95C, clocked by /WR2) and presents it as eight static TTL levels through
100 ohm resistors with 1 nF to ground.

| J15 pin | Net | J6 pin on the amp | Amp side |
|---|---|---|---|
| 2, 4, 6, 11, 10, 12, 14, 16 | D0, D1, D2, D3, D4, D5, D6, D7 | same numbers | 74LS244 IC12 inputs; D0..D4 direct, one of D5/D6/D7 chosen by jumper block OPT1 (pairs 3-4, 2-5, 1-6, "see note 2"), so six bits are used |
| 8, 9, 13, 15 | +5 V | 9 = +5 V LOGIC (through L1 3.6 uH, C10 100 uF); 8, 13, 15 not connected on the amp | supplies the LS244 and the six opto LEDs (470 ohm each, about 8 mA per lit bit) |
| 1, 3, 5, 7 | GND | 1, 3, 5, 7 | logic ground |

Behind the optos (TIL115 x 6, 4.3 k pull-ups to the amp's own 20 V) the
bits go into two 74HC174 registers clocked by a free-running 74HC14 RC
oscillator ("FORCE LATCH"), then a DAC-08 and a 741 current mirror produce
SFORCE (magnitude) and SDIRECTION, which a TL595 PWM stage turns into
DRIVE-EVEN/DRIVE-ODD for the two 044250-01 driver PCBs (IRF9640/IRF630
half-bridges on +RAIL/-RAIL, the off-line rectified mains bus; the motor
sits between J2-1 and J2-4 via 3.6 uH chokes). So:

- **There is no hardware strobe line across J15, but the game makes one in
  software.** A MAME trace of the cockpit set (this session, `mame/
  oracle.lua` with `RD_OUT=1`, attract mode and a scripted race) shows the
  game writing the force latch four times in about 100 us at every 244 Hz
  periodic interrupt: `V`, `V | 0xE0`, `0xE0`, `0x00`, with `V` in bits
  0-4. Bits 5, 6 and 7 always move together: they are the strobe, and the
  amp's OPT1 jumper picks which of the three it listens to. The sixth opto
  feeds the 74HC14 RC chain that clocks both 74HC174 registers, so the amp
  latches bits 0-4 on the delayed rising edge of the strobe, about 35 us
  after `V | 0xE0` appears, while the data is still valid. This closes
  PLAN.md decision 5's open item.
- The five data bits are, by every indication, four torque bits (D0-D3)
  and a direction bit (D4): the amp's "LEVEL SHIFT" transistor Q1 feeds a
  single bit to the TL595's steering input as SDIRECTION, the DAC-08 and
  current mirror make SFORCE from the rest, and the Suzo-Happ 50-2000-05
  that replaces this amp exposes exactly "torque A-D" plus "direction" on
  its J1. In the trace attract mode writes `V = 0x00` throughout (no force)
  and the race writes values clustered at 0x00, 0x01, 0x10, 0x11, 0x0F,
  0x0D with occasional 0x13 and 0x16 (small torques of both signs plus
  short large ones). Inferred; the bench test in section 5, item 4, confirms
  which polarity of D4 is clockwise.
- +5 V on the ribbon is the amp's logic supply. The new board must source
  about 100 mA on J15-9 and should fuse it.
- The coin counters, for the record from the same trace: the game holds a
  counter line on for about 0.2 s per coin, and writes the counters off at
  every interrupt otherwise. The seat-lock line (LC1) is written 0 every
  interrupt in attract and goes to 1 once at race start; the abort lamp
  (LC2) is written 0 at attract start and about four times a second during
  the race. The polarity at the connector (which state lights the lamp)
  is item 7 in section 5.

The compact amp A046640-01 has the same 16-pin dual-row J6 and the same
6-pin OPT1 block (TM-329 p. 4-35), a DAC-08, two 74LS174 and a 7406, so its
input stage is almost certainly the same six-bit static interface without
optos (inferred; the compact amp schematic is not available). Its power
stage is low voltage (4 x 4700 uF 25 V, 15 V and 20 V zeners, TIP145/TIP140
darlingtons, IRF630/IRF9640), fed from the cabinet's transformer, not the
mains, so bench work on it is safer than on the cockpit amp.

### 1.5 The serial ports J2 and J3

Identical pinouts (multisync doc, link schematic R2): 4 and 5 ground, 6 RX
into the board, 7 TX out, 9 a switched copy of TX, 10 +12 V through 10 ohm
(never a supply), 11 +12 V through 220 ohm, switched, read back as "link
present". The main board uses an MC1488 driver and MC1489 receiver on the
board's +12 V/-5 V. The factory link cable is a DB-25 bulkhead on each
cabinet (J2-7 to pin 2, J2-6 to pin 3, J2-4 to pin 7, J2-5 to pin 1, J2-11
to pins 4 and 5 joined) and a DB-25 null-modem cable between cabinets; only
TX, RX and ground matter to the programs. Pins 9, 10, 11 serve the Panorama
side monitors. Both channels run 38,400 8N1.

## 2. Connectors and pin map of the new board

The board reproduces the main board's cabinet connectors one for one.
Original references: Atari 179118-011 11-circuit .100" header (Molex
KK-series friction-lock style; confirm the housing on the harness),
179069-012 12-circuit .250" header (power), 179261-026 and 179261-016
dual-row .1" x .1" shrouded headers (ribbon). Keying pins are left as pins
with no circuit, exactly as the original, so keyed housings still fit.

### 2.1 Connector list

| New board | Mates with | Cockpit | Compact | Notes |
|---|---|---|---|---|
| P1 power, 12-pin .250" | cabinet power harness (J1) | yes | yes | +5 V (2, 3, 10, 11), GND (1, 5, 8, 12), +15 V (4, 9), -22 V (6, 7). The board runs from +5 V and makes +12 V and the pot reference; -22 V only passes through to J14-17. |
| J6 coin door, 11-pin .100" | coin door harness | yes | yes | 1 COIN1, 2 COIN2, 3 SELF-TEST, 4 GND, 5 key, 6 CC2, 7 CC1, 8 GND, 9 DIAGN, 10 LC1 seat control, 11 LC2 LED 2 |
| J5 controls, 11-pin .100" | dashboard switch harness | yes | yes | 4 key, 7 AUX COIN, 8 ENGINE/key switch, 9 GAME START/abort, 10, 11 GND; pins 1, 2, 3, 5, 6 reserved for the compact gear switches until measured |
| J4 "SW A", 11-pin .100" | compact only, function unverified | no | maybe | populate once the compact harness is traced (gear switches and/or encoder) |
| J13, 11-pin .100" | compact only, function unverified | no | maybe | as J4 |
| J8 pots A, 11-pin .100" | not plugged on the cockpit | no | maybe | 1, 2, 3 pot supply; 4 wheel; 5 shifter X; 7 shifter Y; 8 key; 9, 10, 11 GND |
| J9 pots B, 11-pin .100" | pedal/seat harness | yes | yes | 1, 2, 3 pot supply; 4 SEAT; 5 CLUTCH; 6 GAS; 7 key (wired as the harness has it); 8 spare; 9, 10, 11 GND. The compact force brake lands here or on J8 (unverified). |
| J11 pots C, 11-pin .100" | steering and brake harness | yes | no | 1, 2, 3 wheel pot supply; 4, 5 spare analog in; 6 BRAKE SGA; 7 STEERING; 8, 10, 11 GND; 9 key |
| J14 shifter, 26-pin dual row shrouded | shifter PCB ribbon | yes | no | pin map of section 1.3, including +5 V, +12 V, -22 V, GND, GNDA |
| J15 steering wheel, 16-pin dual row shrouded | motor amp ribbon (cockpit 044253-01 J6, compact A046640-01 J6) | yes | yes | pin map of section 1.4 |
| J2 serial A, J3 serial B, 11-pin .100" | the cabinet's DB-25 pigtail | yes | yes | 4, 5 GND; 6 RX; 7 TX; 9 TX copy; 10 +12 V via 10 ohm; 11 +12 V via 220 ohm, sensed |
| JM MiSTer user port | USB 3.0 A-to-A cable to the I/O board's user port | yes | yes | see 3.1 |
| JENC encoder, 2 x 4-pin .156" or one 8-pin | compact encoder and centring PCBs (A046689-01, A046691-01 each have a 4-circuit .156" locking connector) | no | yes | only if the compact harness brings the opto PCBs to the main board on their own plugs rather than through J4/J13; decided by the trace in section 5 |
| JFF modern force-feedback, 8-pin .100" | Suzo-Happ 50-2000-05 J1 (torque A-D, direction, ground) or an H-bridge module (PWM, DIR, EN, GND) | optional | optional | fallback for a cabinet without a working original amp |
| JDBG | USB-C to the ESP32-S3 (native USB/JTAG), 2x5 JTAG | | | firmware and debug |

Cabinet-specific differences a single board absorbs with population
options and a cabinet-type DIP switch read by the firmware:

- Cockpit: J11, J14 populated; wheel is a pot on J11-7; brake is a 12-bit
  value from BRAKE SGA; seat and shifter pots; J8 unused.
- Compact: J4/J13/JENC as traced; wheel is the quadrature encoder; brake is
  the 8-bit force value; gear switches; J11 and J14 unpopulated.

Adapter harnesses: none are needed for the cockpit, which is the point.
For the compact, until J4/J13 are traced, a short pigtail from the encoder
PCBs' .156" plugs to JENC is the fallback.

What is not on this board and comes from the MiSTer I/O board instead:
monitor RGB and sync (the cockpit's J10 11-pin and the compact's video
harness: a VGA-to-Atari-video pigtail from the I/O board's VGA connector),
and audio (the I/O board's line/amp output into the cabinet APU's audio
inputs, JAUX-5/9 on the cockpit APU, or straight to the speakers if the APU
is bypassed). Those pigtails are a separate small task.

## 3. Board architecture

### 3.1 Hanging off the MiSTer user port

The user port is the analog I/O board's USB 3.0-shaped socket: seven
open-drain 3.3 V LVTTL FPGA lines with weak pull-ups (NOTES.md section 5:
pin 1 +5 V, pin 4 GND, D-/D+ = USER_IO[1]/[0], the four SS pins = USER_IO
[2..5], pin 7 = USER_IO[6] via the IO6 jumper on I/O board 6.1 and later).
Confirm the mapping against the schematic of the I/O board revision in the
cabinet before layout; clone boards differ.

The core today (`RaceDrivin.sv` lines 11 and 544) drives USER_OUT[0] as its
link TX and reads USER_IN[1] as link RX, 2,000,000 baud 8N1. The board side:

- RX from the core on USER_IO[0]: 100 ohm series into an ESP32 UART RX pin
  (3.3 V, no shifting needed).
- TX to the core on USER_IO[1]: push-pull 3.3 V through 100 ohm is safe
  because the FPGA pin is an input in this design; an open-drain driver
  with the FPGA's weak pull-up would be too slow at 2 Mbaud.
- USER_IO[2], [3], [4]: compact encoder A, B, index, buffered 3.3 V (option,
  section 3.6).
- USER_IO[5], [6]: reserved; bring them to a header (fallback raw serial
  lines per PLAN.md 3.2).
- Pin 1 (+5 V from the MiSTer): not used for power. The board runs from the
  cabinet's +5 V; sharing only ground with the MiSTer avoids loading the
  DE10's 5 V rail and avoids a loop through two supplies. Bring pin 1 to a
  sense input so the firmware can tell the cable is plugged in.
- ESD: a 3.3 V TVS array on all seven lines at the socket, 100 ohm series.

Ground: cabinet ground, MiSTer ground and the video ground meet at this
board's P1 ground. One star point, a solid ground plane, no isolation (the
original was not isolated either; the only isolation in the system is the
motor amp's optos, which stay).

### 3.2 Power

| Rail | From | Used by | Notes |
|---|---|---|---|
| +5 V cabinet | P1 | 3.3 V regulator, pull-ups, 74HCT output buffers, J15-9 amp logic (fused 250 mA polyfuse), J14-15 shifter logic (fused), pot supply reference, encoder optos | the Hitron supply has ample margin; the original main board drew several amps |
| +3.3 V | buck or LDO from +5 V | ESP32-S3 module (up to 500 mA peaks with Wi-Fi), ADC, LVC buffers, MAX3232 | a 1 A buck keeps the LDO heat off the board when Wi-Fi is on |
| +12 V | 7812 (or a 12 V buck) from +15 V on P1-4/9, exactly as the original main board did | J14-19 (shifter PCB 7805 input), J2/J3 pins 10 and 11, MAX3232 does not need it | fused 500 mA; if the cabinet's +15 V is absent (bench), a jumper feeds +12 V from a DC jack |
| -22 V | P1-6/7, passed through | J14-17 only | fused 250 mA; nothing else on the board touches it |
| Pot reference | 5.00 V precision regulator or reference (REF5050 class) from +5 V | J8/J9/J11 pins 1-3 and the ADC VREF | ratiometric measurement, so the exact value does not matter and the game's Set Controls calibration absorbs the rest; the cockpit wheel pot originally saw a higher voltage (section 5, item 5), which is why we do not feed the ADC from the cabinet rail |

Bench mode: a 5.5 mm DC jack and a jumper let the board run from a 5 V
adapter plus a 12 V adapter without the cabinet.

### 3.3 Microcontroller: keep the ESP32-S3

PLAN.md decision 4 chose the ESP32-S3. Re-examined against the inventory:

For: three hardware UARTs (one for the 2 Mbaud link, one each for the two
RS-232 channels, so no bit-banged serial); up to 5 Mbaud; four PCNT pulse
counter units with hardware quadrature decoding for the compact encoder;
45 GPIO, enough for 8 data + 4 SEL + 8 force lines + 12 switch inputs + 5
outputs + SPI + UARTs without an expander; native USB for firmware and
debug; Wi-Fi/BLE for the pod stream and the link bridge that the user is
already planning (PLAN.md 3.2). Using the ESP32-S3-WROOM-1 module avoids RF
layout and certification questions.

Against: the internal ADC is not good enough (Espressif's own figures:
12-bit SAR, DNL +/-4 LSB, INL +/-8 LSB, usable 100-2900 mV, calibration
needed), and the pins are not 5 V tolerant. Both are solved with an external
SPI ADC and 5 V-tolerant buffers, which a pure-I/O MCU would need anyway for
the TTL outputs.

Alternatives considered: STM32G4 (five excellent 12-bit ADCs with hardware
oversampling to 16 bits, 5 V-tolerant pins, encoder timers, five USARTs; no
Wi-Fi) would be the better chip if the Wi-Fi bridge is dropped; RP2350
(PIO for anything, two mediocre ADCs, Wi-Fi only on the Pico 2 W module)
brings nothing the S3 lacks. Verdict: ESP32-S3 with an external ADC. The radio
is also what makes the board a link bridge in its own right (3.12); if the
link latency measurement (PLAN.md 3.2) ends up forbidding radio for the
link, the Wi-Fi still earns its place for the pod stream and updates.

### 3.4 Analog front end

Channels: wheel (cockpit pot), brake SGA (cockpit), gas, clutch, seat,
shifter X, shifter Y, shift force (STRAINOA/B), compact force brake, two
spares: eleven. Two MCP3208 (8-channel 12-bit, 100 ksps, SPI, VREF pin) or
one ADS7953 (16-channel 12-bit) ratiometric to the 5.00 V pot reference.
Per channel: 1 k series, 10 nF to ground (160 Hz corner; the game samples
at tens of hertz), Schottky clamps to the reference and ground, 100 k
pull-down so an unplugged pot reads zero rather than floating.

- Wheel: the game expects 0x010-0xFF0 over the pot's travel and calibrates
  the centre and ends itself. Oversample 8 x per 1 ms frame and send the
  average: the force-feedback cross-check (the game compares the 12-bit
  reading with its 8-bit copy before enabling the motor, NOTES.md section
  5) is satisfied because the core derives both from the one value.
- Brake SGA: the cockpit Brake PCB runs its OPA111 from +10 V, so the
  output can exceed 5 V; a 2:1 divider (10 k/10 k) in front of the clamp
  keeps the released level (which the game reads as 0xFFF) in range.
  Confirm the span (section 5, item 6).
- STRAINOA/B from the shifter PCB come from a TL082 on +/-5 V and may swing
  below ground: the clamp handles it; a 2:1 divider is not needed (the
  original fed it to a 5 V ADC directly).
- Compact force brake: 0-5 V (the original ADC0809 reference was 5 V),
  reads 0xF0 released; the core already maps byte 14 straight through.
- Shifter X/Y pots are fed from the shifter PCB's own 5 V, so they are
  ratiometric to that, not to our reference: a gain error of a few percent
  that the game's shifter calibration absorbs.

### 3.5 Switch inputs and the 5 V boundary

Twelve switch lines (COIN1, COIN2, SELF-TEST, DIAGN, AUX COIN, ENGINE,
GAME START, gears 1-4, spare) plus two link-present senses. Keep the
original noise margin: 4.7 k pull-up to +5 V at the connector, 1 k series,
then a 74LVC541 (5 V-tolerant inputs on a 3.3 V supply) into the ESP32.
Firmware debounces 2 ms and samples at the 1 kHz frame. The coin switches
are the only inputs where a 1 ms edge matters (the game's coin counter
pulse logic is on the output side, not here).

Link-present (J2/J3-11): the cable joins pin 11 to DB-25 pins 4/5 on the
far cabinet; sense through a 22 k/10 k divider with a clamp. The programs
never read it outside self-test, so this is cosmetic.

### 3.6 The wheel

Cockpit: pot into the ADC (3.4). Compact: Encoder Disk PCB (two NPN
phototransistor outputs, LED resistor on the PCB) and Centering Disk PCB
(one NPN output). Our side supplies +5 V to the LED/sensor rails and pulls
the open-collector outputs up to 3.3 V (4.7 k), so they can go straight to
3.3 V logic. Route A, B and index to both a 74LVC buffer feeding USER_IO
[2..4] (PLAN.md 3.2: the core counts in hardware) and to the ESP32 PCNT
unit (the count travels in frames, section 4). Jumpers select the path;
the bench measurement in section 6 decides which ships. Verify the four
pins of each opto PCB's .156" plug and the output levels with the cabinet
powered (section 5, item 2).

### 3.7 Force feedback

Primary path (PLAN.md decision 5, option F1): J15 carries the force byte as
eight 5 V TTL levels. A 74HCT244 (3.3 V input thresholds, 5 V outputs)
driven from ESP32 GPIO, 100 ohm series and 1 nF to ground per line like the
original, +5 V on pins 8, 9, 13, 15 through a 250 mA polyfuse, ground on 1,
3, 5, 7.

The board regenerates the strobe rather than copying it. The game's strobe
toggles at 244 Hz and the link samples at 1 kHz, so a copied byte would
alias and the amp would see edges late or not at all. Instead the core
sends the latched five-bit code (section 4) and the firmware replays the
game's own sequence once per frame or on change: `V` with bits 5-7 low,
35 us later `V | 0xE0`, 35 us later `0xE0`, 35 us later `0x00`, driving all
three upper bits together so the OPT1 setting does not matter. The amp's
two-stage latch then carries the new torque within about 1.1 ms of the
game's write. Timing is from the trace (section 1.4); the hold time the
amp really needs is measured on the bench (section 5, item 4).

Fail-safe: the 244's output enable comes from a retriggerable monostable
(or a small RC watchdog) kicked by every valid output frame; with the link
down, the MCU in reset or the firmware stalled, the outputs tri-state and
10 k pull-downs present the all-zero code, which is what the game writes
throughout attract mode (zero torque, inferred). No strobe edge reaches the
amp in that state, so it also keeps the last latched value until one does;
the firmware therefore strobes a zero code before it stops on a link loss,
and the watchdog covers the cases where it cannot. Confirm on the bench
that all-zero is zero torque (section 5, item 4).

The compact amp takes the same ribbon; the same circuit serves it
(inferred, section 1.4).

Fallback (option F2) for a cabinet with a dead amp: JFF header with five
open-drain sinks (torque A-D, direction, 20 mA, as the Suzo-Happ 50-2000-05
J1 wants: pins 4-7 torque A-D with A the least significant, pin 8 direction
with 1 = clockwise, pin 2 ground) and a PWM/DIR/EN group for a BTS7960-class
H-bridge module at 20 kHz sign-magnitude. If the inference in 1.4 holds,
the Happ board takes bits 0-3 and bit 4 of the code directly, with no
strobe, which is presumably how it was designed as a drop-in for the 044253
amp. The motor supply (24 V for the Happ driver) is external to this board.

### 3.8 Shifter PCB interface (cockpit)

J14 data D0-D7 and SEL1-4 are 5 V TTL outputs: a second 74HCT244 plus four
more buffer bits, 100 ohm series, 1 nF to ground on the data lines as the
original. Power pins per 3.2. Inputs STRAINOA/B, SLR, SUD per 3.4. The
shifter PCB latches D on the rising edge of the selected SEL line; the
firmware reproduces whatever sequence the trace in 4.3 shows the game
using (data first, then a SEL pulse of at least 1 us, or a level).

### 3.9 Outputs: counters, seat control, LED 2, DSK LED

Four open-drain sinks (logic-level MOSFETs such as IRLML2502 with a flyback
diode to a clamp rail, or a ULN2003A): CC1 and CC2 on J6-7/J6-6 (counter
coils sit on +14 V from the APU; sink up to 200 mA), LC1 seat control on
J6-10 and LC2 LED 2 on J6-11 (loads unverified, section 5, item 7). Rate
them for 30 V/500 mA so any lamp or relay the harness has is covered. The
DSK board's LED is on the board as a status LED. The firmware stretches
coin-counter pulses to at least 50 ms and never leaves a counter on when
the link drops.

### 3.10 RS-232

Two SP3232/MAX3232 transceivers on 3.3 V (two drivers and two receivers
each): channel A driver to J2-7 and, through the second driver, the "TX
copy" J2-9; receiver from J2-6; same for J3. J2/J3-10 and -11 get +12 V
through 10 ohm and 220 ohm from the +12 V rail with the sense tap of 3.5
(both lines fused). Transceiver TX/RX go to two ESP32 UARTs at the rate the
core reports (the core re-serialises at the DUART's programmed rate, so the
board can fix 38,400 8N1 and the frames carry the bytes). TVS on the
connector pins; the link cable runs across the floor between cabinets.

### 3.11 Protection and housekeeping

- Every cabinet-facing input: TVS array, series resistor, clamp.
- Every supply leaving the board: polyfuse; P1 inputs: reverse-polarity
  protection on +15 V and -22 V paths, TVS on +5 V.
- Cabinet-type DIP (2 bits), board address DIP (for linked cabinets later),
  status LEDs (power, link, board OK, force active), test points on every
  analog input and the link lines.
- USB-C to the ESP32's native USB for flashing; 2x5 JTAG; a UART header on
  UART0 for logs.
- Four-layer board, cabinet connectors along one edge in the original
  order (J8, J9, J14, J15, J4, J5, J6, J3, J2 left to right as the A046901
  silkscreen has them), P1 at a corner, the user-port socket at the other
  edge. Mounting holes to sit on the original main-board standoffs if the
  cabinet's board tray is reused (measure the A045988/A046901 outline).

### 3.12 Link transport: cable, ESP-NOW, LAN

The two RS-232 channels must work three ways: over the factory cable to a
real cabinet or to another MiSTer cabinet, over the air to an ESP32 bridge
sitting on a real cabinet's J2, and over the air to another board of this
design. The bytes already pass through the ESP32 in every case (core, user
port, board, transceiver), so the board *is* a link bridge with extra
connectors, and the transport is a routing choice inside one firmware. The
same firmware, minus the cabinet I/O, runs on the real-hardware bridges.

**Route not taken: the MiSTer's own network.** The framework gives every
core one serial port into Linux: the `UART_TXD`/`UART_RXD` ports that
`RaceDrivin.sv` currently ties off go to the HPS UART in `sys/sys_top.v`
(a tty in Linux). A userspace daemon on the MiSTer could forward link bytes
over the MiSTer's Wi-Fi dongle, with one IP address in the cabinet and no
kernel change. Rejected: it is a single channel (serial B and the pod
stream stay on the board anyway), it needs a second link path in the core
(HPS for air, user port for cable) kept in step with the first, it needs
the bridge protocol implemented twice (ESP-IDF and Linux), and the Linux
tty adds scheduler jitter on top of the radio's. The user port itself can
never carry a network: every pin of its USB3 socket is FPGA GPIO. A USB
network-class device on the hub is out too: the MiSTer kernel config
(`arch/arm/configs/MiSTer_defconfig`, branch MiSTer-v6.18) has
`CONFIG_USB_NET_DRIVERS` unset, so no cdc_ether/ncm/rndis host driver.

**Transport order.**

1. **Cable** (default). J2/J3 through the SP3232 as in 3.10. The ESP32
   is a transparent pass-through at 38,400 8N1; byte latency is the
   transceiver's, a few microseconds, so this path matches the original.
2. **ESP-NOW** (preferred radio mode). Espressif's connectionless
   peer-to-peer protocol between ESP32s: 802.11 vendor-specific action
   frames on a fixed 2.4 GHz channel, no access point, no DHCP, no IP
   address, unicast frames acknowledged and retried at the MAC level,
   up to 250 bytes of payload per frame. Latency is one air transaction,
   typically 1 to 3 ms, with far less jitter than a LAN hop through a
   router. The board is not on the home network at all in this mode.
   Every link endpoint in this plan is an ESP32, so nothing is lost by
   excluding non-ESP nodes.
3. **LAN UDP** (fallback for distance). Both ends join the house Wi-Fi as
   stations and exchange the same frames over UDP. This is the one mode
   in which the board holds an IP address beside the MiSTer's. Accepted
   only where ESP-NOW cannot reach.

**Frame design, common to modes 2 and 3.** A frame carries a channel id
(A or B), a 16-bit sequence number, a sender timestamp, and the bytes
received from the core since the previous frame; send on a 2 ms tick or
when 32 bytes are waiting, whichever first (at 38,400 8N1 a channel yields
at most about 8 bytes per 2 ms). The receiver re-serialises the bytes to
its core at 38,400 through a de-jitter buffer whose depth is a setting
(start at 4 ms) and whose correct value comes from open question 9. A gap
in sequence numbers is logged, never retransmitted: the factory cable had
no retransmission either, so the games' own protocol has to survive a
lost byte, and a late retransmission would be worse than a hole. The pod
stream on serial B is one-way and tolerates loss; the link on serial A is
what open question 9 measures.

**Addressing and pairing.** Peers are MAC addresses in the ESP32's NVS.
The board-address DIP of 3.11 names this node; a pairing button (hold 3 s)
broadcasts a pairing frame for 30 s and stores whoever answers, so two
cabinets pair with two button presses and no PC. Pairings persist across
power cycles. Encrypted ESP-NOW peers (shared LMK) keep a neighbour's
cabinet from joining by accident; the limit of six encrypted peers covers
a Panorama trio with room to spare.

**Channel plan.** ESP-NOW uses one fixed channel that every node must
share. When a board is only an ESP-NOW node, pick a 2.4 GHz channel away
from the house access point. When a board also joins the house Wi-Fi (LAN
mode, or firmware update over the air), ESP-NOW is forced onto the access
point's channel. Firmware updates therefore run in a separate "service"
mode entered from the pairing button or the USB console, so normal play
never needs the board on the LAN. The MiSTer's own dongle should be a 5
GHz-capable one (next paragraph) so its traffic is off the 2.4 GHz band
the link uses.

**Mode selection.** Rev A: a 3-position DIP (cable, ESP-NOW, LAN), read at
boot and reported in a status LED pattern. An OSD-driven selection over
protocol v2 can come later once the frame layout is final; it costs one
spare output bit and a mode field in the input frame.

**The real-hardware bridge.** Same firmware, a smaller board: ESP32-S3
module, one SP3232, the 11-pin J2 header and the DB-25 pigtail footprint,
pairing button, address DIP, USB-C. It cannot be powered from J2-10 (+12 V
through 10 ohm drops 1 V at 100 mA and is a sense line, so the rule of 1.5
stands: never a supply); it takes +5 V from the cabinet's P1 or a wall
adapter. Note for later: the original main board's
link-present sense on J2-11 means a real cabinet with a bridge plugged in
sees "cable present" even while the far end is away.

**The MiSTer's own Wi-Fi** (needed regardless: no cable reaches the
cabinet's spot). The ESP32 cannot provide it (above). Dongle guidance,
from the MiSTer docs, the MiSTer Bible, the forum's recommended-dongle
thread, and the drivers built into the MiSTer-v6.18 kernel config:

- The kernel builds, as modules, Realtek rtl8192cu, rtl8192du, rtl8187,
  the generic rtl8xxxu, rtw88 with USB front-ends for 8723DU, 8811/8821AU,
  8812/8822BU, 8821CU, 8822CU, 8814AU and 8812AU, and rtw89 for 8851BU and
  8852BU; MediaTek mt7601u and mt7663u; Ralink rt2800usb; Atheros
  ath9k_htc, ath10k USB, carl9170; Broadcom brcmfmac USB; Marvell mwifiex
  USB. Realtek 8192EU falls to the generic rtl8xxxu driver and is slow.
- Named as working by the docs or the Bible: ASUS USB-AC53 Nano rev A1
  (RTL8822BU, 5 GHz), Edimax EW-7822ULC (USB ID 7392:b822, RTL8822BU, 5
  GHz), TP-Link Archer T3U (RTL8812BU, 5 GHz), TP-Link Archer T2U nano and
  Netgear A6100 (RTL8811AU, 5 GHz), Netgear A6150, D-Link DWA-181, D-Link
  DWA-171 rev A1 only (rev C1, USB ID 0bda:1a2b, enumerates as a CD-ROM
  first and is reported not to work out of the box), Edimax EW-7811UN
  (7392:7811, RTL8188CUS, 2.4 GHz only), Edimax EW-7612UAn v2 (RTL8192CU),
  CanaKit Raspberry Pi dongle (148f:5370, rt2800usb, 2.4 GHz only),
  TP-Link TL-WN823N v2 (RTL8192EU, needs `rtl8192eu_nic.bin` copied to
  `/lib/firmware/rtlwifi`, slow) and v3.
- Forum experience: rtl8192cu and mt7601u sticks are the ones people call
  rock solid; combo Wi-Fi+Bluetooth sticks (RTL8821CU) work for some and
  misbehave for others, and the Bible wants Bluetooth on its own dongle;
  throughput is a few MB/s whatever the chipset, which is fine for
  updates; hardware revisions change chipsets, so check `lsusb` before
  trusting a model name.
- Recommendation for this cabinet: a 5 GHz-capable RTL8822BU/8812BU or
  RTL8811AU stick (ASUS USB-AC53 Nano A1, Edimax EW-7822ULC, Archer T3U or
  T2U nano) on the MiSTer's hub, joined to the 5 GHz SSID, Bluetooth on a
  separate dongle if ever needed. Verification: `lsusb` and `dmesg | grep
  -iE "rtw|usbcore"` on the MiSTer after plugging it in (ask before using
  10.0.1.80).

Sources: MiSTer docs "WiFi" (mister-devel.github.io/MkDocs_MiSTer/basics/
wifi/), MiSTer Bible "WiFi setup" (boogermann.github.io/Bible_MiSTer/
getting-started/network/wifi-setup/), forum thread "Recommended WiFi
Dongles" (misterfpga.org/viewtopic.php?t=407), MiSTer kernel
`arch/arm/configs/MiSTer_defconfig` on branch MiSTer-v6.18 (read
2026-10-28), Espressif ESP-NOW documentation (ESP-IDF API guide).

## 4. Changes to the link protocol and `rd_cabinet_io.sv`

Today's protocol (docs/cabinet-io.md) already carries every input the game
reads except the compact encoder count and the cockpit's shift-force
channel, and every output except the shifter latches. Proposed version 2:

### 4.1 Input frame (board to core), 26 to 29 bytes

- Bits 13-14 of the switch word: cabinet type as set by the board's DIP (00
  unknown, 01 cockpit, 10 compact). The core uses it to pick the compact
  scaling and port-1 semantics instead of a build-time guess, and shows it
  in the OSD.
- Bit 15: encoder valid (compact, when the count travels in frames).
- New byte 25: shift force, 8 bits (STRAINOA/B through the ADC), so a
  Hard Drivin' build can use ADC channel 7; Race Drivin' ignores it.
- New bytes 26-27: compact encoder count, 16 bits, free-running, plus the
  index flag in bit 15 of the switch word above. The core turns it into the
  8-bit modulo-256 counter at 0x400000 and the centre-edge latch the game
  reads, replacing the `steering` slew model when the board is the source.
  If the bench measurement keeps the encoder on USER_IO[2..4], these bytes
  stay reserved and `RaceDrivin.sv` gains a quadrature decoder on those
  pins (today only USER_IN[1] is used).
- CRC moves to byte 28.

### 4.2 Output frame (core to board), 16 to 21 bytes

- Byte 3, the force byte, changes meaning: bits 0-4 are the five-bit code
  the amp would have latched, captured by the core on the write where the
  strobe bits rise (section 4.3), bit 7 is set when at least one such
  strobe happened since the previous frame, bits 5-6 are 0. The board
  regenerates the strobe (section 3.7). Today's raw copy of the latch would
  alias against the game's 244 Hz strobe and hand the amp the 0xE0/0x00
  return writes half the time.
- New bytes 15-18: SEL1..SEL4 data, the last value written to the shifter
  interface latch while that SEL was selected (only SEL3 is used by Race
  Drivin', section 1.3; all four cost nothing).
- New byte 19: bit n set when SELn was pulsed since the previous frame, so
  the board can reproduce the pulse even when the value repeats.
- Bit 5 of the outputs byte: force enable (the core clears it while the
  board reports the wrong cabinet type or during the first second after
  reset), so the board holds the zero-torque code.
- CRC moves to byte 20. 105 us at 2 Mbaud; still comfortably inside the 1
  ms frame.

### 4.3 Core-side changes

- `rtl/harddrivin_main_bus.sv` lines 452-468 capture the coin counters and
  the force byte. Change the force capture to latch bits 12:8 of the write
  when bit 15 (or 13 or 14; they move together) goes from 0 to 1 relative
  to the previous write, and set a strobe-seen flag the link clears per
  frame. Add: wr0 functions 1-4 select a SEL register, writes to 0xA80000
  (upper byte) load it, and a per-SEL pulsed flag set when the function's
  value goes 0 then 1. MAME's `hd68k_wr0_write`/`hd68k_wr1_write` are the
  model; the trace in 1.3 and 1.4 is the timing reference.
- `rtl/io/rd_cabinet_io.sv`: frame lengths, the new fields, the cabinet-type
  and encoder outputs; `sim/models/sim_cabinet_io.sv` and `sim/tb_cabio.sv`
  updated to match; `docs/cabinet-io.md` rewritten as version 2 with a
  version byte so the board and core can detect a mismatch.
- `RaceDrivin.sv`: route the cabinet-type field into the compact/cockpit
  input muxes; add the force-enable gate; optionally the quadrature decoder
  on USER_IN[2..4].

The MAME oracle run behind these findings: `SDL_VIDEODRIVER=dummy RD_OUT=1
RD_LOG=<prefix> ~/Developer/mame/hd racedriv -autoboot_script mame/
oracle.lua ...` with a calibrated NVRAM copy, 150 s of attract mode and 75
s of `mame/play.lua`; the logs are not kept in the repository (they contain
nothing but timestamps and latch values and are reproducible in two
minutes).

## 5. Open questions, each with what settles it

1. **Compact J4 "SW A", J5 pins 1-6, J13: which carries the four gear
   switches, the encoder A/B, the centring index?** Settled by the SP-338
   drawing's connector sheet (the user has the package), or by unplugging
   the compact harness and ohming each plug's wires back to the gear
   switches and the two opto PCBs.
2. **Compact encoder electrical details:** pinout of the two 4-circuit
   .156" plugs, output type (open collector or with pull-up), count per
   revolution. Settled with the compact powered on the original board: scope
   the A/B outputs while turning the wheel one revolution, count edges,
   check the index pulse width at centre.
3. **Compact force brake:** where the strain gauge is amplified (the
   A046640-01 motor amp carries an ADOP07; the APU does not) and on which
   main-board pin the amplified signal arrives, released and full-pressure
   voltages. Settled by tracing the brake harness and measuring at the
   main board with the game on the Control Inputs self-test screen (0xF0
   released, 0x20 full).
4. **Force byte format on the amps:** confirm four torque bits plus a
   direction bit (section 1.4), which direction D4 = 1 turns the wheel,
   that code 0x00 is zero torque, the strobe hold time the 74HC14 chain
   needs, and which OPT1 pair each of the user's amps has jumpered (so the
   compact amp, if it differs, is caught). Settled by a photograph of each
   amp's OPT1 and one bench run of a cockpit amp with its motor, driven
   through J6 from the breadboard replaying the game's four-write sequence
   with chosen codes (mains-fed amp: isolation transformer, driver PCBs
   covered, hands off).
5. **Cockpit wheel-pot supply and pot value:** the schematic feeds J11-1..3
   from +15 V through 91 ohm, the wiring diagram says +5 V. Settled by a
   voltmeter on J11-3 and an ohmmeter across the 10-turn pot with the
   original board; decides nothing electrically (ratiometric at 5 V) but
   confirms the pot survives 5 V excitation and that its wiper travel fits
   0x010-0xFF0 after calibration.
6. **Brake SGA span:** voltage at J11-6 released and at full pedal force.
   Settled with a voltmeter on the cockpit; sets the divider in 3.4.
7. **LC1/LC2/CC drive requirements:** open-circuit voltage at J6-10, J6-11,
   J6-6, J6-7 and the current when the original board sinks them (seat lock
   engaging, abort lamp on, counter pulse). Settled with a meter on a
   cockpit and on the compact; sets the output transistors in 3.9.
8. **Shifter latch use: answered.** Race Drivin' writes the latch and pulses
   SEL3 at 244 Hz (section 1.3). Still open: what the 0xB9 value does on
   the shifter PCB (the coil's PWM duty and whether the player feels it),
   settled on the bench in build step 5 by watching the coil current while
   the breadboard replays data 0xB9 with a SEL3 pulse.
9. **Link latency tolerance** (PLAN.md 3.2): decides whether serial A can
   go over the air at all and sets the de-jitter depth of 3.12. Settled by
   the two-instance MAME link with an inserted delay, swept from 1 to 20
   ms with 1 ms of jitter and 0.1 % byte loss, noting where LINKED GAME
   degrades and where it drops; then confirmed on two ESP32 dev modules
   over ESP-NOW with a counter loopback (round trip measured on a scope
   from TX edge to re-serialised RX edge).
10. **I/O board revision and user-port pin map in the cabinet's MiSTer:**
    continuity from the USB 3.0 socket to the GPIO_1 header against the
    I/O board schematic; whether the IO6 jumper exists. Settled with a
    meter on the I/O board (not on the shared MiSTer at 10.0.1.80 without
    asking).
11. **Shifter PCB jumpers on the user's cockpits:** JP1/JP2/JP3 positions
    (which SEL clocks which latch; whether the strain amp feeds A or B).
    Settled by a photograph of each shifter PCB.
12. **Harness connector housings:** confirm the 11-pin plugs are Molex KK
    .100" with a plugged key position, the ribbon plugs are standard 2.54
    mm IDC with polarising bump, and P1 is a .250" (6.35 mm) 12-way. Settled
    with photographs and a caliper on one cockpit and the compact.
13. **Coin door lamps** are on +5 V AC from the transformer, not from the
    main board (SP-327 sheet 15): confirm the compact's door is wired the
    same, so no lamp supply is expected from this board.
14. **Cabinet board outline:** whether the new board should match the
    A045988/A046901 outline and standoffs or mount beside the MiSTer.
    Settled by measuring the board tray.
15. **Cockpit amp and motor for the fallback driver:** motor voltage and
    stall current if a modern driver is ever fitted. Settled by measuring
    the motor's resistance and the amp's rails.

## 6. Build order

1. **Paper work (now):** settle items 1, 4 (OPT1 photographs), 8, 11, 12,
   13 from drawings and photographs; schedule the cabinet measurements (2,
   3, 5, 6, 7, 10, 14) for one visit each to a cockpit and to the compact.
2. **Protocol version 2 in simulation:** docs/cabinet-io.md v2,
   `rd_cabinet_io.sv`, `sim_cabinet_io.sv`, `tb_cabio.sv`, the main-bus SEL
   capture, a sim run of the self-test's Control Inputs screen through the
   model. No hardware needed; this is the one RTL task and it can start
   immediately.
3. **Breadboard link prototype:** ESP32-S3 dev module, an MCP3208 breakout,
   a 74HCT244 and a 74LVC541 on a breadboard, a cut USB 3.0 A-to-A cable
   into a spare I/O board's user port (not the shared MiSTer). Firmware
   speaks v2; pots and switches on the breadboard. Done when the core's
   OSD "Inputs: Cabinet board" plays the attract mode and a game from the
   breadboard controls with zero CRC drops over an hour and a measured
   input-to-core latency under 2 ms.
4. **Force path on the bench:** the breadboard's J15 lines into a logic
   analyser to check the regenerated strobe sequence, then into one cockpit
   amp with its motor (isolation transformer, driver PCBs under a cover).
   Verify that code 0x00 gives no torque, that the link-loss watchdog
   drops to it, that D4 selects the direction and D0-D3 the torque, and
   that a scripted force ramp from the core moves the wheel the expected
   way. Record OPT1 and the measured code-to-torque map for the F2
   fallback.
5. **Shifter PCB on the bench:** J14 ribbon from the breadboard; read X/Y
   and strain through the ADC; replay the game's data-then-SEL3-pulse
   sequence with 0x00 and 0xB9 and watch the clutch coil and the DAC output
   respond.
6. **First cockpit trial, no PCB yet:** original main board out, breadboard
   plus pigtails on J5, J6, J9, J11, J14, J15, J2; monitor and sound from
   the analog I/O board. Play through calibration, a race and a linked-game
   menu check. This is the gate for layout.
7. **Compact trial:** encoder path decision (frames versus USER_IO[2..4],
   from the measured latency and the 0x400000 counter behaviour in the
   self-test), gear switches, brake, the compact amp through J15.
8. **KiCad rev A:** everything in section 3, five boards (four cockpits and
   the compact) plus two spares. Bring-up on the bench, then one cockpit,
   then the compact. Rev B carries the fixes.
9. **Later (PLAN.md M8):** the ESP-NOW link of 3.12 between two boards,
   then the real-hardware bridge board, then LAN UDP; the pod stream rides
   the same frames; the fallback H-bridge for a cabinet with a dead amp.
