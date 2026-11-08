// mc09_soc.v - a Multicomp09-compatible 6809 machine for the Tang Nano 20K:
// cpu09p (with the ICE ports), 8 KiB boot ROM in block RAM at $E000, up to
// 1 MiB of RAM in the SDRAM behind the Multicomp MMU, the console ACIA,
// the SD controller and the 50 Hz timer, and the ICE (dbg6809) on the same
// USB serial port as the console.
//
// The CPU runs from the 32 MHz system clock with a clock enable every
// CPU_DIV clocks; memory accesses stretch a CPU cycle with cpu09p's hold
// input until the data is there.
// GPL-3.0-or-later.
module mc09_soc #(
    parameter ROM_HEX  = "rom6809.hex",
    parameter RAM_KB   = 1024,
    parameter CPU_DIV  = 2,
    parameter UART_DIV = 278,       // 32 MHz / 115200
    parameter TICK     = 640000,    // 50 Hz
    parameter SIMULATE = 0
) (
    input         clk,
    input         por_n,          // power-on reset (also resets the ICE)
    input         reset_btn,      // reset button (the machine only)
    input         uart_rx,
    output        uart_tx,
    output [5:0]  leds,

    // SDRAM
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

    // SD card
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

// ---------------- resets ----------------
wire dbg_reset;
wire ram_ready;
reg [3:0] rst_sync;
always @(posedge clk or negedge por_n)
    if (!por_n) rst_sync <= 4'd0;
    else rst_sync <= {rst_sync[2:0], !(reset_btn || dbg_reset) && ram_ready};
wire sys_rst_n = rst_sync[3];

// ---------------- CPU ----------------
wire        c_vma, c_lic, c_ifetch, c_opfetch, c_ba, c_bs, c_rw;
wire [15:0] c_addr;
wire [7:0]  c_dout;
reg  [7:0]  c_din;
wire        c_halt, c_brk, c_hold;
wire [111:0] c_regs;
wire        c_halted;
wire [15:0] c_pcn;
wire        c_reg_we;
wire [3:0]  c_reg_sel;
wire [15:0] c_reg_wd;
wire        c_irq;

cpu09p_dbg cpu (
    .clk(clk), .rst_n(sys_rst_n), .vma(c_vma), .lic_out(c_lic), .ifetch(c_ifetch),
    .opfetch(c_opfetch), .ba(c_ba), .bs(c_bs), .addr(c_addr), .rw(c_rw),
    .data_out(c_dout), .data_in(c_din), .irq(c_irq), .firq(1'b0), .nmi(1'b0),
    .halt(c_halt), .hold(c_hold),
    .dbg_regs(c_regs), .dbg_halted(c_halted), .dbg_pcn(c_pcn), .dbg_brk(c_brk),
    .dbg_we(c_reg_we), .dbg_sel(c_reg_sel), .dbg_wd(c_reg_wd)
);

reg [3:0] div;
always @(posedge clk or negedge sys_rst_n)
    if (!sys_rst_n) div <= 4'd0;
    else div <= (div == CPU_DIV - 1) ? 4'd0 : div + 4'd1;
wire cen = (div == CPU_DIV - 1);

// ---------------- bus ----------------
// The ICE's bus master (used while the CPU is halted).
wire        m_req, m_we;
wire [1:0]  m_space;
wire [19:0] m_addr;
wire [7:0]  m_wdata;
reg         m_ack;
reg  [7:0]  m_rdata;

reg         acc_done;     // the CPU's current access has its data
reg         busy;         // an access is in flight (ROM or SDRAM)
reg         by_dbg;       // ... for the ICE
reg         dbg_cool;
reg  [7:0]  latch;

wire        use_dbg = c_halted && !c_vma;
wire [15:0] la = use_dbg ? m_addr[15:0] : c_addr;      // logical address
wire        phys_space = use_dbg && m_space == 2'd1;

wire [19:0] mmu_pa;
wire        mmu_ok, mmu_wp, rom_dis;
wire [19:0] pcn_pa;
wire        pcn_ok;
wire [7:0]  mapper;
wire        fixed_top;
wire [7:0]  map_q;
wire [3:0]  map_idx;

wire io_hit  = !phys_space && la[15:4] == 12'hffd;
wire rom_hit = !phys_space && la >= 16'he000 && !rom_dis && !io_hit;
wire [19:0] pa = phys_space ? m_addr : mmu_pa;
wire pa_ok = phys_space ? (m_addr < RAM_KB * 1024) : mmu_ok;
wire pa_wp = phys_space ? 1'b0 : mmu_wp;

// device registers
wire [7:0] acia_q, sd_q, timer_q, acia_ctl;
reg  [7:0] io_q;
always @* begin
    case (la[3:0])
    4'h0, 4'h1: io_q = acia_q;
    4'h2, 4'h4: io_q = 8'h02;
    4'h8, 4'h9: io_q = sd_q;
    4'hd: io_q = timer_q;
    default: io_q = 8'hff;
    endcase
end

// the CPU advances at this edge
wire cpu_access = c_vma && !use_dbg;
wire cpu_ready = !cpu_access || io_hit || acc_done;
assign c_hold = !(cen && cpu_ready);
wire cpu_adv = !c_hold;
wire io_we = cpu_adv && cpu_access && io_hit && !c_rw;
wire io_re = cpu_adv && cpu_access && io_hit && c_rw;
always @* c_din = (cpu_access && io_hit) ? io_q : latch;

// ROM
reg [7:0] rom [0:8191];
initial $readmemh(ROM_HEX, rom);
reg [7:0] rom_q;
always @(posedge clk) rom_q <= rom[la[12:0]];

// SDRAM
reg         s_req;
reg         s_we;
wire        s_ack;
wire [15:0] s_rdata;
reg  [19:0] s_pa;
reg         rom_wait;

always @(posedge clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        acc_done <= 1'b0; busy <= 1'b0; by_dbg <= 1'b0; latch <= 8'hff; m_ack <= 1'b0;
        m_rdata <= 8'hff; s_req <= 1'b0; s_we <= 1'b0; s_pa <= 20'd0; rom_wait <= 1'b0; dbg_cool <= 1'b0;
    end else begin
        m_ack <= 1'b0;
        dbg_cool <= 1'b0;
        if (cpu_adv) acc_done <= 1'b0;
        if (!busy) begin
            if (cpu_access && !io_hit && !acc_done && !cpu_adv) begin
                by_dbg <= 1'b0;
                if (rom_hit) begin
                    if (c_rw) begin busy <= 1'b1; rom_wait <= 1'b1; end
                    else acc_done <= 1'b1;
                end else if (!pa_ok || (!c_rw && pa_wp)) begin
                    latch <= 8'hff; acc_done <= 1'b1;
                end else begin
                    busy <= 1'b1; s_req <= 1'b1; s_we <= !c_rw; s_pa <= pa;
                end
            end else if (use_dbg && m_req && !m_ack && !dbg_cool) begin
                by_dbg <= 1'b1;
                if (io_hit) begin
                    // no side effects: reads see the registers, writes are dropped
                    m_rdata <= io_q; m_ack <= 1'b1; dbg_cool <= 1'b1;
                end else if (rom_hit) begin
                    if (!m_we) begin busy <= 1'b1; rom_wait <= 1'b1; end
                    else begin m_ack <= 1'b1; dbg_cool <= 1'b1; end
                end else if (!pa_ok || (m_we && pa_wp)) begin
                    m_rdata <= 8'hff; m_ack <= 1'b1; dbg_cool <= 1'b1;
                end else begin
                    busy <= 1'b1; s_req <= 1'b1; s_we <= m_we; s_pa <= pa;
                end
            end
        end else if (rom_wait) begin
            rom_wait <= 1'b0; busy <= 1'b0;
            if (by_dbg) begin m_rdata <= rom_q; m_ack <= 1'b1; dbg_cool <= 1'b1; end
            else begin latch <= rom_q; acc_done <= 1'b1; end
        end else if (s_ack) begin
            s_req <= 1'b0; busy <= 1'b0;
            if (by_dbg) begin
                m_rdata <= s_pa[0] ? s_rdata[7:0] : s_rdata[15:8]; m_ack <= 1'b1; dbg_cool <= 1'b1;
            end else begin
                latch <= s_pa[0] ? s_rdata[7:0] : s_rdata[15:8]; acc_done <= 1'b1;
            end
        end
    end
end
wire [7:0] s_wbyte = by_dbg ? m_wdata : c_dout;

sdram ram (
    .clk(clk), .rst_n(por_n), .ready(ram_ready),
    .req(s_req), .we(s_we), .addr({2'b00, s_pa[19:1]}), .wdata({s_wbyte, s_wbyte}),
    .be(s_pa[0] ? 2'b01 : 2'b10), .ack(s_ack), .rdata(s_rdata),
    .sd_clk(sd_clk), .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n),
    .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n), .sd_addr(sd_addr), .sd_ba(sd_ba),
    .sd_dqm(sd_dqm), .sd_dq_out(sd_dq_out), .sd_dq_oe(sd_dq_oe), .sd_dq_in(sd_dq_in)
);

// ---------------- devices ----------------
mc_mmu #(.RAM_KB(RAM_KB)) mmu (
    .clk(clk), .rst_n(sys_rst_n),
    .we_mapper(io_we && la[3:0] == 4'he), .we_map(io_we && la[3:0] == 4'hf), .wdata(c_dout),
    .a(la), .pa(mmu_pa), .pa_ok(mmu_ok), .wprot(mmu_wp),
    .b(c_pcn), .pb(pcn_pa), .pb_ok(pcn_ok),
    .rom_dis(rom_dis), .mapper(mapper), .fixed_top(fixed_top), .map_idx(map_idx), .map_q(map_q)
);

wire       con_rx_valid;
wire [7:0] con_rx_data;
wire       con_tx_empty, con_tx_rd;
wire [7:0] con_tx_data;
wire       acia_irq;
mc_acia acia (
    .clk(clk), .rst_n(sys_rst_n), .rs(la[0]),
    .we(io_we && la[3:1] == 3'd0), .re(io_re && la[3:1] == 3'd0), .wdata(c_dout),
    .rdata(acia_q), .irq(acia_irq), .control_q(acia_ctl),
    .rx_valid(con_rx_valid), .rx_data(con_rx_data),
    .tx_empty(con_tx_empty), .tx_data(con_tx_data), .tx_rd(con_tx_rd)
);

wire [2:0] sd_state;
mc_sd #(.SIMULATE(SIMULATE)) sdc (
    .clk(clk), .rst_n(sys_rst_n), .reg_(la[2:0]),
    .we(io_we && la[3] && la[2:0] <= 3'd4), .re(io_re && la[3] && la[2:0] <= 3'd4),
    .wdata(c_dout), .rdata(sd_q), .state_q(sd_state),
    .sdclk(sdclk), .sdcmd(sdcmd), .sddat(sddat)
`ifdef VERILATOR
    , .sdcmd_in(sdcmd_in), .sddat_in(sddat_in)
`endif
);

mc_timer #(.TICK(TICK)) tmr (
    .clk(clk), .rst_n(sys_rst_n), .we(io_we && la[3:0] == 4'hd), .wdata(c_dout),
    .freeze(c_halted), .timer(timer_q)
);

wire irq_block;
assign c_irq = (timer_q[7] || acia_irq) && !irq_block;

// ---------------- ICE ----------------
wire       cmd_valid;
wire [7:0] cmd_code, cmd_len, pay_raddr, pay_rdata;
wire       rsp_we, rsp_send, rsp_busy;
wire [7:0] rsp_waddr, rsp_wdata, rsp_code, rsp_len;

dbg_link #(.DIV(UART_DIV)) link (
    .clk(clk), .rst_n(por_n), .uart_rx(uart_rx), .uart_tx(uart_tx),
    .con_rx_valid(con_rx_valid), .con_rx_data(con_rx_data),
    .con_tx_empty(con_tx_empty), .con_tx_data(con_tx_data), .con_tx_rd(con_tx_rd),
    .cmd_valid(cmd_valid), .cmd_code(cmd_code), .cmd_len(cmd_len),
    .pay_raddr(pay_raddr), .pay_rdata(pay_rdata),
    .rsp_we(rsp_we), .rsp_waddr(rsp_waddr), .rsp_wdata(rsp_wdata),
    .rsp_send(rsp_send), .rsp_code(rsp_code), .rsp_len(rsp_len), .rsp_busy(rsp_busy)
);

// device state for the ICE (space 2): maps 0-15, mapper, flags, timer,
// ACIA control, SD state
wire [7:0] dev_addr;
reg  [7:0] dev_q;
assign map_idx = dev_addr[3:0];
always @* begin
    if (dev_addr < 8'd16) dev_q = map_q;
    else case (dev_addr)
    8'd16: dev_q = mapper;
    8'd17: dev_q = {6'd0, rom_dis, fixed_top};
    8'd18: dev_q = timer_q;
    8'd19: dev_q = acia_ctl;
    8'd20: dev_q = {5'd0, sd_state};
    default: dev_q = 8'hff;
    endcase
end

dbg6809 #(.RAM_KB(RAM_KB)) ice (
    .clk(clk), .rst_n(por_n),
    .cmd_valid(cmd_valid), .cmd_code(cmd_code), .cmd_len(cmd_len),
    .pay_raddr(pay_raddr), .pay_rdata(pay_rdata),
    .rsp_we(rsp_we), .rsp_waddr(rsp_waddr), .rsp_wdata(rsp_wdata),
    .rsp_send(rsp_send), .rsp_code(rsp_code), .rsp_len(rsp_len), .rsp_busy(rsp_busy),
    .regs(c_regs), .halted(c_halted), .pcn(c_pcn), .pcn_phys(pcn_pa), .pcn_phys_ok(pcn_ok),
    .lic(c_lic), .cpu_adv(cpu_adv), .vma(c_vma), .ifetch(c_ifetch), .rw(c_rw), .addr(c_addr),
    .data_out(c_dout), .data_in(c_din),
    .halt(c_halt), .brk(c_brk), .reg_we(c_reg_we), .reg_sel(c_reg_sel), .reg_wd(c_reg_wd),
    .irq_block(irq_block), .sys_reset(dbg_reset),
    .m_req(m_req), .m_space(m_space), .m_addr(m_addr), .m_we(m_we), .m_wdata(m_wdata),
    .m_ack(m_ack), .m_rdata(m_rdata), .dev_rdata(dev_q), .dev_addr(dev_addr)
);

// LEDs: running, halted by the ICE, SD busy, MMU on, ROM off, console activity
assign leds = {!con_tx_empty, rom_dis, mapper[5], sd_state != 3'd0, c_halted, sys_rst_n && !c_halted};

endmodule
