// t68k_soc.v - a Tiny68K-compatible 68000 machine for the Tang Nano 20K:
// fx68k at 8 MHz, 8 MiB of RAM in the SDRAM ($000000-$7FFFFF), the boot ROM
// at $FF0000 (also at $000000 after reset), the IDE registers on the SD card
// at $FFE000, the MC68681 DUART at $FFF000 (channel A the console on the
// USB serial port, channel B a second serial port on GPIO), and the ICE.
// Addresses $800000-$FFDFFF that hold nothing read $FFFF.
//
// The ICE (debug unit here, protocol in dbg68k.v): a level-7 interrupt,
// a breakpoint (an ILLEGAL shown in place of the instruction word) or the
// trace exception after a step takes the CPU into the stub: the debug unit
// answers that exception's vector fetch with the stub's address and opens
// the debug window ($FFD000 stub ROM, $FFD800 mailbox, $FFDC00 control)
// until the stub returns. While the window is open, and while a step runs,
// interrupts are held off and the DUART's timer stands still.
// GPL-3.0-or-later.
module t68k_soc #(
    parameter BOOT_HEX = "boot68k.hex",
    parameter STUB_HEX = "stub68k.hex",
    parameter SYS_HZ   = 32400000,
    parameter UART_DIV = 281,
    parameter UART_B_DIV = 281,
    parameter SIMULATE = 0
) (
    input         clk,
    input         por_n,
    input         reset_btn,
    input         uart_rx,
    output        uart_tx,
    input         uart_b_rx,
    output        uart_b_tx,
    output [5:0]  leds,

    output        sd_clk,
    output        sd_cke,
    output        sd_cs_n,
    output        sd_ras_n,
    output        sd_cas_n,
    output        sd_we_n,
    output [10:0] sd_addr,
    output [1:0]  sd_ba,
    output [3:0]  sd_dqm,
    output [31:0] sd_dq_out,
    output        sd_dq_oe,
    input  [31:0] sd_dq_in,

    output        sdclk,
`ifdef VERILATOR
    output        sdcmd,
    input         sdcmd_in,
    output [3:0]  sddat,
    input  [3:0]  sddat_in
`else
    inout         sdcmd,
    inout  [3:0]  sddat
`endif
);
localparam STUB_ENTRY = 24'hffd000;

// ---------------- resets ----------------
wire dbg_reset, ram_ready;
reg [3:0] rst_sync;
always @(posedge clk or negedge por_n)
    if (!por_n) rst_sync <= 4'd0;
    else rst_sync <= {rst_sync[2:0], !(reset_btn || dbg_reset) && ram_ready};
wire sys_rst_n = rst_sync[3];

// ---------------- CPU (8 MHz: PHI1 and PHI2 every 4 clocks) ----------------
reg [1:0] ph;
always @(posedge clk) ph <= ph + 2'd1;
wire enPhi1 = (ph == 2'd0);
wire enPhi2 = (ph == 2'd2);
wire ASn, UDSn, LDSn, eRWn, FC0, FC1, FC2, E, VMAn, BGn, oRESETn, oHALTEDn;
wire [15:0] oEdb;
wire [23:1] eab;
reg  [15:0] iEdb;
reg         DTACKn;
reg  [2:0]  ipl;
fx68k cpu (
    .clk(clk), .HALTn(1'b1), .extReset(!sys_rst_n), .pwrUp(!sys_rst_n), .enPhi1(enPhi1), .enPhi2(enPhi2),
    .eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn), .E(E), .VMAn(VMAn),
    .FC0(FC0), .FC1(FC1), .FC2(FC2), .BGn(BGn), .oRESETn(oRESETn), .oHALTEDn(oHALTEDn),
    .DTACKn(DTACKn), .VPAn(1'b1), .BERRn(1'b1), .BRn(1'b1), .BGACKn(1'b1),
    .IPL0n(!ipl[0]), .IPL1n(!ipl[1]), .IPL2n(!ipl[2]),
    .iEdb(iEdb), .oEdb(oEdb), .eab(eab)
);
wire [2:0]  fc = {FC2, FC1, FC0};
wire [23:0] ca = {eab, 1'b0};
wire        iack = (fc == 3'b111);
wire        prog = (fc[1:0] == 2'b10);
wire        sup_data = (fc == 3'b101);

// ---------------- debug unit state ----------------
reg         window;          // the debug window is open (CPU in the stub)
reg         parked;          // the stub has saved the registers
reg         exiting;         // the stub has returned; close at the next fetch outside
reg         stepping;
reg         ipl7;            // level-7 request
reg         ack7;            // our level 7 was acknowledged: intercept its vector
reg         bp_sub;          // an ILLEGAL was shown for a breakpoint
reg  [2:0]  cause, pend_cause;
reg  [23:0] w_addr;
reg  [15:0] w_val;
reg         w_rw;
wire [7:0]  bp_on;
wire [8*24-1:0] bp_addrs;
wire [4*2-1:0]  wp_modes;
wire [4*24-1:0] wp_los, wp_his;
wire        req_halt, halt_after_reset;

reg bp_hit;
reg wp_hit;
integer k;
always @* begin
    bp_hit = 1'b0;
    for (k = 0; k < 8; k = k + 1)
        if (bp_on[k] && bp_addrs[k*24 +: 24] == ca) bp_hit = 1'b1;
    wp_hit = 1'b0;
    for (k = 0; k < 4; k = k + 1)
        if (wp_modes[k*2 + (eRWn ? 0 : 1)] && ca >= wp_los[k*24 +: 24] && ca <= wp_his[k*24 +: 24]) wp_hit = 1'b1;
end

// ---------------- bus ----------------
wire duart_irq;
wire [7:0] duart_ivr;
always @(posedge clk) begin
    if (ipl7 && !window) ipl <= 3'd7;
    else if (window || stepping) ipl <= 3'd0;
    else ipl <= duart_irq ? 3'd2 : 3'd0;
end

reg        overlay;
reg        busy, done;
reg        by_dbg;
reg        dbg_cool;
reg [15:0] latch;
wire       strobes = !UDSn || !LDSn;
wire       cpu_start = !ASn && strobes && !done && !busy;

// ROMs and the mailbox (block RAM)
reg [15:0] boot [0:8191];
reg [15:0] stub [0:1023];
initial begin $readmemh(BOOT_HEX, boot); $readmemh(STUB_HEX, stub); end
reg [12:0] rom_a;
reg [15:0] boot_q, stub_q;
always @(posedge clk) begin boot_q <= boot[rom_a]; stub_q <= stub[rom_a[9:0]]; end
reg [7:0] mb_hi [0:511];
reg [7:0] mb_lo [0:511];
reg [8:0] mb_a;
reg       mb_we_hi, mb_we_lo;
reg [15:0] mb_wd;
reg [7:0] mb_hi_q, mb_lo_q;
// the engine's port to the mailbox
wire [9:0] e_mb_addr;
wire       e_mb_we;
wire [7:0] e_mb_wdata;
reg  [7:0] e_mb_hi_q, e_mb_lo_q;
// One write port: the CPU's write first, the engine's (held in pend_*)
// in a clock without one; the engine never writes two clocks running.
reg        pend_we;
reg [9:0]  pend_a;
reg [7:0]  pend_d;
always @(posedge clk) begin
    if (e_mb_we) begin pend_we <= 1'b1; pend_a <= e_mb_addr; pend_d <= e_mb_wdata; end
    else if (!(mb_we_hi || mb_we_lo)) pend_we <= 1'b0;
end
wire       w_cpu = mb_we_hi || mb_we_lo;
wire       w_hi = w_cpu ? mb_we_hi : (pend_we && !pend_a[0]);
wire       w_lo = w_cpu ? mb_we_lo : (pend_we && pend_a[0]);
wire [8:0] w_a = w_cpu ? mb_a : pend_a[9:1];
wire [7:0] w_dh = w_cpu ? mb_wd[15:8] : pend_d;
wire [7:0] w_dl = w_cpu ? mb_wd[7:0] : pend_d;
always @(posedge clk) begin
    if (w_hi) mb_hi[w_a] <= w_dh;
    if (w_lo) mb_lo[w_a] <= w_dl;
end
always @(posedge clk) begin
    mb_hi_q <= mb_hi[mb_a];
    mb_lo_q <= mb_lo[mb_a];
    e_mb_hi_q <= mb_hi[e_mb_addr[9:1]];
    e_mb_lo_q <= mb_lo[e_mb_addr[9:1]];
end
reg e_mb_odd;
always @(posedge clk) e_mb_odd <= e_mb_addr[0];
wire [7:0] e_mb_rdata = e_mb_odd ? e_mb_lo_q : e_mb_hi_q;

// SDRAM
reg         s_req, s_we;
reg  [21:0] s_addr;
reg  [15:0] s_wdata;
reg  [1:0]  s_be;
wire        s_ack;
wire [15:0] s_rdata;

// IDE
reg         i_req, i_we, i_word, i_peek;
reg  [11:0] i_off;
reg  [15:0] i_wdata;
wire        i_ack;
wire [15:0] i_rdata;

// DUART
wire [7:0]  du_q;
reg         du_we, du_re;
reg  [3:0]  du_rs;
reg  [7:0]  du_wd;

// the engine's memory port
wire        m_req, m_we;
wire [23:0] m_addr;
wire [7:0]  m_wdata;
reg         m_ack;
reg  [7:0]  m_rdata;

localparam K_NONE = 3'd0, K_RAM = 3'd1, K_BOOT = 3'd2, K_STUB = 3'd3, K_MB = 3'd4, K_IDE = 3'd5;
reg [2:0] kind;
reg       byte_odd;       // the engine's byte is the low byte
reg       bw;

always @(posedge clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        DTACKn <= 1'b1; iEdb <= 16'hffff; busy <= 1'b0; done <= 1'b0; by_dbg <= 1'b0; dbg_cool <= 1'b0;
        overlay <= 1'b1; latch <= 16'hffff; kind <= K_NONE; byte_odd <= 1'b0; bw <= 1'b0;
        s_req <= 1'b0; s_we <= 1'b0; s_addr <= 0; s_wdata <= 0; s_be <= 0;
        i_req <= 1'b0; i_we <= 1'b0; i_word <= 1'b0; i_peek <= 1'b0; i_off <= 0; i_wdata <= 0;
        du_we <= 1'b0; du_re <= 1'b0; du_rs <= 0; du_wd <= 0; rom_a <= 0;
        mb_a <= 0; mb_we_hi <= 1'b0; mb_we_lo <= 1'b0; mb_wd <= 0; m_ack <= 1'b0; m_rdata <= 0;
        window <= 1'b0; parked <= 1'b0; exiting <= 1'b0; stepping <= 1'b0; ipl7 <= halt_after_reset; ack7 <= 1'b0;
        bp_sub <= 1'b0; cause <= 3'd0; pend_cause <= 3'd5; w_addr <= 0; w_val <= 0; w_rw <= 0;
    end else begin
        du_we <= 1'b0; du_re <= 1'b0; mb_we_hi <= 1'b0; mb_we_lo <= 1'b0; m_ack <= 1'b0; dbg_cool <= 1'b0;
        if (req_halt && !ipl7 && !window) begin ipl7 <= 1'b1; pend_cause <= 3'd1; end
        if (ASn) begin DTACKn <= 1'b1; done <= 1'b0; end

        if (!busy) begin
            if (cpu_start) begin
                by_dbg <= 1'b0;
                // a program fetch outside the window closes it after the stub returned
                if (prog && exiting && ca[23:12] != 12'hffd) begin
                    window <= 1'b0; exiting <= 1'b0; bp_sub <= 1'b0;
                end
                if (prog && overlay && ca[23:16] == 8'hff) overlay <= 1'b0;
                // watchpoints (data space, outside the stub)
                if (!prog && !iack && !window && wp_hit && !ipl7) begin
                    ipl7 <= 1'b1; pend_cause <= 3'd4;
                    w_addr <= ca; w_rw <= eRWn; w_val <= eRWn ? 16'h0000 : oEdb;
                end
                if (iack) begin
                    // interrupt acknowledge: ours (level 7) or the DUART's
                    if (ca[3:1] == 3'd7) begin
                        iEdb <= 16'h00ff; ack7 <= 1'b1; ipl7 <= 1'b0;
                    end else iEdb <= {8'h00, duart_ivr};
                    DTACKn <= 1'b0; done <= 1'b1;
                end else if (eRWn && sup_data && !window &&
                             ((ack7 && ca[23:2] == 22'h0000ff) ||        // $3FC: our level 7
                              (bp_sub && ca[23:2] == 22'h000004) ||      // $10: ILLEGAL
                              (stepping && ca[23:2] == 22'h000009))) begin // $24: trace
                    // the vector fetch: the stub instead
                    iEdb <= ca[1] ? STUB_ENTRY[15:0] : {8'h00, STUB_ENTRY[23:16]};
                    if (ca[1]) begin
                        window <= 1'b1; parked <= 1'b0; exiting <= 1'b0;
                        cause <= ack7 ? pend_cause : stepping ? 3'd3 : 3'd2;
                        if (stepping && pend_cause == 3'd4 && ack7) cause <= 3'd4;
                        ack7 <= 1'b0; stepping <= 1'b0;
                    end
                    DTACKn <= 1'b0; done <= 1'b1;
                end else if (eRWn && prog && !window && !stepping && bp_hit) begin
                    iEdb <= 16'h4afc; bp_sub <= 1'b1; DTACKn <= 1'b0; done <= 1'b1;
                end else if (window && ca[23:12] == 12'hffd) begin
                    if (ca[11] == 1'b0) begin               // stub ROM
                        rom_a <= {3'd0, ca[10:1]}; kind <= K_STUB; busy <= 1'b1;
                    end else if (ca[10] == 1'b0) begin      // mailbox
                        mb_a <= ca[9:1];
                        if (!eRWn) begin
                            mb_wd <= oEdb; mb_we_hi <= !UDSn; mb_we_lo <= !LDSn;
                            DTACKn <= 1'b0; done <= 1'b1;
                        end else begin kind <= K_MB; busy <= 1'b1; end
                    end else begin                          // control
                        if (!eRWn && ca[3:1] == 3'd0) parked <= 1'b1;
                        if (!eRWn && ca[3:1] == 3'd1) begin
                            parked <= 1'b0; exiting <= 1'b1; stepping <= oEdb[0];
                        end
                        iEdb <= {13'd0, cause};
                        DTACKn <= 1'b0; done <= 1'b1;
                    end
                end else if (overlay && eRWn && ca[23:16] == 8'h00) begin
                    rom_a <= ca[13:1]; kind <= K_BOOT; busy <= 1'b1;
                end else if (ca[23] == 1'b0) begin
                    s_addr <= ca[22:1]; s_we <= !eRWn; s_wdata <= oEdb; s_be <= {!UDSn, !LDSn};
                    s_req <= 1'b1; kind <= K_RAM; busy <= 1'b1;
                end else if (ca[23:14] == 10'b1111_1111_00) begin   // $FF0000-$FF3FFF
                    if (eRWn) begin rom_a <= ca[13:1]; kind <= K_BOOT; busy <= 1'b1; end
                    else begin DTACKn <= 1'b0; done <= 1'b1; end
                end else if (ca[23:12] == 12'hffe) begin
                    i_req <= 1'b1; i_we <= !eRWn; i_word <= !UDSn && !LDSn; i_peek <= 1'b0;
                    i_off <= {ca[11:1], UDSn}; i_wdata <= oEdb;
                    kind <= K_IDE; busy <= 1'b1;
                end else if (ca[23:12] == 12'hfff && ca[11:5] == 7'd0 && !LDSn) begin
                    du_rs <= ca[4:1]; du_wd <= oEdb[7:0];
                    du_we <= !eRWn; du_re <= eRWn;
                    iEdb <= {8'hff, du_q};
                    DTACKn <= 1'b0; done <= 1'b1;
                end else begin
                    iEdb <= 16'hffff; DTACKn <= 1'b0; done <= 1'b1;
                end
            end else if (m_req && !m_ack && !dbg_cool) begin
                // the ICE's memory access (bytes)
                by_dbg <= 1'b1;
                byte_odd <= m_addr[0];
                if (m_addr[23] == 1'b0) begin
                    s_addr <= m_addr[22:1]; s_we <= m_we; s_wdata <= {m_wdata, m_wdata};
                    s_be <= m_addr[0] ? 2'b01 : 2'b10; s_req <= 1'b1; kind <= K_RAM; busy <= 1'b1;
                end else if (m_addr[23:14] == 10'b1111_1111_00 && !m_we) begin
                    rom_a <= m_addr[13:1]; kind <= K_BOOT; busy <= 1'b1;
                end else if (m_addr[23:12] == 12'hffd && !m_addr[11] && !m_we) begin
                    rom_a <= {3'd0, m_addr[10:1]}; kind <= K_STUB; busy <= 1'b1;
                end else if (m_addr[23:12] == 12'hfff && m_addr[11:5] == 7'd0 && m_addr[0]) begin
                    m_rdata <= du_q; m_ack <= 1'b1; dbg_cool <= 1'b1;
                end else if (m_addr[23:12] == 12'hffe && !m_we) begin
                    i_req <= 1'b1; i_we <= 1'b0; i_word <= 1'b0; i_peek <= 1'b1;
                    i_off <= m_addr[11:0]; kind <= K_IDE; busy <= 1'b1;
                end else begin
                    m_rdata <= 8'hff; m_ack <= 1'b1; dbg_cool <= 1'b1;
                end
            end
        end else begin
            // the access in flight
            case (kind)
            K_RAM: if (s_ack) begin s_req <= 1'b0; busy <= 1'b0; finish(s_rdata); end
            K_IDE: if (i_ack) begin i_req <= 1'b0; busy <= 1'b0; finish(i_rdata); end
            K_BOOT, K_STUB, K_MB: begin
                // block RAM: the data is there two clocks after the access began
                if (bw) begin
                    bw <= 1'b0; busy <= 1'b0;
                    finish(kind == K_BOOT ? boot_q : kind == K_STUB ? stub_q : {mb_hi_q, mb_lo_q});
                end else bw <= 1'b1;
            end
            default: busy <= 1'b0;
            endcase
        end
    end
end

// the access's data to the CPU or the engine
task finish(input [15:0] d);
begin
    if (by_dbg) begin
        m_rdata <= byte_odd ? d[7:0] : d[15:8]; m_ack <= 1'b1; dbg_cool <= 1'b1;
    end else begin
        iEdb <= d; DTACKn <= 1'b0; done <= 1'b1;
    end
end
endtask

// DUART register values for reads (side effects come with du_re)
wire [3:0] du_prs = cpu_start ? ca[4:1] : m_addr[4:1];

sdram ram (
    .clk(clk), .rst_n(por_n), .ready(ram_ready),
    .req(s_req), .we(s_we), .addr(s_addr), .wdata(s_wdata), .be(s_be), .ack(s_ack), .rdata(s_rdata),
    .sd_clk(sd_clk), .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n),
    .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n), .sd_addr(sd_addr), .sd_ba(sd_ba),
    .sd_dqm(sd_dqm), .sd_dq_out(sd_dq_out), .sd_dq_oe(sd_dq_oe), .sd_dq_in(sd_dq_in)
);

ide_sd #(.SIMULATE(SIMULATE)) ide (
    .clk(clk), .rst_n(sys_rst_n), .req(i_req), .we(i_we), .word(i_word), .peek(i_peek),
    .off(i_off), .wdata(i_wdata), .ack(i_ack), .rdata(i_rdata),
    .sdclk(sdclk), .sdcmd(sdcmd), .sddat(sddat)
`ifdef VERILATOR
    , .sdcmd_in(sdcmd_in), .sddat_in(sddat_in)
`endif
);

// ---------------- DUART and the serial ports ----------------
wire       a_rx_valid, a_tx_empty, a_tx_rd;
wire [7:0] a_rx_data, a_tx_data;
wire       b_rx_valid, b_tx_empty;
wire [7:0] b_rx_data, b_tx_data;
reg        b_tx_rd;
duart #(.SYS_HZ(SYS_HZ)) du (
    .clk(clk), .rst_n(sys_rst_n), .rs(du_rs), .prs(du_prs), .we(du_we), .re(du_re), .wdata(du_wd),
    .rdata(du_q), .irq(duart_irq), .ivr_q(duart_ivr), .freeze(window),
    .a_rx_valid(a_rx_valid), .a_rx_data(a_rx_data), .a_tx_empty(a_tx_empty), .a_tx_data(a_tx_data), .a_tx_rd(a_tx_rd),
    .b_rx_valid(b_rx_valid), .b_rx_data(b_rx_data), .b_tx_empty(b_tx_empty), .b_tx_data(b_tx_data), .b_tx_rd(b_tx_rd)
);
uart_rx #(.DIV(UART_B_DIV)) brx (.clk(clk), .rst_n(por_n), .rx(uart_b_rx), .valid(b_rx_valid), .data(b_rx_data));
wire b_busy;
uart_tx #(.DIV(UART_B_DIV)) btx (.clk(clk), .rst_n(por_n), .start(b_tx_rd), .data(b_tx_data), .busy(b_busy), .tx(uart_b_tx));
always @(posedge clk) b_tx_rd <= !b_tx_empty && !b_busy && !b_tx_rd;

// ---------------- ICE ----------------
wire       cmd_valid;
wire [7:0] cmd_code, cmd_len, pay_raddr, pay_rdata;
wire       rsp_we, rsp_send, rsp_busy;
wire [7:0] rsp_waddr, rsp_wdata, rsp_code, rsp_len;
dbg_link #(.DIV(UART_DIV)) link (
    .clk(clk), .rst_n(por_n), .uart_rx(uart_rx), .uart_tx(uart_tx),
    .con_rx_valid(a_rx_valid), .con_rx_data(a_rx_data),
    .con_tx_empty(a_tx_empty), .con_tx_data(a_tx_data), .con_tx_rd(a_tx_rd),
    .cmd_valid(cmd_valid), .cmd_code(cmd_code), .cmd_len(cmd_len),
    .pay_raddr(pay_raddr), .pay_rdata(pay_rdata),
    .rsp_we(rsp_we), .rsp_waddr(rsp_waddr), .rsp_wdata(rsp_wdata),
    .rsp_send(rsp_send), .rsp_code(rsp_code), .rsp_len(rsp_len), .rsp_busy(rsp_busy)
);
dbg68k ice (
    .clk(clk), .rst_n(por_n),
    .cmd_valid(cmd_valid), .cmd_code(cmd_code), .cmd_len(cmd_len),
    .pay_raddr(pay_raddr), .pay_rdata(pay_rdata),
    .rsp_we(rsp_we), .rsp_waddr(rsp_waddr), .rsp_wdata(rsp_wdata),
    .rsp_send(rsp_send), .rsp_code(rsp_code), .rsp_len(rsp_len), .rsp_busy(rsp_busy),
    .bp_on(bp_on), .bp_addrs(bp_addrs), .wp_modes(wp_modes), .wp_los(wp_los), .wp_his(wp_his),
    .req_halt(req_halt), .sys_reset(dbg_reset), .halt_after_reset(halt_after_reset),
    .parked(parked), .cause(cause), .window(window), .stepping(stepping),
    .w_addr(w_addr), .w_val(w_val), .w_rw(w_rw),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata), .m_ack(m_ack), .m_rdata(m_rdata),
    .mb_addr(e_mb_addr), .mb_we(e_mb_we), .mb_wdata(e_mb_wdata), .mb_rdata(e_mb_rdata)
);

assign leds = {!a_tx_empty, stepping, window, kind == K_IDE && busy, overlay, sys_rst_n && !window};
endmodule
