# Toolchain

## Simulation (Mac, native)

- Verilator 5.052 from Homebrew (`brew install verilator`).
- Gotcha: Verilator's `verilator` command is a perl script and this Mac has an
  x86-only MacPorts perl at `/opt/local/bin/perl` ahead of the system perl in
  PATH, which fails with "Bad CPU type in executable". `make test` prepends
  `/usr/bin` to PATH; do the same for manual runs.
- `make test` runs the Verilator regressions (currently the three GSP-memory
  testbenches inherited from the Hard Drivin' core, under `sim/hd_tests/`).
  All three pass on the imported tree (2026-10-24).

## Synthesis (x86 Linux build host)

Quartus Prime Lite 24.1 runs on a rented x86 Linux server, driven over SSH
from the Mac. The user's own x86 box never materialised and AWS held the
account in a verification block for days, so the host is a Hetzner Cloud
server (2026-10-26):

- Hetzner Cloud project `rd-mister`, server `rd-mister-build`, Ashburn,
  type CPX41 (8 shared AMD vCPU, 16 GB, 240 GB NVMe), Ubuntu 24.04, SSH as
  `root` with the Mac's `~/.ssh/id_ed25519` key. The IP changes when the
  server is recreated; it lives only in the untracked `make.local`.
- The server bills while it exists, powered off or not, so delete it after
  a build session and recreate it next time: the OS prerequisites plus the
  Quartus install take about twenty minutes to redo.
- Prerequisites: `apt-get install rsync make libglib2.0-0 libxext6 libx11-6
  libxrender1 libxtst6 libxi6 libfontconfig1 libfreetype6 libsm6 libice6
  libncurses6 libncurses5-dev libstdc++6 libpng16-16t64 libxft2 libbz2-1.0
  libxcb1 xz-utils bzip2 zlib1g`.
- Quartus Lite 24.1 installed unattended from `QuartusLiteSetup-24.1std.0.1077-linux.run`
  with `cyclonev-24.1std.0.1077.qdz` in the same directory:
  `--mode unattended --unattendedmodeui none --accept_eula 1
  --installdir /opt/intelFPGA_lite/24.1std --disable-components
  quartus_help,questa_fe,questa_fse`. `quartus_sh` is
  `/opt/intelFPGA_lite/24.1std/quartus/bin/quartus_sh`.
- Getting the installer: Altera's download pages need a free Altera
  account, and the file host (`download.altera.com`, Akamai) refuses curl
  and wget outright, so the two files have to be downloaded in a real
  browser and copied to the server with rsync. Published SHA-1s:
  installer `62a899e695d4ea478bc51850867cf6222d9589cf`, Cyclone V pack
  `a361c6ab1aba00f6385fc8deb8b81045c3f9ad7c`.
- `make.local` on the Mac (ignored by git):

```
BUILD_HOST = root@<server ip>
BUILD_DIR = rd-mister
QUARTUS_SH = /opt/intelFPGA_lite/24.1std/quartus/bin/quartus_sh
```

`make build` rsyncs the tree there (excluding `.git`, Quartus outputs,
`sim/build` and `make.local`), runs `quartus_sh --flow compile RaceDrivin`
and copies `output_files/` back. A build is about 35 minutes (7 synthesis,
25 fit); the server runs three or four in parallel in copies of the tree
for seed sweeps. Timing closure notes, including the measuring loop (one-
module Quartus projects for sizes, a grouped `report_timing` for the
failing path families), are in NOTES.md section 12.

Fallback if no server is available: Docker Desktop with Rosetta on the Mac
(Rosetta is not installed here yet), using an image with Quartus Lite 24.1.

## MAME oracle

MAME 0.289 built from source at `~/Developer/mame` as the `hd` subtarget
(`./hd`). See `mame/README.md` for the measurement patch, the PCH gotcha and
the run commands.

## Python tools

- `tools/mame_machines.py`: ROM/CPU/display facts from `mame -listxml` into
  `tools/data/machines.json` (names, sizes, CRCs only).
- `tools/romset.py`: validate a zip or directory against those facts, with a
  `--slapstic-free` mode for the patched program ROMs.
- `tools/mkmra.py`: generate the MRAs; regenerating the Hard Drivin' cockpit
  MRA reproduces the upstream file byte for byte (regression check).
- `tools/dsp32_report.py`: summarise an `RD_DSP32LOG` run.
