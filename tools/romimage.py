#!/usr/bin/env python3
"""Build the simulation memory images for one core layout from a MAME ROM set.

    tools/romimage.py racedriv-cockpit ~/roms/racedriv.zip -o sim/build/roms/racedriv

Produces, in the output directory (which must be outside the repository or
under the gitignored sim/build/):

    ddr.bin        exactly the bytes MiSTer would write to DDR at 0x30000000
                   for MRA download index 0 (same layout as tools/mkmra.py)
    index1.bin     sound 68000 EPROM pair, interleaved as MAME lays it out
    zram_hi.hex    200E contents, one byte per line (power-up zero RAM, high lane)
    zram_lo.hex    210E contents, one byte per line (low lane)
    dips.bin       2 bytes: SW1 (0xFF = all off) and the DIAGN jumper (0x01 = off)
    manifest.txt   what went where

The set may be a zip or a directory of loose files; a parent set may be given
with --parent for clones. With --slapstic-free the R/S program ROM pairs are
accepted with any CRC (names must still match). ROM data never enters the
repository; this tool only reads the user's own set.
"""
import argparse
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mkmra  # noqa: E402  (layouts, machine data, region helpers)
from romset import Source, SLAPSTIC_FREE_PATCHED  # noqa: E402


def read_rom(sources, rom, slapstic_free):
    for src in sources:
        data = src.read(rom["name"])
        if data is not None:
            break
    else:
        raise SystemExit(f"missing ROM {rom['name']} ({rom['region']})")
    if len(data) != rom["size"]:
        raise SystemExit(f"{rom['name']}: size {len(data)} != {rom['size']}")
    crc = f"{zlib.crc32(data) & 0xffffffff:08x}"
    if crc != rom["crc"]:
        if slapstic_free and (rom["region"], rom["offset"]) in SLAPSTIC_FREE_PATCHED:
            pass
        else:
            raise SystemExit(f"{rom['name']}: CRC {crc} != {rom['crc']} (use --slapstic-free for patched sets)")
    return data


def build_region(machine, region, allotted, sources, slapstic_free, manifest):
    """Bytes of a region laid out as MAME does (even/odd ROMs interleaved), 0xFF filled."""
    roms = mkmra.region_roms(machine, region)
    end = allotted if allotted is not None else 0
    for r in roms:
        is_odd_half = (r["offset"] % 2 == 1)
        rom_end = (r["offset"] & ~1) + r["size"] * 2 if (
            any(o["offset"] == (r["offset"] ^ 1) and o["size"] == r["size"] for o in roms)) else r["offset"] + r["size"]
        end = max(end, rom_end)
    image = bytearray(b"\xff" * end)
    i = 0
    while i < len(roms):
        rom = roms[i]
        pair = roms[i + 1] if i + 1 < len(roms) else None
        is_pair = (pair is not None and rom["offset"] % 2 == 0 and pair["offset"] == rom["offset"] + 1
                   and pair["size"] == rom["size"])
        if is_pair:
            even = read_rom(sources, rom, slapstic_free)
            odd = read_rom(sources, pair, slapstic_free)
            base = rom["offset"] & ~1
            image[base:base + 2 * rom["size"]:2] = even
            image[base + 1:base + 2 * rom["size"]:2] = odd
            manifest.append(f"  {region} +{base:06x} {rom['name']} (even) / {pair['name']} (odd) {rom['size'] * 2:#x} bytes")
            i += 2
        else:
            data = read_rom(sources, rom, slapstic_free)
            image[rom["offset"]:rom["offset"] + rom["size"]] = data
            manifest.append(f"  {region} +{rom['offset']:06x} {rom['name']} {rom['size']:#x} bytes")
            i += 1
    if allotted is not None and len(image) > allotted:
        raise SystemExit(f"{region}: {len(image):#x} bytes exceed allotted {allotted:#x}")
    return bytes(image)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("layout", choices=sorted(mkmra.LAYOUTS))
    ap.add_argument("romset", type=Path)
    ap.add_argument("--parent", type=Path, action="append", default=[])
    ap.add_argument("--slapstic-free", action="store_true")
    ap.add_argument("-o", "--out", type=Path, required=True, help="output directory (outside git)")
    args = ap.parse_args()

    layout = mkmra.LAYOUTS[args.layout]
    machine = mkmra.json.loads(mkmra.DATA.read_text())[layout["setname"]]
    sources = [Source(args.romset)] + [Source(p) for p in args.parent]
    args.out.mkdir(parents=True, exist_ok=True)
    manifest = [f"layout {args.layout} set {layout['setname']} from {args.romset}"]

    for index, address, regions in layout["indexes"]:
        image = bytearray()
        for region, offset, allotted in regions:
            if offset < len(image):
                raise SystemExit(f"{region}: offset {offset:#x} overlaps")
            image.extend(b"\xff" * (offset - len(image)))
            manifest.append(f"index {index} offset {offset:#x}: region {region}")
            image.extend(build_region(machine, region, allotted, sources, args.slapstic_free, manifest))
        if index == 0:
            (args.out / "ddr.bin").write_bytes(image)
            manifest.append(f"ddr.bin: {len(image):#x} bytes (DDR 0x{address:08X})")
        elif index == 3:
            # merged 200e/210e pair: even bytes = 200e (high lane), odd = 210e (low lane)
            (args.out / "zram_hi.hex").write_text("".join(f"{b:02x}\n" for b in image[0::2]))
            (args.out / "zram_lo.hex").write_text("".join(f"{b:02x}\n" for b in image[1::2]))
            manifest.append(f"zram_hi.hex / zram_lo.hex: {len(image) // 2} bytes each")
        else:
            (args.out / f"index{index}.bin").write_bytes(image)
            manifest.append(f"index{index}.bin: {len(image):#x} bytes")
    (args.out / "dips.bin").write_bytes(bytes([0xFF, 0x01]))
    (args.out / "manifest.txt").write_text("\n".join(manifest) + "\n")
    print("\n".join(manifest))


if __name__ == "__main__":
    main()
