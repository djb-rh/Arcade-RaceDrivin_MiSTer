.PHONY: test check mra machines build sync help

PYTHON ?= python3
# Verilator's wrapper is a perl script; on this Mac an x86 perl sits earlier
# in PATH than the system one, so put /usr/bin first for simulation runs.
SIM_PATH ?= /usr/bin:$(PATH)

# Quartus runs on the x86 Linux build host, driven over SSH. Set BUILD_HOST
# (user@host) and BUILD_DIR (remote checkout path) in the environment or in a
# local, untracked make.local.
-include make.local
BUILD_HOST ?=
BUILD_DIR  ?= rd-mister
QUARTUS_SH ?= quartus_sh

help:
	@echo "make test      - Verilator regressions (inherited GSP memory tests, more as they land)"
	@echo "make check     - source-list, hash and hygiene checks"
	@echo "make mra       - regenerate MRA files into releases/"
	@echo "make machines  - refresh tools/data/machines.json from a MAME binary (MAME=path)"
	@echo "make build     - rsync to BUILD_HOST and run the Quartus flow there (needs BUILD_HOST)"

test:
	PATH="$(SIM_PATH)" $(PYTHON) tools/hd/test.py

check:
	$(PYTHON) tools/hd/check_release.py

mra:
	$(PYTHON) tools/mkmra.py racedriv-cockpit  -o "releases/Race Drivin' (Cockpit, rev 5).mra"
	$(PYTHON) tools/mkmra.py racedriv-cockpit  --slapstic-free -o "releases/Race Drivin' (Cockpit, rev 5, slapstic-free).mra"
	$(PYTHON) tools/mkmra.py racedrivc-compact -o "releases/Race Drivin' (Compact, rev 5).mra"
	$(PYTHON) tools/mkmra.py racedrivc-compact --slapstic-free -o "releases/Race Drivin' (Compact, rev 5, slapstic-free).mra"

machines:
	@test -n "$(MAME)" || (echo 'Usage: make machines MAME=path/to/mame'; exit 2)
	$(PYTHON) tools/mame_machines.py --mame "$(MAME)" racedriv racedrivc harddriv harddrivc

sync:
	@test -n "$(BUILD_HOST)" || (echo 'Set BUILD_HOST=user@host (see docs/toolchain.md)'; exit 2)
	rsync -az --delete --exclude .git --exclude output_files --exclude db --exclude incremental_db \
		--exclude generated ./ "$(BUILD_HOST):$(BUILD_DIR)/"

build: sync
	ssh "$(BUILD_HOST)" "cd $(BUILD_DIR) && $(QUARTUS_SH) --flow compile RaceDrivin"
	mkdir -p output_files
	rsync -az "$(BUILD_HOST):$(BUILD_DIR)/output_files/" output_files/
	@ls -la output_files/*.rbf
