// sdram.v - controller for the SDRAM inside the Tang Nano 20K's GW2AR-18
// (64 Mbit, 32 bits wide: 4 banks x 2048 rows x 256 columns).
//
// The CPU side is a request/acknowledge port with 16-bit words and byte
// enables; a 22-bit word address covers the whole 8 MiB. Word address bit 0
// selects the half of the 32-bit SDRAM word (0: bits 31-16, 1: bits 15-0),
// so the memory reads as big-endian 16-bit words.
//
// Timing follows MiSTeryNano's sdram.v (Till Harbaum, GPL-3.0-or-later),
// which runs this chip at 32 MHz: the SDRAM clock is the inverted system
// clock, tRCD is one cycle, CAS latency 2 and read data is taken three
// cycles after the READ command was registered. Every access is a single
// word with auto-precharge, so no bank is left open. Refresh is issued by
// the controller itself every REFRESH_CYCLES cycles, between accesses.
//
// Copyright (C) 2026 rs6809-fpga contributors. GPL-3.0-or-later.
module sdram #(
    parameter REFRESH_CYCLES = 16'd480,   // 15 us at 32 MHz (4096 rows / 64 ms)
    parameter INIT_CYCLES    = 16'd6400   // 200 us at 32 MHz
) (
    input             clk,
    input             rst_n,
    output            ready,      // initialised

    input             req,        // start an access (held until ack)
    input             we,
    input      [21:0] addr,       // 16-bit word address
    input      [15:0] wdata,
    input      [1:0]  be,         // byte enables: [1] bits 15-8, [0] bits 7-0
    output reg        ack,        // one cycle: done (rdata valid on a read)
    output reg [15:0] rdata,

    output            sd_clk,
    output            sd_cke,
    output            sd_cs_n,
    output            sd_ras_n,
    output            sd_cas_n,
    output            sd_we_n,
    output reg [10:0] sd_addr,
    output reg [1:0]  sd_ba,
    output reg [3:0]  sd_dqm,
    output reg [31:0] sd_dq_out,
    output reg        sd_dq_oe,
    input      [31:0] sd_dq_in
);

assign sd_clk = ~clk;
assign sd_cke = 1'b1;

localparam CMD_INHIBIT  = 4'b1111;
localparam CMD_NOP      = 4'b0111;
localparam CMD_ACTIVE   = 4'b0011;
localparam CMD_READ     = 4'b0101;
localparam CMD_WRITE    = 4'b0100;
localparam CMD_PRECHARGE= 4'b0010;
localparam CMD_REFRESH  = 4'b0001;
localparam CMD_MODE     = 4'b0000;

// burst 1, sequential, CAS 2, single writes
localparam [10:0] MODE = 11'b00_1_00_010_0_000;

reg [3:0] cmd;
assign {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} = cmd;

localparam S_INIT = 3'd0, S_IDLE = 3'd1, S_RW = 3'd2, S_WAIT = 3'd3, S_REF = 3'd4;
reg [2:0]  state;
reg [15:0] count;
reg [3:0]  init_step;
reg [15:0] ref_count;
reg [3:0]  phase;
reg        is_we, half;

assign ready = (state != S_INIT);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_INIT;
        count <= INIT_CYCLES;
        init_step <= 4'd0;
        cmd <= CMD_INHIBIT;
        sd_addr <= 11'd0;
        sd_ba <= 2'd0;
        sd_dqm <= 4'b1111;
        sd_dq_oe <= 1'b0;
        sd_dq_out <= 32'd0;
        ack <= 1'b0;
        rdata <= 16'd0;
        ref_count <= 16'd0;
        phase <= 4'd0;
        is_we <= 1'b0;
        half <= 1'b0;
    end else begin
        cmd <= CMD_NOP;
        ack <= 1'b0;
        sd_dq_oe <= 1'b0;
        if (state != S_INIT && ref_count != 16'd0)
            ref_count <= ref_count - 16'd1;
        case (state)
        S_INIT: begin
            // 200 us of NOPs, then precharge all, eight refreshes and the
            // mode register, each followed by a few idle cycles.
            if (count != 16'd0) count <= count - 16'd1;
            else begin
                count <= 16'd7;
                init_step <= init_step + 4'd1;
                case (init_step)
                4'd0: begin cmd <= CMD_PRECHARGE; sd_addr[10] <= 1'b1; end
                4'd1, 4'd2, 4'd3, 4'd4, 4'd5, 4'd6, 4'd7, 4'd8: cmd <= CMD_REFRESH;
                4'd9: begin cmd <= CMD_MODE; sd_addr <= MODE; sd_ba <= 2'b00; end
                default: begin state <= S_IDLE; ref_count <= REFRESH_CYCLES; end
                endcase
            end
        end
        S_IDLE: begin
            if (ref_count == 16'd0) begin
                cmd <= CMD_REFRESH;
                ref_count <= REFRESH_CYCLES;
                phase <= 4'd0;
                state <= S_REF;
            end else if (req) begin
                cmd <= CMD_ACTIVE;
                sd_ba <= addr[21:20];
                sd_addr <= addr[19:9];
                is_we <= we;
                half <= addr[0];
                state <= S_RW;
            end
        end
        S_RW: begin
            // tRCD = 1 cycle: READ/WRITE with auto-precharge (A10)
            sd_addr <= {3'b100, addr[8:1]};
            if (is_we) begin
                cmd <= CMD_WRITE;
                sd_dq_out <= {wdata, wdata};
                sd_dq_oe <= 1'b1;
                sd_dqm <= half ? {2'b11, ~be} : {~be, 2'b11};
            end else begin
                cmd <= CMD_READ;
                sd_dqm <= 4'b0000;
            end
            phase <= 4'd0;
            state <= S_WAIT;
        end
        S_WAIT: begin
            // READ registered at the end of S_RW is seen by the SDRAM in
            // phase 0; data comes CAS 2 SDRAM clocks later and is taken at
            // the end of phase 2. The bank precharges itself meanwhile.
            phase <= phase + 4'd1;
            if (!is_we && phase == 4'd2) begin
                rdata <= half ? sd_dq_in[15:0] : sd_dq_in[31:16];
                ack <= 1'b1;
            end
            if (is_we && phase == 4'd0)
                ack <= 1'b1;
            if (phase == 4'd3) begin
                sd_dqm <= 4'b1111;
                state <= S_IDLE;
            end
        end
        S_REF: begin
            // tRC: 60 ns or more
            phase <= phase + 4'd1;
            if (phase == 4'd2) state <= S_IDLE;
        end
        default: state <= S_IDLE;
        endcase
    end
end

endmodule
