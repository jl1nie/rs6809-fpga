#!/bin/sh
# oss-check.sh 6809|68k: synthesis (Yosys) and place & route (nextpnr
# himbaechel, Apicula) of a machine for the GW2AR-18C, to see the
# resources and the timing without Gowin EDA. The bitstream for the board
# is made with Gowin EDA (m6809/build.tcl, m68k/build.tcl).
# Uses yowasp-yosys and yowasp-nextpnr-himbaechel-gowin (pip install
# yowasp-yosys yowasp-nextpnr-himbaechel-gowin), and GHDL for cpu09p.
set -eu
cd "$(dirname "$0")/.."
R=$PWD
M=$1
OUT=build/oss$M
mkdir -p "$OUT"
COMMON="$R/common/sdram.v $R/common/uart.v $R/common/dbg_link.v $R/common/sd_rw.v $R/common/sdcmd_ctrl.v $R/common/sd_sector.v $R/common/pll_32m.v"
case $M in
6809)
	# cpu09p is VHDL: GHDL turns it into Verilog for Yosys
	mkdir -p "$OUT/ghdl"
	(cd "$OUT/ghdl" && ghdl -a --std=08 -fsynopsys "$R/m6809/cpu09p_dbg.vhd" &&
		ghdl synth --std=08 -fsynopsys --out=verilog cpu09p_dbg > ../cpu09p_dbg.v)
	cp m6809/rom6809.hex "$OUT/"
	SRC="$R/$OUT/cpu09p_dbg.v $R/m6809/mc09_soc.v $R/m6809/mc_devices.v $R/m6809/dbg6809.v $R/m6809/tn20k_top.v"
	CST=common/tn20k.cst
	;;
68k)
	mkdir -p "$OUT/rom"
	cp m68k/rom/*.hex "$OUT/rom/"
	cp m68k/fx68k/*.mem "$OUT/"
	SRC="-sv $R/m68k/fx68k/fx68k.sv $R/m68k/fx68k/fx68kAlu.sv $R/m68k/fx68k/uaddrPla.sv $R/m68k/t68k_soc.v $R/m68k/duart.v $R/m68k/ide_sd.v $R/m68k/dbg68k.v $R/m68k/tn20k_top.v"
	CST=m68k/tn20k_68k.cst
	;;
*) echo "usage: $0 6809|68k" >&2; exit 1 ;;
esac
cd "$OUT"
yowasp-yosys -q -l yosys.log -p "read_verilog $SRC $COMMON; synth_gowin -top tn20k_top -json top.json; tee -q -o stat.txt stat"
yowasp-nextpnr-himbaechel-gowin --json top.json --write pnr.json --device GW2AR-LV18QN88C8/I7 \
	--vopt family=GW2A-18C --vopt cst="$R/$CST" --freq 32.4 > pnr.log 2>&1 || true
grep -A30 "Device utilisation" pnr.log | head -40
grep "Max frequency" pnr.log | tail -3
