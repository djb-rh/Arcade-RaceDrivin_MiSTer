# Race Drivin' for MiSTer

An FPGA implementation of Atari's Race Drivin' (compact / A046901 MultiSync
hardware) for the DE10-Nano MiSTer, intended to replace the original board
stack in a real Race Drivin' cabinet, together with a custom I/O board that
connects the cabinet's wheel, pedals, shifter, switches, coin door and the two
RS-232 ports to the core.

Status: **planning**. See [PLAN.md](PLAN.md) for the approach, roadmap and
open decisions, and [NOTES.md](NOTES.md) for the sourced findings behind it.

This project extends the Hard Drivin' MiSTer core by Fulviuus
(<https://github.com/retrogarage/harddrivin-mister>, GPL-3.0-or-later) and
uses MAME's `harddriv` driver as the behavioural reference.

No ROM data is or may be committed to this repository. Tools work from
MAME-style ROM zips supplied by the user.

Licence: GPL-3.0-or-later for project code; third-party blocks keep their
own licences (see NOTICE once sources are imported).
