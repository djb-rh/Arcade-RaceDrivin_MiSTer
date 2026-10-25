#!/usr/bin/env python3
"""Check a MAME-style ROM set (zip or directory) for one of the supported machines.

    tools/romset.py racedriv  ~/roms/racedriv.zip
    tools/romset.py racedrivc ~/roms/racedrivc/ --slapstic-free

Reports every ROM MAME expects: present, missing, wrong size, CRC mismatch.
With --slapstic-free the four program ROMs that slapfree.py rewrites (the R and
S pairs) are allowed to have any CRC, as long as the size is right. Undumped
ROMs (the ASIC65 mask ROM) are skipped. Exit status is 0 only if the set is
usable by the core. Nothing is extracted or copied.
"""
import argparse
import json
import sys
import zipfile
import zlib
from pathlib import Path

DATA = Path(__file__).resolve().parent / "data" / "machines.json"

# ROM region offsets of the program ROM pairs that slapfree.py modifies
# (200R/210R at 0x00000 and 200S/210S at 0x20000 of mainpcb:maincpu).
SLAPSTIC_FREE_PATCHED = {("mainpcb:maincpu", 0x00000), ("mainpcb:maincpu", 0x00001),
                         ("mainpcb:maincpu", 0x20000), ("mainpcb:maincpu", 0x20001)}


def load_machine(name):
    machines = json.loads(DATA.read_text())
    if name not in machines:
        raise SystemExit(f"{name} is not in {DATA}; run tools/mame_machines.py first")
    return machines[name]


class Source:
    """A zip file or a directory of loose files, read by file name."""

    def __init__(self, path: Path):
        self.path = path
        self.zip = zipfile.ZipFile(path) if path.is_file() else None
        if self.zip:
            self.names = {Path(n).name: n for n in self.zip.namelist()}
        else:
            self.names = {p.name: p for p in path.iterdir() if p.is_file()}

    def read(self, name):
        key = self.names.get(name)
        if key is None:
            return None
        return self.zip.read(key) if self.zip else Path(key).read_bytes()


def check(machine, source, slapstic_free=False, parents=None):
    ok = True
    for rom in machine["roms"]:
        if rom["status"] == "nodump":
            print(f"  skip   {rom['name']:28s} undumped")
            continue
        data = source.read(rom["name"])
        if data is None and parents:
            for parent in parents:
                data = parent.read(rom["name"])
                if data is not None:
                    break
        if data is None:
            print(f"  MISSING {rom['name']:28s} {rom['region']}")
            ok = False
            continue
        if len(data) != rom["size"]:
            print(f"  SIZE    {rom['name']:28s} {len(data)} != {rom['size']}")
            ok = False
            continue
        crc = f"{zlib.crc32(data) & 0xffffffff:08x}"
        patched = (rom["region"], rom["offset"]) in SLAPSTIC_FREE_PATCHED
        if crc != rom["crc"]:
            if slapstic_free and patched:
                print(f"  patched {rom['name']:28s} crc {crc} (slapstic-free, accepted)")
            else:
                print(f"  CRC     {rom['name']:28s} {crc} != {rom['crc']}")
                ok = False
        else:
            print(f"  ok      {rom['name']:28s}")
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("machine")
    ap.add_argument("romset", type=Path, help="zip file or directory")
    ap.add_argument("--parent", type=Path, action="append", default=[],
                    help="parent set zip/dir for clones that share ROMs (e.g. racedriv for racedrivc)")
    ap.add_argument("--slapstic-free", action="store_true",
                    help="accept any CRC for the R and S program ROM pairs")
    args = ap.parse_args()
    machine = load_machine(args.machine)
    print(f"{machine['name']}: {machine['description']}")
    ok = check(machine, Source(args.romset), args.slapstic_free, [Source(p) for p in args.parent])
    print("RESULT:", "usable" if ok else "NOT usable")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
