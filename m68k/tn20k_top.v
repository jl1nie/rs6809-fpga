// tn20k_top.v - the Tiny68K-compatible 68000 machine on the Tang Nano 20K.
// S2 resets the machine (RAM and the SD card keep their contents).
// GPL-3.0-or-later.
module tn20k_top (
    input         clk_27m,
    input         btn_s1,
    input         btn_s2,
    input         uart_rx,
    output        uart_tx,
    input         uart_b_rx,
    output        uart_b_tx,
    output [5:0]  leds_n,
    output        sd_clk,
    inout         sd_cmd,
    inout  [3:0]  sd_dat,
    output        O_sdram_clk,
    output        O_sdram_cke,
    output        O_sdram_cs_n,
    output        O_sdram_cas_n,
    output        O_sdram_ras_n,
    output        O_sdram_wen_n,
    inout  [31:0] IO_sdram_dq,
    output [10:0] O_sdram_addr,
    output [1:0]  O_sdram_ba,
    output [3:0]  O_sdram_dqm
);
wire clk, lock;
pll_32m pll (.clkout(clk), .lock(lock), .clkin(clk_27m));

reg [15:0] por = 16'd0;
always @(posedge clk) if (!lock) por <= 16'd0; else if (!por[15]) por <= por + 16'd1;

wire [31:0] dq_out;
wire        dq_oe;
assign IO_sdram_dq = dq_oe ? dq_out : 32'bz;
wire [5:0] leds;
assign leds_n = ~leds;

t68k_soc #(.BOOT_HEX("rom/boot68k.hex"), .STUB_HEX("rom/stub68k.hex"), .SYS_HZ(32400000),
           .UART_DIV(281), .UART_B_DIV(281)) soc (
    .clk(clk), .por_n(por[15]), .reset_btn(btn_s2), .uart_rx(uart_rx), .uart_tx(uart_tx),
    .uart_b_rx(uart_b_rx), .uart_b_tx(uart_b_tx), .leds(leds),
    .sd_clk(O_sdram_clk), .sd_cke(O_sdram_cke), .sd_cs_n(O_sdram_cs_n), .sd_ras_n(O_sdram_ras_n),
    .sd_cas_n(O_sdram_cas_n), .sd_we_n(O_sdram_wen_n), .sd_addr(O_sdram_addr), .sd_ba(O_sdram_ba),
    .sd_dqm(O_sdram_dqm), .sd_dq_out(dq_out), .sd_dq_oe(dq_oe), .sd_dq_in(IO_sdram_dq),
    .sdclk(sd_clk), .sdcmd(sd_cmd), .sddat(sd_dat)
);
endmodule
