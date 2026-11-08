# Gowin EDA (gw_sh): the 6809 machine. Run from the repository root:
#   gw_sh m6809/build.tcl      ->  impl/pnr/rs6809fpga_6809.fs
# m6809/rom6809.hex (the 8 KiB boot ROM) must exist first: make rom6809
set_device GW2AR-LV18QN88C8/I7 -name GW2AR-18C
add_file m6809/tn20k_top.v
add_file m6809/mc09_soc.v
add_file m6809/mc_devices.v
add_file m6809/dbg6809.v
add_file m6809/cpu09p_dbg.vhd
add_file common/sdram.v
add_file common/uart.v
add_file common/dbg_link.v
add_file common/sd_rw.v
add_file common/sdcmd_ctrl.v
add_file common/sd_sector.v
add_file common/pll_32m.v
add_file common/tn20k.cst
add_file common/tn20k.sdc
set_option -synthesis_tool gowinsynthesis
set_option -output_base_name rs6809fpga_6809
set_option -verilog_std v2001
set_option -vhdl_std vhd2008
set_option -top_module tn20k_top
set_option -use_mspi_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -bit_compress 1
run all
