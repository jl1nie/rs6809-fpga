// dbg6809.v - the ICE engine of the 6809 machine.
//
// cpu09p_dbg stops at an instruction boundary when its halt input is high
// (or dbg_brk, a breakpoint on the next PC), shows its registers and takes
// register writes while halted. Halted, the CPU leaves the bus alone and
// this engine reads and writes memory through the machine's bus (logical
// addresses through the MMU, or physical RAM), without the side effects a
// CPU access to a device would have.
//
// Commands (dbg_link framing; every command gets one response):
//   'I'                      -> 'i' cpu=$09 version nbp nwp ramkb(2)
//   'Q'                      -> 'q' halted cause pc(2)
//   'H'                      -> 'k'  stop (an 'S' event follows)
//   'G'                      -> 'k'  run
//   'T'                      -> 'k'  one instruction (an 'S' event follows)
//   'R'                      -> 'r' cc a b dp x(2) y(2) u(2) s(2) pc(2)
//   'W' sel v(2)             -> 'k'  set a register (0 CC 1 A 2 B 3 DP 4 X 5 Y 6 U 7 S 8 PC)
//   'M' space a(3) n         -> 'm' n bytes (n=0: 256). space 0 CPU, 1 physical, 2 devices
//   'P' space a(3) data...   -> 'k'
//   'B' i flags a(3)         -> 'k'  breakpoint i: flags bit0 on, bit1 physical address
//   'X' i mode lo(2) hi(2)   -> 'k'  watchpoint i: mode bit0 read, bit1 write
//   'Z' mode                 -> 'k'  reset the machine; mode bit0: stop at the first instruction
// Event: 'S' cause pc(2) waddr(2) wval wrw  (cause 1 stop, 2 breakpoint,
//   3 step, 4 watchpoint, 5 reset)
// While a step runs, interrupts are held off (irq_block).
// GPL-3.0-or-later.
module dbg6809 #(parameter RAM_KB = 1024, parameter NBP = 8, parameter NWP = 4) (
    input             clk,
    input             rst_n,

    // link
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

    // CPU
    input     [111:0] regs,
    input             halted,
    input      [15:0] pcn,
    input      [19:0] pcn_phys,
    input             pcn_phys_ok,
    input             lic,
    input             cpu_adv,      // the CPU advances on this clock edge
    input             vma,
    input             ifetch,
    input             rw,
    input      [15:0] addr,
    input      [7:0]  data_out,
    input      [7:0]  data_in,
    output            halt,
    output            brk,
    output reg        reg_we,
    output reg [3:0]  reg_sel,
    output reg [15:0] reg_wd,
    output            irq_block,
    output reg        sys_reset,    // reset the CPU and the devices

    // bus master (used while halted)
    output reg        m_req,
    output reg [1:0]  m_space,
    output reg [19:0] m_addr,
    output reg        m_we,
    output reg [7:0]  m_wdata,
    input             m_ack,
    input      [7:0]  m_rdata,
    // device state (space 2)
    input      [7:0]  dev_rdata,
    output     [7:0]  dev_addr
);

// ---------------- breakpoints, watchpoints, halt ----------------
reg [NBP-1:0] bp_on, bp_phys;
reg [19:0]    bp_addr [0:NBP-1];
reg [1:0]     wp_mode [0:NWP-1];
reg [15:0]    wp_lo [0:NWP-1];
reg [15:0]    wp_hi [0:NWP-1];

reg halt_req, step_release, stepping;
reg [2:0] cause;
reg [15:0] w_addr;
reg [7:0]  w_val;
reg        w_rw;

integer k, kr;
reg bp_match;
always @* begin
    bp_match = 1'b0;
    for (k = 0; k < NBP; k = k + 1)
        if (bp_on[k] && (bp_phys[k] ? (pcn_phys_ok && pcn_phys == bp_addr[k]) : (pcn == bp_addr[k][15:0])))
            bp_match = 1'b1;
end
reg wp_now;
always @* begin
    wp_now = 1'b0;
    for (k = 0; k < NWP; k = k + 1)
        if (vma && !ifetch && wp_mode[k][rw ? 0 : 1] && addr >= wp_lo[k] && addr <= wp_hi[k])
            wp_now = 1'b1;
end
// a breakpoint stops before the instruction at pcn; not while stepping
assign brk = bp_match && lic && !stepping && !step_release;
assign halt = (halt_req && !step_release) || (wp_now && !halted);
assign irq_block = stepping || step_release;

// ---------------- command engine ----------------
localparam E_IDLE = 4'd0, E_ARGS = 4'd1, E_EXEC = 4'd2, E_MEMRD = 4'd3, E_MEMWR = 4'd4,
           E_RSP = 4'd5, E_EVENT = 4'd6, E_WAITRSP = 4'd7, E_REGS = 4'd8, E_DEV = 4'd9,
           E_RESET = 4'd10;
reg [3:0]  es;
reg [7:0]  code, len;
reg [7:0]  arg [0:6];
reg [7:0]  ai;              // argument index being read
reg        ai_valid;
reg [8:0]  cnt, n;          // memory transfer
reg [7:0]  ri;
reg        was_halted;
reg        event_pending;
reg [2:0]  settle;
reg [4:0]  rst_cnt;
reg [1:0]  we_cnt;
assign dev_addr = m_addr[7:0];

task respond(input [7:0] c, input [7:0] l);
begin
    rsp_code <= c; rsp_len <= l; rsp_send <= 1'b1; es <= E_IDLE;
end
endtask

wire [7:0] regbyte [0:13];
genvar g;
generate for (g = 0; g < 14; g = g + 1) begin : rb
    assign regbyte[g] = regs[111 - 8*g -: 8];
end endgenerate

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        es <= E_IDLE; halt_req <= 1'b0; step_release <= 1'b0; stepping <= 1'b0;
        cause <= 3'd0; bp_on <= 0; bp_phys <= 0;
        for (kr = 0; kr < NWP; kr = kr + 1) wp_mode[kr] <= 2'd0;
        rsp_we <= 1'b0; rsp_send <= 1'b0; pay_raddr <= 8'd0; m_req <= 1'b0;
        reg_we <= 1'b0; sys_reset <= 1'b0; was_halted <= 1'b0; event_pending <= 1'b0;
        settle <= 3'd0; w_addr <= 0; w_val <= 0; w_rw <= 0; rst_cnt <= 0; we_cnt <= 0;
        code <= 0; len <= 0; ai <= 0; ai_valid <= 0; cnt <= 0; n <= 0; ri <= 0;
        m_space <= 0; m_addr <= 0; m_we <= 0; m_wdata <= 0; reg_sel <= 0; reg_wd <= 0;
        rsp_code <= 0; rsp_len <= 0; rsp_waddr <= 0; rsp_wdata <= 0;
    end else begin
        rsp_we <= 1'b0;
        rsp_send <= 1'b0;

        // register write pulse: two clocks, so that it meets a CPU clock
        if (we_cnt != 2'd0) we_cnt <= we_cnt - 2'd1;
        else reg_we <= 1'b0;

        // stop conditions seen while running
        if (cpu_adv && wp_now && !halted && !halt_req) begin
            halt_req <= 1'b1; cause <= 3'd4;
            w_addr <= addr; w_val <= rw ? data_in : data_out; w_rw <= rw;
        end else if (cpu_adv && brk && !halt_req) begin
            halt_req <= 1'b1; cause <= 3'd2;
        end
        if (step_release && !halted) begin
            step_release <= 1'b0; stepping <= 1'b1;
        end
        // the CPU has stopped: report it once its registers have settled
        if (!halted) begin
            settle <= 3'd0;
            was_halted <= 1'b0;
        end else if (!was_halted && !step_release) begin
            if (settle == 3'd4) begin
                was_halted <= 1'b1;
                event_pending <= 1'b1;
                if (stepping) begin
                    stepping <= 1'b0;
                    if (cause != 3'd4) cause <= 3'd3;
                end
            end else settle <= settle + 3'd1;
        end

        case (es)
        E_IDLE: begin
            if (cmd_valid) begin
                code <= cmd_code; len <= cmd_len; ai <= 8'd0; pay_raddr <= 8'd0; ai_valid <= 1'b0;
                es <= E_ARGS;
            end else if (event_pending && !rsp_busy && !rsp_send) begin
                event_pending <= 1'b0;
                ri <= 8'd0;
                es <= E_EVENT;
            end
        end
        E_ARGS: begin
            // up to 7 argument bytes from the payload buffer (read
            // combinationally at pay_raddr)
            if (ai_valid) begin
                arg[ai[2:0]] <= pay_rdata; ai <= ai + 8'd1; ai_valid <= 1'b0;
            end else if (ai < len && ai < 8'd7) begin
                pay_raddr <= ai; ai_valid <= 1'b1;
            end else if (!rsp_busy && !rsp_send) es <= E_EXEC;
        end
        E_EXEC: begin
            case (code)
            "I": begin
                rsp_we <= 1'b1; rsp_waddr <= 8'd0; rsp_wdata <= 8'h09;
                ri <= 8'd1; es <= E_RSP;
            end
            "Q": begin ri <= 8'd0; es <= E_RSP; end
            "H": begin
                if (!halt_req) begin halt_req <= 1'b1; cause <= 3'd1; end
                respond("k", 8'd0);
            end
            "G": begin
                halt_req <= 1'b0;
                respond("k", 8'd0);
            end
            "T": begin
                if (halted && was_halted) begin
                    step_release <= 1'b1; cause <= 3'd3;
                    respond("k", 8'd0);
                end else respond("e", 8'd0);
            end
            "R": begin ri <= 8'd0; es <= E_REGS; end
            "W": begin
                if (halted) begin
                    reg_we <= 1'b1; we_cnt <= 2'd2; reg_sel <= arg[0][3:0]; reg_wd <= {arg[1], arg[2]};
                    respond("k", 8'd0);
                end else respond("e", 8'd0);
            end
            "M": begin
                m_space <= arg[0][1:0]; m_addr <= {arg[1][3:0], arg[2], arg[3]};
                n <= (arg[4] == 8'd0) ? 9'd256 : {1'b0, arg[4]}; cnt <= 9'd0;
                if (!halted || !was_halted) respond("e", 8'd0);
                else if (arg[0][1:0] == 2'd2) es <= E_DEV;
                else begin m_req <= 1'b1; m_we <= 1'b0; es <= E_MEMRD; end
            end
            "P": begin
                m_space <= arg[0][1:0]; m_addr <= {arg[1][3:0], arg[2], arg[3]};
                n <= {1'b0, len} - 9'd4; cnt <= 9'd0;
                if (!halted || !was_halted || len <= 8'd4 || arg[0][1:0] == 2'd2) respond(len <= 8'd4 ? "k" : "e", 8'd0);
                else begin pay_raddr <= 8'd4; ai_valid <= 1'b0; es <= E_MEMWR; end
            end
            "B": begin
                if (arg[0] < NBP) begin
                    bp_on[arg[0][2:0]] <= arg[1][0];
                    bp_phys[arg[0][2:0]] <= arg[1][1];
                    bp_addr[arg[0][2:0]] <= {arg[2][3:0], arg[3], arg[4]};
                end
                respond("k", 8'd0);
            end
            "X": begin
                if (arg[0] < NWP) begin
                    wp_mode[arg[0][1:0]] <= arg[1][1:0];
                    wp_lo[arg[0][1:0]] <= {arg[2], arg[3]};
                    wp_hi[arg[0][1:0]] <= {arg[4], arg[5]};
                end
                respond("k", 8'd0);
            end
            "Z": begin
                halt_req <= arg[0][0] && len != 0;
                cause <= 3'd5; step_release <= 1'b0; stepping <= 1'b0;
                sys_reset <= 1'b1; rst_cnt <= 5'd31; es <= E_RESET;
            end
            default: respond("e", 8'd0);
            endcase
        end
        E_RESET: begin
            if (rst_cnt != 0) rst_cnt <= rst_cnt - 5'd1;
            else begin sys_reset <= 1'b0; respond("k", 8'd0); end
        end
        E_RSP: begin
            // the short fixed responses 'i' and 'q'
            rsp_we <= 1'b1; rsp_waddr <= ri; ri <= ri + 8'd1;
            if (code == "I") begin
                case (ri)
                8'd1: rsp_wdata <= 8'd1;
                8'd2: rsp_wdata <= NBP;
                8'd3: rsp_wdata <= NWP;
                8'd4: rsp_wdata <= RAM_KB & 8'hff;
                default: rsp_wdata <= RAM_KB >> 8;
                endcase
                if (ri == 8'd5) respond("i", 8'd6);
            end else begin
                case (ri)
                8'd0: rsp_wdata <= {7'd0, halted && was_halted};
                8'd1: rsp_wdata <= {5'd0, cause};
                8'd2: rsp_wdata <= regs[15:8];
                default: rsp_wdata <= regs[7:0];
                endcase
                if (ri == 8'd3) respond("q", 8'd4);
            end
        end
        E_EVENT: begin
            rsp_we <= 1'b1; rsp_waddr <= ri; ri <= ri + 8'd1;
            case (ri)
            8'd0: rsp_wdata <= {5'd0, cause};
            8'd1: rsp_wdata <= regs[15:8];
            8'd2: rsp_wdata <= regs[7:0];
            8'd3: rsp_wdata <= w_addr[15:8];
            8'd4: rsp_wdata <= w_addr[7:0];
            8'd5: rsp_wdata <= w_val;
            default: rsp_wdata <= {7'd0, w_rw};
            endcase
            if (ri == 8'd6) respond("S", 8'd7);
        end
        E_REGS: begin
            rsp_we <= 1'b1; rsp_waddr <= ri; rsp_wdata <= regbyte[ri[3:0]]; ri <= ri + 8'd1;
            if (ri == 8'd13) respond("r", 8'd14);
        end
        E_DEV: begin
            rsp_we <= 1'b1; rsp_waddr <= cnt[7:0]; rsp_wdata <= dev_rdata;
            m_addr <= m_addr + 20'd1; cnt <= cnt + 9'd1;
            if (cnt + 9'd1 == n) respond("m", n[7:0]);
        end
        E_MEMRD: begin
            if (m_ack) begin
                m_req <= 1'b0;
                rsp_we <= 1'b1; rsp_waddr <= cnt[7:0]; rsp_wdata <= m_rdata;
                cnt <= cnt + 9'd1;
                m_addr <= m_addr + 20'd1;
                if (cnt + 9'd1 == n) respond("m", n[7:0]);
            end else if (!m_req) m_req <= 1'b1;
        end
        E_MEMWR: begin
            // payload byte at pay_raddr arrives one clock later
            if (!m_req && !ai_valid) ai_valid <= 1'b1;
            else if (!m_req && ai_valid) begin
                m_wdata <= pay_rdata; m_we <= 1'b1; m_req <= 1'b1; ai_valid <= 1'b0;
            end else if (m_ack) begin
                m_req <= 1'b0; m_we <= 1'b0;
                cnt <= cnt + 9'd1; m_addr <= m_addr + 20'd1;
                pay_raddr <= pay_raddr + 8'd1;
                if (cnt + 9'd1 == n) respond("k", 8'd0);
            end
        end
        default: es <= E_IDLE;
        endcase
    end
end
endmodule
