#!/usr/bin/env python3
"""Extract ROM, CPU and display facts for the Hard/Race Drivin' machines from MAME.

Reads `mame -listxml <machine>` output (either by running a MAME binary or from
saved XML files) and writes a compact JSON file that the other tools consume.
The JSON holds names, sizes, offsets and CRCs only: no ROM data.

    tools/mame_machines.py --mame ~/Developer/mame/hd racedriv racedrivc harddriv harddrivc
    tools/mame_machines.py --xml racedriv.xml --xml racedrivc.xml

Output defaults to tools/data/machines.json.
"""
import argparse
import json
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

DEFAULT_OUT = Path(__file__).resolve().parent / "data" / "machines.json"


def machine_from_xml(root, name):
    for mach in root.iter("machine"):
        if mach.get("name") == name:
            return mach
    raise SystemExit(f"machine {name} not in listxml output")


def describe(mach):
    roms = []
    for rom in mach.findall("rom"):
        roms.append({
            "region": rom.get("region"),
            "name": rom.get("name"),
            "offset": int(rom.get("offset", "0"), 16),
            "size": int(rom.get("size")),
            "crc": rom.get("crc"),
            "sha1": rom.get("sha1"),
            "status": rom.get("status", "good"),
        })
    cpus = [{"tag": c.get("tag"), "name": c.get("name"), "clock": int(c.get("clock"))}
            for c in mach.findall("chip") if c.get("type") == "cpu"]
    displays = [{k: d.get(k) for k in ("width", "height", "refresh", "pixclock", "htotal", "vtotal")}
                for d in mach.findall("display")]
    return {
        "name": mach.get("name"),
        "description": mach.findtext("description"),
        "year": mach.findtext("year"),
        "manufacturer": mach.findtext("manufacturer"),
        "cloneof": mach.get("cloneof"),
        "romof": mach.get("romof"),
        "roms": roms,
        "cpus": cpus,
        "displays": displays,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("machines", nargs="*", help="machine names to query from --mame")
    ap.add_argument("--mame", type=Path, help="MAME binary to run -listxml with")
    ap.add_argument("--xml", action="append", type=Path, default=[], help="saved -listxml output (repeatable)")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = ap.parse_args()

    result = {}
    if args.out.exists():
        result = json.loads(args.out.read_text())
    for path in args.xml:
        root = ET.parse(path).getroot()
        for mach in root.iter("machine"):
            if mach.find("rom") is not None and mach.get("isdevice") != "yes":
                result[mach.get("name")] = describe(mach)
    if args.machines:
        if not args.mame:
            ap.error("--mame is required to query machines by name")
        for name in args.machines:
            xml = subprocess.run([str(args.mame), "-listxml", name], check=True, text=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
            result[name] = describe(machine_from_xml(ET.fromstring(xml), name))
    if not result:
        ap.error("nothing to do: give machine names with --mame, or --xml files")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=1, sort_keys=True) + "\n")
    print(f"wrote {args.out} with {len(result)} machines: {', '.join(sorted(result))}")


if __name__ == "__main__":
    main()
