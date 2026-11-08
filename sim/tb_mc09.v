// tb_mc09.v - the 6809 machine with the SDRAM model, for Verilator.
module tb_mc09 #(parameter UART_DIV = 32, parameter TICK = 640000) (
    input        clk,
    input        por_n,
    input        reset_btn,
    input        uart_rx,
    output       uart_tx,
    output [5:0] leds,
    output       sdclk,
    output       sdcmd,
    input        sdcmd_in,
    output [3:0] sddat,
    input  [3:0] sddat_in
);
wire sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_dq_oe;
wire [10:0] sd_addr;
wire [1:0] sd_ba;
wire [3:0] sd_dqm;
wire [31:0] sd_dq_out, sd_dq_in;
mc09_soc #(.ROM_HEX("rom6809.hex"), .RAM_KB(1024), .UART_DIV(UART_DIV), .TICK(TICK), .SIMULATE(1)) soc (
    .clk(clk), .por_n(por_n), .reset_btn(reset_btn), .uart_rx(uart_rx), .uart_tx(uart_tx), .leds(leds),
    .sd_clk(sd_clk), .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n),
    .sd_we_n(sd_we_n), .sd_addr(sd_addr), .sd_ba(sd_ba), .sd_dqm(sd_dqm), .sd_dq_out(sd_dq_out),
    .sd_dq_oe(sd_dq_oe), .sd_dq_in(sd_dq_in),
    .sdclk(sdclk), .sdcmd(sdcmd), .sdcmd_in(sdcmd_in), .sddat(sddat), .sddat_in(sddat_in)
);
sdram_model ram (.sd_clk(sd_clk), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n),
    .sd_we_n(sd_we_n), .sd_addr(sd_addr), .sd_ba(sd_ba), .sd_dqm(sd_dqm), .sd_dq_out(sd_dq_out),
    .sd_dq_oe(sd_dq_oe), .sd_dq_in(sd_dq_in));
endmodule
