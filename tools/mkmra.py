#!/usr/bin/env python3
"""Generate MiSTer MRA files for the Hard/Race Drivin' cores from MAME's ROM facts.

    tools/mkmra.py harddriv-cockpit  -o "releases/Hard Drivin' (Cockpit, rev 7).mra"
    tools/mkmra.py racedriv-cockpit  --slapstic-free -o releases/...
    tools/mkmra.py racedrivc-compact -o releases/...

A layout says which MAME ROM regions go into which MiSTer download index, at
which byte offset inside that index, and how much space each region is given
(gaps are filled with 0xFF). 16-bit regions are detected from MAME's even/odd
ROM offsets and emitted as interleaved pairs; the even ROM (big-endian high
byte) gets map="01" and the odd ROM map="10", matching the Hard Drivin' core.

With --slapstic-free the CRC attribute is omitted for the four program ROMs
that slapfree.py rewrites, so the MRA accepts the patched set (same file
names, produced by `slapfree.py --mame-set` or `rdtrack.stockcar`).
"""
import argparse
import json
import sys
from pathlib import Path

DATA = Path(__file__).resolve().parent / "data" / "machines.json"

DIPS = """  <switches default="FF 01">
    <dip bits="0" name="SW1:8" ids="On,Off"/>
    <dip bits="1" name="SW1:7" ids="On,Off"/>
    <dip bits="2" name="SW1:6" ids="On,Off"/>
    <dip bits="3" name="SW1:5" ids="On,Off"/>
    <dip bits="4" name="SW1:4" ids="On,Off"/>
    <dip bits="5" name="SW1:3" ids="On,Off"/>
    <dip bits="6" name="SW1:2" ids="On,Off"/>
    <dip bits="7" name="SW1:1" ids="On,Off"/>
    <dip bits="8" name="Diagnostic jumper" ids="On,Off"/>
  </switches>
"""

BUTTONS = ('  <buttons default="A,B,X,Y,L,R,Start,Select" '
           'names="Gas,Brake,Clutch,Abort,Gear Down,Gear Up,Key,Coin,Gear 1,Gear 2,Gear 3,Gear 4"/>\n')

# Each layout: MRA header fields and a list of download indexes. An index is
# (index, ddr_address or None, [(region, offset_in_index, allotted_size or None)]).
# Allotted size None means "exactly the ROMs present, no trailing fill".
#
# The DDR map shared by the Hard Drivin' core and this one:
#   0x000000 main 68010 program (1 MiB)
#   0x100000 ADSP sequential object ROMs (up to 0x50000)
#   0x150000 sound sample ROMs (up to 0x50000; Hard Drivin' uses 4, Race Drivin' 5)
#   0x1A0000 DSK track ROM (Race Drivin' only; 0x40000 reserved, stock sets use 0x20000)
# Index 1 is the sound 68000 program ROM (BRAM), index 2 is the 8 KiB NVRAM
# save file (main-board zero RAM, then the DSK board's), index 3 is the 200E/210E power-up ZRAM image
# interleaved as the 68010 sees it (200E = high byte, 210E = low byte).
LAYOUTS = {
    "harddriv-cockpit": {
        "setname": "harddriv", "rbf": "HardDrivin_cockpit", "zip": "harddriv.zip",
        "name": "Hard Drivin' (Cockpit, rev 7)", "year": "1989",  # as the upstream MRA states it
        "indexes": [
            (0, 0x30000000, [("mainpcb:maincpu", 0x000000, 0x100000),
                             ("mainpcb:user1", 0x100000, 0x50000),
                             ("mainpcb:harddriv_sound:serialroms", 0x150000, None)]),
            (1, None, [("mainpcb:harddriv_sound:soundcpu", 0, None)]),
            (3, None, [("mainpcb:200e+mainpcb:210e", 0, None)]),
        ],
        "nvram": (2, 8192),
        "remark": ("Uses stock MiSTer Main. Default gamepad controls: left-stick steering, right-stick up for "
                   "gas and down for brake, mapped Clutch, Gear Down/Up, Key and Coin. Pedals: Buttons disables "
                   "stick pedals and uses mapped Gas/Brake buttons. Gearbox: H-pattern uses maintained Gear 1-4 "
                   "buttons and neutral when released. Wheel mode uses MiSTer's standard wheel axes. "
                   "Calibration remains user-driven."),
    },
    "racedriv-cockpit": {
        "setname": "racedriv", "rbf": "RaceDrivin_cockpit", "zip": "racedriv.zip",
        "name": "Race Drivin' (Cockpit, rev 5)",
        "indexes": [
            (0, 0x30000000, [("mainpcb:maincpu", 0x000000, 0x100000),
                             ("mainpcb:user1", 0x100000, 0x50000),
                             ("mainpcb:harddriv_sound:serialroms", 0x150000, 0x50000),
                             ("mainpcb:user3", 0x1A0000, 0x40000)]),
            (1, None, [("mainpcb:harddriv_sound:soundcpu", 0, None)]),
            (3, None, [("mainpcb:200e+mainpcb:210e", 0, None)]),
        ],
        "nvram": (2, 8192),
        "remark": "Work in progress. See PLAN.md in the project repository.",
    },
    "racedrivc-compact": {
        "setname": "racedrivc", "rbf": "RaceDrivin_compact", "zip": "racedrivc.zip",
        "name": "Race Drivin' (Compact, rev 5)",
        "indexes": [
            (0, 0x30000000, [("mainpcb:maincpu", 0x000000, 0x100000),
                             ("mainpcb:user1", 0x100000, 0x50000),
                             ("mainpcb:harddriv_sound:serialroms", 0x150000, 0x50000),
                             ("mainpcb:user3", 0x1A0000, 0x40000)]),
            (1, None, [("mainpcb:harddriv_sound:soundcpu", 0, None)]),
            (3, None, [("mainpcb:200e+mainpcb:210e", 0, None)]),
        ],
        "nvram": (2, 8192),
        "remark": "Work in progress. See PLAN.md in the project repository.",
    },
}

# Program ROM pairs rewritten by slapfree.py (region offsets).
SLAPSTIC_FREE_PATCHED = {("mainpcb:maincpu", 0x00000), ("mainpcb:maincpu", 0x00001),
                         ("mainpcb:maincpu", 0x20000), ("mainpcb:maincpu", 0x20001)}


def region_roms(machine, region):
    """ROMs of a region sorted by offset. 'a+b' merges two 8-bit regions as a 16-bit pair."""
    if "+" in region:
        hi, lo = region.split("+")
        roms = []
        for r in machine["roms"]:
            if r["region"] == hi:
                roms.append(dict(r, offset=r["offset"] * 2))
            elif r["region"] == lo:
                roms.append(dict(r, offset=r["offset"] * 2 + 1))
        return sorted(roms, key=lambda r: r["offset"])
    return sorted((r for r in machine["roms"] if r["region"] == region and r["status"] != "nodump"),
                  key=lambda r: r["offset"])


def part(rom, zipname, slapstic_free, indent):
    crc = ""
    if not (slapstic_free and (rom["region"], rom["offset"]) in SLAPSTIC_FREE_PATCHED):
        crc = f' crc="{rom["crc"]}"'
    return f'{indent}<part name="{rom["name"]}"{crc}{zipname}'


def emit_region(machine, region, allotted, zipname, slapstic_free, out):
    roms = region_roms(machine, region)
    pos = 0
    i = 0
    while i < len(roms):
        rom = roms[i]
        pair = roms[i + 1] if i + 1 < len(roms) else None
        is_pair = (pair is not None and rom["offset"] % 2 == 0 and pair["offset"] == rom["offset"] + 1
                   and pair["size"] == rom["size"])
        start = rom["offset"] & ~1 if is_pair else rom["offset"]
        if start > pos:
            out.append(f'    <part repeat="0x{start - pos:X}">ff</part>')
        if is_pair:
            out.append('    <interleave output="16">')
            out.append(part(rom, zipname, slapstic_free, "      ") + ' map="01"/>')
            out.append(part(pair, zipname, slapstic_free, "      ") + ' map="10"/>')
            out.append('    </interleave>')
            pos = start + rom["size"] * 2
            i += 2
        else:
            out.append(part(rom, zipname, slapstic_free, "    ") + "/>")
            pos = start + rom["size"]
            i += 1
    if allotted is not None:
        if pos > allotted:
            raise SystemExit(f"{region}: ROMs ({pos:#x}) exceed allotted {allotted:#x}")
        if allotted > pos:
            out.append(f'    <part repeat="0x{allotted - pos:X}">ff</part>')
        pos = allotted
    return pos


def build(layout_name, slapstic_free):
    layout = LAYOUTS[layout_name]
    machines = json.loads(DATA.read_text())
    machine = machines[layout["setname"]]
    name = layout["name"] + (" (slapstic-free)" if slapstic_free else "")
    out = ["<misterromdescription>",
           f"  <name>{name}</name>",
           f"  <setname>{layout['setname']}</setname>",
           f"  <year>{layout.get('year', machine['year'])}</year>",
           f"  <manufacturer>{machine['manufacturer']}</manufacturer>",
           "  <category>Racing</category>",
           f"  <rbf>{layout['rbf']}</rbf>",
           "  <rotation>horizontal</rotation>",
           BUTTONS.rstrip("\n"), DIPS.rstrip("\n")]
    for index, address, regions in layout["indexes"]:
        addr = f' address="0x{address:08X}"' if address is not None else ""
        out.append(f'  <rom index="{index}"{addr} zip="{layout["zip"]}" md5="none">')
        pos = 0
        for region, offset, allotted in regions:
            if offset > pos:
                out.append(f'    <part repeat="0x{offset - pos:X}">ff</part>')
            elif offset < pos:
                raise SystemExit(f"{region} offset {offset:#x} overlaps previous region end {pos:#x}")
            pos = offset + emit_region(machine, region, allotted, "", slapstic_free, out)
        out.append("  </rom>")
    idx, size = layout["nvram"]
    out.append(f'  <nvram index="{idx}" size="{size}"/>')
    out.append("")
    out.append(f"  <remark>{layout['remark']}</remark>")
    out.append("</misterromdescription>")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("layout", choices=sorted(LAYOUTS))
    ap.add_argument("--slapstic-free", action="store_true")
    ap.add_argument("-o", "--out", type=Path)
    args = ap.parse_args()
    text = build(args.layout, args.slapstic_free)
    if args.out:
        args.out.write_text(text)
        print(f"wrote {args.out}")
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
