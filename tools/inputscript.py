#!/usr/bin/env python3
"""Write a cabinet input script that MAME (mame/inputs.lua) and the sim
(sim/tb_core.sv +inputs=) both replay, so the two machines get identical
inputs at identical machine times.

    tools/inputscript.py play > inputs/play.txt      # coin, Key, drive with a steering weave
    tools/inputscript.py selftest > inputs/selftest.txt

Format: one event per line, "time_s control value", with the value being
what the 68010 reads from the port (MAME's ioport value):
  coin1 coin2 auxcoin service key abort   1 pressed, 0 released
  gas clutch seat shx shy                 0-255, the 8-bit ADC channel value
  wheel                                   16-4080 (0x010-0xff0), the 12-bit ADC;
                                          the 8-bit copy on ADC channel 5 is derived
  brake                                   0-4095 as the 12-bit ADC reads it (4095 released)
Continuous motions are written as sampled events, one per video frame.
"""
import math
import sys

FRAME = 1.0 / 59.92            # Hard Drivin' video frame


def press(t, name, hold=0.4):
    return [(t, name, 1), (t + hold, name, 0)]


def play(t0=9.0, end=40.0):
    ev = []
    ev += press(t0, "coin1")
    ev += press(t0 + 2.0, "key")
    ev += press(t0 + 4.5, "key")
    ev += press(t0 + 7.0, "key")
    ev += [(t0 + 8.0, "shx", 0x20), (t0 + 8.0, "shy", 0x20), (t0 + 8.0, "gas", 0xff)]
    t = t0 + 8.0
    while t < end:
        ev.append((t, "wheel", 0x800 + int(0x180 * math.sin(t * 2 * math.pi / 4))))
        t += FRAME
    return ev


def selftest():
    return [(0.0, "service", 1)]


def main():
    kind = sys.argv[1] if len(sys.argv) > 1 else "play"
    ev = {"play": play, "selftest": selftest}[kind]()
    ev.sort(key=lambda e: e[0])
    print(f"# cabinet inputs: {kind}")
    for t, name, v in ev:
        print(f"{t:.6f} {name} {v}")


if __name__ == "__main__":
    main()
