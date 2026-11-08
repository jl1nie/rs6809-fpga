# Verilator simulation of both machines.
#   make mc09        the 6809 machine (needs build/rom6809.hex: make rom6809)
#   make t68k        the 68000 machine
VERILATOR ?= verilator
BUILD := build
COMMON := ../common/sdram.v ../common/uart.v ../common/dbg_link.v ../common/sd_rw.v \
          ../common/sdcmd_ctrl.v ../common/sd_sector.v sdram_model.v
VFLAGS := -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-PINMISSING -Wno-TIMESCALEMOD \
          -Wno-MULTIDRIVEN -Wno-LATCH -Wno-UNOPTFLAT -Wno-SYMRSVDWORD -Wno-BLKANDNBLK \
          -Wno-INITIALDLY -Wno-CASEOVERLAP -Wno-IMPLICIT -Wno-COMBDLY -Wno-UNSIGNED \
          --x-assign 0 --x-initial 0 -O3 --threads 1 -CFLAGS -O2

all: mc09

$(BUILD)/cpu09p_dbg.v: ../m6809/cpu09p_dbg.vhd
	mkdir -p $(BUILD)/ghdl
	cd $(BUILD)/ghdl && ghdl -a --std=08 -fsynopsys ../../$< && ghdl synth --std=08 -fsynopsys --out=verilog cpu09p_dbg > ../cpu09p_dbg.v

mc09: $(BUILD)/cpu09p_dbg.v
	$(VERILATOR) --cc --exe --build -j 8 $(VFLAGS) -Mdir $(BUILD)/mc09 --top-module tb_mc09 \
	  tb_mc09.v ../m6809/mc09_soc.v ../m6809/mc_devices.v ../m6809/dbg6809.v $(BUILD)/cpu09p_dbg.v \
	  $(COMMON) $(CURDIR)/tb_mc09.cpp -CFLAGS -I$(CURDIR) -o ../sim_mc09

clean:
	rm -rf $(BUILD)

FX68K := ../m68k/fx68k/fx68k.sv ../m68k/fx68k/fx68kAlu.sv ../m68k/fx68k/uaddrPla.sv
t68k:
	$(MAKE) -C ../m68k/rom
	mkdir -p $(BUILD)
	cp ../m68k/rom/*.hex ../m68k/fx68k/*.mem $(BUILD)/
	$(VERILATOR) --cc --exe --build -j 8 $(VFLAGS) -Wno-UNOPTFLAT -Mdir $(BUILD)/t68k --top-module tb_t68k \
	  tb_t68k.v ../m68k/t68k_soc.v ../m68k/duart.v ../m68k/ide_sd.v ../m68k/dbg68k.v $(FX68K) \
	  $(COMMON) $(CURDIR)/tb_t68k.cpp -CFLAGS -I$(CURDIR) -o ../sim_t68k
