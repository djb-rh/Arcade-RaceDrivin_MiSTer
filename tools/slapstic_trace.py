#!/usr/bin/env python3
"""Replay a sim 68010 bus trace through a model of the 137412-117 slapstic.

    tools/slapstic_trace.py sim/build/run/trace.txt

Prints every state-machine event (arm, direct switch, alternate/additive
sequence steps, commits) with the sim time and address, following MAME's
src/mame/atari/slapstic.cpp for the 111-118 class exactly as
rtl/slapstic/harddrivin_slapstic.sv does. Useful to see which bank the core
should be presenting at a given moment, and to compare the event sequence
with MAME's own (`hd ... -log`, then grep slapstic error.log).
"""
import sys
RANGE_MASK, RANGE_VAL = ~0x1FFFF & 0xFFFFFF, 0xE0000
IN_MASK = 0x3FFF << 1
BANKS = [0x0008, 0x001a, 0x002c, 0x003e]
alt1=(0x007f,0x007d); alt2=(0x3fff,0x3580); alt3=(0x0079,0x0020); alt4=(0x3fc9,0x0008)
add1=(0x3fff,0x0676); add2=(0x3fff,0x0677); addp1=(0x3e62,0x1a42); addp2=(0x3e35,0x1a11); add3=(0x3fff,0x1a42)
def t_in(a, mv): return (a & (RANGE_MASK | (mv[0] << 1))) == (RANGE_VAL | (mv[1] << 1))
def t_any(a, mv): return (a & (mv[0] << 1)) == (mv[1] << 1)
def t_reset(a): return (a & (RANGE_MASK | IN_MASK)) == RANGE_VAL
def t_bank(a, b): return (a & (RANGE_MASK | IN_MASK)) == (RANGE_VAL | (BANKS[b] << 1))
state, cur, loaded = "IDLE", 0, 0
events = []
with open(sys.argv[1]) as f:
    for line in f:
        if line[0] == "#": continue
        t, kind, addr, *_ = line.split()
        a = int(addr, 16)
        if a < 0xE0000 and state == "IDLE": continue
        ts = int(t) / 1e12
        if state == "IDLE":
            if t_reset(a): state = "ACTIVE"; events.append((ts, "reset", addr))
        elif state == "ACTIVE":
            for b in range(4):
                if t_bank(a, b): cur = b; state = "IDLE"; events.append((ts, f"direct bank {b}", addr)); break
            else:
                if t_any(a, alt1): state = "ALT_VALID"; events.append((ts, "alt start", addr))
                elif t_in(a, add1): state = "ADD_LOAD"; events.append((ts, "add start", addr))
        elif state == "ALT_VALID":
            if t_reset(a): state = "ACTIVE"; events.append((ts, "reset", addr))
            elif t_in(a, alt2): state = "ALT_SELECT"; events.append((ts, "alt valid", addr))
            elif t_in(a, add1): state = "ADD_LOAD"; events.append((ts, "alt->add", addr))
            else: state = "ACTIVE"; events.append((ts, "alt break@valid", addr))
        elif state == "ALT_SELECT":
            if t_reset(a): state = "ACTIVE"; events.append((ts, "reset", addr))
            elif t_any(a, alt3): loaded = (a >> 2) & 3; state = "ALT_COMMIT"; events.append((ts, f"alt select {loaded}", addr))
            else: state = "ACTIVE"; events.append((ts, "alt break@select", addr))
        elif state == "ALT_COMMIT":
            if t_reset(a): state = "ACTIVE"; events.append((ts, "reset", addr))
            elif t_in(a, alt4): cur = loaded; state = "IDLE"; events.append((ts, f"COMMIT bank {cur}", addr))
        elif state == "ADD_LOAD":
            if t_reset(a): state = "ACTIVE"; events.append((ts, "reset", addr))
            elif t_in(a, add2): loaded = cur; state = "ADD_SET"; events.append((ts, "add load", addr))
            else: state = "ACTIVE"; events.append((ts, "add break", addr))
        elif state == "ADD_SET":
            if t_reset(a): state = "ACTIVE"; events.append((ts, "reset", addr))
            elif t_in(a, addp1): loaded = (loaded + 1) & 3; events.append((ts, "add +1", addr))
            elif t_in(a, addp2): loaded = (loaded + 2) & 3; events.append((ts, "add +2", addr))
            elif t_in(a, add3): state = "ALT_COMMIT"; events.append((ts, "add end", addr))
print(len(events), "events")
for ts, ev, addr in events[:60]:
    print(f"  {ts:9.6f} {ev:18s} {addr}")
