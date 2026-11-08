create_clock -name clk_27m -period 37.037 [get_ports {clk_27m}]
create_generated_clock -name clk -source [get_ports {clk_27m}] -multiply_by 6 -divide_by 5 [get_pins {pll/rpll_inst/CLKOUT}]
