# Cabinet I/O board protocol

The cabinet board (ESP32-S3, PLAN.md section 3.2) carries every cabinet
electrical interface and talks to the core over one full-duplex UART on the
MiSTer user port: `USER_OUT[0]` core to board, `USER_IN[1]` board to core,
2,000,000 baud, 8N1. The core side is `rtl/io/rd_cabinet_io.sv`; the board
side is the ESP32 firmware (separate repository, to come). `sim/models/
sim_cabinet_io.sv` is a model of the board for simulation and
`sim/tb_cabio.sv` checks both directions through a real MC68681 instance.

Both directions use the same framing: a sync byte, a type byte, a sequence
byte, the payload, and a CRC-8 (polynomial 0x07, initial value 0x00, over
every byte after the sync). A receiver drops a frame whose type it does not
know or whose CRC fails, and resynchronises on the next sync byte. Multi-byte
values are little-endian.

## Board to core: input frame, type 0x10, every 1 ms

| Byte | Content |
|---|---|
| 0 | 0xA5 sync |
| 1 | 0x10 |
| 2 | sequence, increments per frame |
| 3-4 | switches, 1 = active (pressed, closed, present): bit 0 coin 1, 1 coin 2, 2 aux coin, 3 self-test, 4 key, 5 abort, 6 DIAGN jumper (1 = jumper fitted = diagnostics on), 7 link A present, 8 link B present, 9-12 compact gear switches 1-4, 13-15 reserved 0 |
| 5-6 | wheel, 12 bits, 0 to 4095 (cockpit pot; the compact's encoder goes to `USER_IN[2..4]` directly) |
| 7-8 | brake, 12 bits, 0 to 4095, 0 released (cockpit pot) |
| 9 | gas, 8 bits, 0 released |
| 10 | clutch, 8 bits, 0 released |
| 11 | seat, 8 bits |
| 12 | shifter X, 8 bits |
| 13 | shifter Y, 8 bits |
| 14 | compact brake transducer, 8 bits as the ADC0809 reads it (0xF0 released, 0x20 full) |
| 15 | serial A received byte count, 0 to 4 |
| 16 | serial B received byte count, 0 to 4 |
| 17-20 | serial A received bytes |
| 21-24 | serial B received bytes |
| 25 | CRC-8 over bytes 1 to 24 |

26 bytes, 130 us at 2 Mbaud. At 38,400 baud a serial channel delivers at
most 3.84 bytes per millisecond, so four slots per frame never fall behind;
unused slots are 0.

The core scales the analog values to what the game expects: the cockpit's
wheel pot becomes the 12-bit ADC reading (0x010 to 0xFF0 by the game's own
calibration) and its 8-bit copy on ADC0809 channel 5; the brake pot becomes
the 12-bit ADC's reading with 0xFFF released; the 8-bit pots go straight to
the ADC0809 channels.

## Core to board: output frame, type 0x20, in reply to every input frame

| Byte | Content |
|---|---|
| 0 | 0xA5 sync |
| 1 | 0x20 |
| 2 | sequence of the input frame being answered |
| 3 | force byte, the game's write to 0xB00000 (wheel motor command) |
| 4 | outputs, 1 = on: bit 0 seat-lock lamp, 1 abort lamp, 2 coin counter 1, 3 coin counter 2, 4 DSK LED, 5-7 reserved |
| 5 | serial A bytes to transmit, 0 to 4 |
| 6 | serial B bytes to transmit, 0 to 4 |
| 7-10 | serial A bytes |
| 11-14 | serial B bytes |
| 15 | CRC-8 over bytes 1 to 14 |

16 bytes, 80 us. The outputs are levels sampled when the frame is built;
coin-counter pulses from the game last tens of milliseconds, so a 1 kHz
sample never misses one.

## Serial channels

The MC68681's two channels stay serial lines inside the core. Bytes the
board received on RS-232 (or over Wi-Fi) arrive in input frames and are
re-serialised onto the DUART's RX pins at the rate the game programmed in
the DUART (the core reads the DUART's receive rate, 38,400 baud in Race
Drivin'); bytes the DUART transmits are received from its TX pins at the
programmed rate and go out in output frames. A 16-byte FIFO per direction
and channel absorbs frame timing.

## Core-side signals

`rd_cabinet_io` presents the same input signals the USB mapping presents to
`harddrivin_milestone` (switches, 12-bit wheel and brake, the 8-bit pots),
plus `link_present_a/b` and the serial pins, and takes the force byte, the
control-latch lamp bits, the coin-counter levels and the DSK LED. An OSD
option selects USB or cabinet inputs. When no valid input frame has arrived
for 50 ms the inputs fall back to their released values and `board_ok_o`
drops, so a disconnected board does not leave a pedal pressed.
