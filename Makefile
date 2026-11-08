# rs6809-fpga: the Tang Nano 20K machines of rs6809.
#
#   make rom6809 ROM=path/to/6809M.bin   the 6809 boot ROM (NitrOS-9 kit) -> m6809/rom6809.hex
#   make rom68k                          the 68000 boot ROM and ICE stub   -> m68k/rom/*.hex
#   make sim                             Verilator models of both machines (sim/build/sim_mc09, sim_t68k)
#   make test6809 SD6809=...             NitrOS-9 + BASIC09 in the simulation (prints 42)
#   make test6809l2 SD6809L2=...         NitrOS-9 Level 2: mfree (952k), then cc1 hello.c (Hello from C: 42)
#   make check6809 / check68k            open-source synthesis and place & route (fit and timing only)
#   gw_sh m6809/build.tcl / m68k/build.tcl   the bitstreams, with Gowin EDA
ROM ?= ../rs6809/artifacts/nitros9/6809M.bin
SD6809 ?= ../rs6809/artifacts/nitros9/multicomp09_sd.img
SD6809L2 ?= ../rs6809/artifacts/level2/multicomp09-level2.img
RS6809 ?= ../rs6809/target/release/rs6809

.PHONY: rom6809 rom68k sim test6809 test6809l2 check6809 check68k clean

rom6809:
	python3 tools/bin2hex.py $(ROM) m6809/rom6809.hex 8192
	mkdir -p sim/build && cp m6809/rom6809.hex sim/build/

rom68k:
	$(MAKE) -C m68k/rom

sim: rom68k
	$(MAKE) -C sim mc09 t68k

test6809:
	cd sim/build && ./sim_mc09 -s $(abspath $(SD6809)) -S ../../tests/nitros9-basic09.tsv -u " 42"

test6809l2:
	cd sim/build && ./sim_mc09 -s $(abspath $(SD6809L2)) -S ../../tests/level2.tsv -u "Total:"
	cd sim/build && ./sim_mc09 -s $(abspath $(SD6809L2)) -S ../../tests/level2-cc1.tsv -u "Hello from C: 42"

check6809: m6809/rom6809.hex
	sh tools/oss-check.sh 6809

check68k: rom68k
	sh tools/oss-check.sh 68k

clean:
	rm -rf build sim/build
	$(MAKE) -C m68k/rom clean
