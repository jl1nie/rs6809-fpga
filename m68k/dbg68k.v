// dbg68k.v - the ICE engine of the 68000 machine. fx68k is used as it is:
// the debug unit in t68k_soc.v takes the CPU into a stub monitor in a
// hidden debug window (m68k/rom/stub.S), which saves the registers in a
// mailbox and runs the host's continue/step commands. This engine speaks
// the dbg_link protocol, keeps the breakpoints and watchpoints, and reads
// and writes memory (SDRAM and ROM directly, space 0) and the mailbox
// (space 3).
//
// Commands (every command gets one response):
//   'I'                      -> 'i' cpu=$68 version nbp nwp ramkb(2)
//   'Q'                      -> 'q' parked cause window stepping
//   'H'                      -> 'k'  stop: enter the stub (an 'S' event follows)
//   'M' space a(3) n         -> 'm' n bytes (n=0: 256)
//   'P' space a(3) data...   -> 'k'
//   'B' i flags a(3)         -> 'k'  breakpoint i (flags bit0 on)
//   'X' i mode lo(3) hi(3)   -> 'k'  watchpoint i (mode bit0 read, bit1 write)
//   'Z' mode                 -> 'k'  reset; mode bit0: stop after the first instruction
// Event: 'S' cause waddr(3) wval(2) wrw   (cause 1 stop, 2 breakpoint (or an
//   ILLEGAL), 3 step, 4 watchpoint, 5 reset). Continue and step are mailbox
//   writes (see stub.S).
// GPL-3.0-or-later.
module dbg68k #(parameter RAM_KB = 8192, parameter NBP = 8, parameter NWP = 4) (
    input             clk,
    input             rst_n,

    input             cmd_valid,
    input      [7:0]  cmd_code,
    input      [7:0]  cmd_len,
    output reg [7:0]  pay_raddr,
    input      [7:0]  pay_rdata,
    output reg        rsp_we,
    output reg [7:0]  rsp_waddr,
    output reg [7:0]  rsp_wdata,
    output reg        rsp_send,
    output reg [7:0]  rsp_code,
    output reg [7:0]  rsp_len,
    input             rsp_busy,

    // debug unit
    output reg [NBP-1:0]    bp_on,
    output     [NBP*24-1:0] bp_addrs,
    output     [NWP*2-1:0]  wp_modes,
    output     [NWP*24-1:0] wp_los,
    output     [NWP*24-1:0] wp_his,
    output reg        req_halt,       // one clock
    output reg        sys_reset,
    output reg        halt_after_reset,
    input             parked,         // the stub has saved the registers
    input      [2:0]  cause,
    input             window,
    input             stepping,
    input      [23:0] w_addr,
    input      [15:0] w_val,
    input             w_rw,

    // memory (space 0)
    output reg        m_req,
    output reg        m_we,
    output reg [23:0] m_addr,
    output reg [7:0]  m_wdata,
    input             m_ack,
    input      [7:0]  m_rdata,
    // mailbox (space 3), synchronous read
    output reg [9:0]  mb_addr,
    output reg        mb_we,
    output reg [7:0]  mb_wdata,
    input      [7:0]  mb_rdata
);
reg [23:0] bp_addr [0:NBP-1];
reg [1:0]  wp_mode [0:NWP-1];
reg [23:0] wp_lo [0:NWP-1];
reg [23:0] wp_hi [0:NWP-1];
genvar g;
generate
    for (g = 0; g < NBP; g = g + 1) begin : bpa assign bp_addrs[g*24 +: 24] = bp_addr[g]; end
    for (g = 0; g < NWP; g = g + 1) begin : wpa
        assign wp_modes[g*2 +: 2] = wp_mode[g];
        assign wp_los[g*24 +: 24] = wp_lo[g];
        assign wp_his[g*24 +: 24] = wp_hi[g];
    end
endgenerate

localparam E_IDLE = 4'd0, E_ARGS = 4'd1, E_EXEC = 4'd2, E_MEMRD = 4'd3, E_MEMWR = 4'd4,
           E_RSP = 4'd5, E_EVENT = 4'd6, E_MBRD = 4'd7, E_MBWR = 4'd8, E_RESET = 4'd9;
reg [3:0]  es;
reg [7:0]  code, len;
reg [7:0]  arg [0:7];
reg [7:0]  ai;
reg        ai_valid;
reg [8:0]  cnt, n;
reg [7:0]  ri;
reg        was_parked, event_pending;
reg [1:0]  wait_;
reg [5:0]  rst_cnt;
integer k;

task respond(input [7:0] c, input [7:0] l);
begin
    rsp_code <= c; rsp_len <= l; rsp_send <= 1'b1; es <= E_IDLE;
end
endtask

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        es <= E_IDLE; bp_on <= 0; req_halt <= 1'b0; sys_reset <= 1'b0; halt_after_reset <= 1'b0;
        for (k = 0; k < NWP; k = k + 1) wp_mode[k] <= 2'd0;
        rsp_we <= 0; rsp_send <= 0; rsp_waddr <= 0; rsp_wdata <= 0; rsp_code <= 0; rsp_len <= 0;
        pay_raddr <= 0; m_req <= 0; m_we <= 0; m_addr <= 0; m_wdata <= 0;
        mb_addr <= 0; mb_we <= 0; mb_wdata <= 0; was_parked <= 0; event_pending <= 0;
        code <= 0; len <= 0; ai <= 0; ai_valid <= 0; cnt <= 0; n <= 0; ri <= 0; wait_ <= 0; rst_cnt <= 0;
    end else begin
        rsp_we <= 1'b0;
        rsp_send <= 1'b0;
        req_halt <= 1'b0;
        mb_we <= 1'b0;
        if (parked && !was_parked) event_pending <= 1'b1;
        was_parked <= parked;

        case (es)
        E_IDLE: begin
            if (cmd_valid) begin
                code <= cmd_code; len <= cmd_len; ai <= 8'd0; ai_valid <= 1'b0; es <= E_ARGS;
            end else if (event_pending && !rsp_busy && !rsp_send) begin
                event_pending <= 1'b0; ri <= 8'd0; es <= E_EVENT;
            end
        end
        E_ARGS: begin
            if (ai_valid) begin
                arg[ai[2:0]] <= pay_rdata; ai <= ai + 8'd1; ai_valid <= 1'b0;
            end else if (ai < len && ai < 8'd8) begin
                pay_raddr <= ai; ai_valid <= 1'b1;
            end else if (!rsp_busy && !rsp_send) es <= E_EXEC;
        end
        E_EXEC: begin
            ri <= 8'd0;
            case (code)
            "I", "Q": es <= E_RSP;
            "H": begin if (!parked) req_halt <= 1'b1; respond("k", 8'd0); end
            "M": begin
                m_addr <= {arg[1], arg[2], arg[3]};
                mb_addr <= {arg[2][1:0], arg[3]};
                n <= (arg[4] == 8'd0) ? 9'd256 : {1'b0, arg[4]}; cnt <= 9'd0; wait_ <= 2'd0;
                if (arg[0] == 8'd3) es <= E_MBRD;
                else if (arg[0] == 8'd0) begin m_req <= 1'b1; m_we <= 1'b0; es <= E_MEMRD; end
                else respond("e", 8'd0);
            end
            "P": begin
                m_addr <= {arg[1], arg[2], arg[3]};
                mb_addr <= {arg[2][1:0], arg[3]};
                n <= {1'b0, len} - 9'd4; cnt <= 9'd0; wait_ <= 2'd0;
                pay_raddr <= 8'd4; ai_valid <= 1'b0;
                if (len <= 8'd4) respond("k", 8'd0);
                else if (arg[0] == 8'd3) es <= E_MBWR;
                else if (arg[0] == 8'd0) es <= E_MEMWR;
                else respond("e", 8'd0);
            end
            "B": begin
                if (arg[0] < NBP) begin
                    bp_on[arg[0][2:0]] <= arg[1][0];
                    bp_addr[arg[0][2:0]] <= {arg[2], arg[3], arg[4][7:1], 1'b0};
                end
                respond("k", 8'd0);
            end
            "X": begin
                if (arg[0] < NWP) begin
                    wp_mode[arg[0][1:0]] <= arg[1][1:0];
                    wp_lo[arg[0][1:0]] <= {arg[2], arg[3], arg[4]};
                    wp_hi[arg[0][1:0]] <= {arg[5], arg[6], arg[7]};
                end
                respond("k", 8'd0);
            end
            "Z": begin
                halt_after_reset <= (len != 8'd0) && arg[0][0];
                sys_reset <= 1'b1; rst_cnt <= 6'd63; es <= E_RESET;
            end
            default: respond("e", 8'd0);
            endcase
        end
        E_RESET: begin
            if (rst_cnt != 0) rst_cnt <= rst_cnt - 6'd1;
            else begin sys_reset <= 1'b0; respond("k", 8'd0); end
        end
        E_RSP: begin
            rsp_we <= 1'b1; rsp_waddr <= ri; ri <= ri + 8'd1;
            if (code == "I") begin
                case (ri)
                8'd0: rsp_wdata <= 8'h68;
                8'd1: rsp_wdata <= 8'd1;
                8'd2: rsp_wdata <= NBP;
                8'd3: rsp_wdata <= NWP;
                8'd4: rsp_wdata <= RAM_KB & 8'hff;
                default: rsp_wdata <= RAM_KB >> 8;
                endcase
                if (ri == 8'd5) respond("i", 8'd6);
            end else begin
                case (ri)
                8'd0: rsp_wdata <= {7'd0, parked};
                8'd1: rsp_wdata <= {5'd0, cause};
                8'd2: rsp_wdata <= {7'd0, window};
                default: rsp_wdata <= {7'd0, stepping};
                endcase
                if (ri == 8'd3) respond("q", 8'd4);
            end
        end
        E_EVENT: begin
            rsp_we <= 1'b1; rsp_waddr <= ri; ri <= ri + 8'd1;
            case (ri)
            8'd0: rsp_wdata <= {5'd0, cause};
            8'd1: rsp_wdata <= w_addr[23:16];
            8'd2: rsp_wdata <= w_addr[15:8];
            8'd3: rsp_wdata <= w_addr[7:0];
            8'd4: rsp_wdata <= w_val[15:8];
            8'd5: rsp_wdata <= w_val[7:0];
            default: rsp_wdata <= {7'd0, w_rw};
            endcase
            if (ri == 8'd6) respond("S", 8'd7);
        end
        E_MEMRD: begin
            if (m_ack) begin
                m_req <= 1'b0;
                rsp_we <= 1'b1; rsp_waddr <= cnt[7:0]; rsp_wdata <= m_rdata;
                cnt <= cnt + 9'd1; m_addr <= m_addr + 24'd1;
                if (cnt + 9'd1 == n) respond("m", n[7:0]);
            end else if (!m_req) m_req <= 1'b1;
        end
        E_MEMWR: begin
            if (!m_req && !ai_valid) ai_valid <= 1'b1;
            else if (!m_req && ai_valid) begin
                m_wdata <= pay_rdata; m_we <= 1'b1; m_req <= 1'b1; ai_valid <= 1'b0;
            end else if (m_ack) begin
                m_req <= 1'b0; m_we <= 1'b0;
                cnt <= cnt + 9'd1; m_addr <= m_addr + 24'd1; pay_raddr <= pay_raddr + 8'd1;
                if (cnt + 9'd1 == n) respond("k", 8'd0);
            end
        end
        E_MBRD: begin
            // mb_rdata follows mb_addr one clock later
            if (wait_ != 2'd2) wait_ <= wait_ + 2'd1;
            else begin
                rsp_we <= 1'b1; rsp_waddr <= cnt[7:0]; rsp_wdata <= mb_rdata;
                cnt <= cnt + 9'd1; mb_addr <= mb_addr + 10'd1; wait_ <= 2'd0;
                if (cnt + 9'd1 == n) respond("m", n[7:0]);
            end
        end
        E_MBWR: begin
            if (!ai_valid) ai_valid <= 1'b1;
            else begin
                mb_we <= 1'b1; mb_wdata <= pay_rdata; ai_valid <= 1'b0;
                cnt <= cnt + 9'd1; pay_raddr <= pay_raddr + 8'd1;
                if (cnt + 9'd1 == n) respond("k", 8'd0);
            end
            if (mb_we) mb_addr <= mb_addr + 10'd1;
        end
        default: es <= E_IDLE;
        endcase
    end
end
endmodule
