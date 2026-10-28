#!/usr/bin/env python3
"""Check release hashes, build source paths and source-tree hygiene."""
import hashlib
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
result = subprocess.run(["tclsh", "tools/hd/list_sources.tcl"], cwd=ROOT, check=True,
                        text=True, stdout=subprocess.PIPE)
count = 0
for row in result.stdout.splitlines():
    kind, value = row.split("\t", 1)
    if kind in {"VERILOG_FILE", "SYSTEMVERILOG_FILE", "VHDL_FILE", "QIP_FILE", "SDC_FILE", "SOURCE_FILE"}:
        source = Path(value)
        assert source.is_file(), f"Missing source: {value}"
        assert source.is_relative_to(ROOT), "Build depends on an external source"
        count += 1
for row in (ROOT / "releases/SHA256SUMS").read_text().splitlines():
    digest, name = row.split("  ", 1)
    assert hashlib.sha256((ROOT / "releases" / name).read_bytes()).hexdigest() == digest, name
mra = ET.parse(ROOT / "releases/Race Drivin' (Cockpit, rev 5).mra").getroot()
rbfs = sorted((ROOT / "releases").glob(mra.findtext("rbf") + "_*.rbf"))
assert rbfs, "No released cockpit RBF (releases/RaceDrivin_cockpit_YYYYMMDD.rbf)"
assert mra.find("nvram").attrib == {"index": "2", "size": "8192"}
private = re.compile(r"/(?:Users|home)/[A-Za-z0-9]|192[.]168[.]\d+[.]\d+|BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY")
excluded = {".git", ".claude", "build", "generated", "output_files", "db", "incremental_db", "__pycache__", "make.local"}
for path in ROOT.rglob("*"):
    if any(part in excluded for part in path.relative_to(ROOT).parts) or not path.is_file():
        continue
    assert not path.is_symlink(), f"Unexpected symlink: {path.relative_to(ROOT)}"
    if path.suffix in {".rbf", ".jpg"}:
        continue
    text = path.read_text(errors="replace")
    assert not private.search(text), f"Private path or secret marker: {path.relative_to(ROOT)}"
print(f"PASS: {count} build source assignments, release hashes, MRA and source hygiene")
