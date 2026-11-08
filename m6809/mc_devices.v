// mc_devices.v - the Multicomp09 devices as rs6809's machine.rs models them
// (src/machine.rs is the specification; Grant Searle's and Neal Crook's
// VHDL are not used): the MMU at $FFDE/$FFDF, the 6850 console ACIA at
// $FFD0/$FFD1, the SD controller at $FFD8-$FFDC and the 50 Hz timer at
// $FFDD.
// GPL-3.0-or-later.

// ---------------- MMU ($FFDE mapper, $FFDF map entry) ----------------
module mc_mmu #(parameter RAM_KB = 1024) (
    input             clk,
    input             rst_n,
    input             we_mapper,
    input             we_map,
    input      [7:0]  wdata,
    // translation of the bus address
    input      [15:0] a,
    output     [19:0] pa,
    output            pa_ok,       // a populated bank
    output            wprot,       // the slot is write-protected
    // translation of the CPU's next PC (for physical breakpoints)
    input      [15:0] b,
    output     [19:0] pb,
    output            pb_ok,
    output            rom_dis,
    output reg [7:0]  mapper,
    output reg        fixed_top,
    input      [3:0]  map_idx,
    output     [7:0]  map_q
);
reg [7:0] maps [0:15];
assign map_q = maps[map_idx];
reg rom_disabled;
assign rom_dis = rom_disabled;
wire enabled = mapper[5];
wire task_ = mapper[6];
localparam BANKS = RAM_KB / 8;

function [21:0] xlate; // {ok, wp, pa}
    input [15:0] x;
    reg [7:0] e;
    begin
        if (!enabled || (fixed_top && x >= 16'hfe00))
            xlate = {1'b1, 1'b0, 4'd0, x};
        else begin
            e = maps[{task_, x[15:13]}];
            xlate = {(e[6:0] < BANKS), e[7], e[6:0], x[12:0]};
        end
    end
endfunction
wire [21:0] xa = xlate(a);
wire [21:0] xb = xlate(b);
assign {pa_ok, wprot, pa} = xa;
assign {pb_ok, pb} = {xb[21], xb[19:0]};

integer i;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        mapper <= 8'd0; fixed_top <= 1'b0; rom_disabled <= 1'b0;
        for (i = 0; i < 16; i = i + 1) maps[i] <= 8'd0;
    end else begin
        if (we_mapper && !wdata[4]) begin
            if (!wdata[5]) fixed_top <= 1'b0;
            else if (mapper[7] && mapper[5] && !wdata[7]) fixed_top <= 1'b1;
            // ROMDIS stays set during the fixed-top handshake
            rom_disabled <= wdata[7] || (mapper[7] && mapper[5] && wdata[5]);
            mapper <= wdata | ((wdata[7] || (mapper[7] && mapper[5] && wdata[5])) ? 8'h80 : 8'h00);
        end
        if (we_map) maps[mapper[3:0]] <= wdata;
    end
end
endmodule

// ---------------- 6850 ACIA (console) ----------------
module mc_acia (
    input            clk,
    input            rst_n,
    input            rs,           // 0 control/status, 1 data
    input            we,           // write strobe (once per CPU access)
    input            re,           // read strobe (pops received data)
    input      [7:0] wdata,
    output     [7:0] rdata,
    output           irq,
    output     [7:0] control_q,
    // link side
    input            rx_valid,
    input      [7:0] rx_data,
    output           tx_empty,
    output     [7:0] tx_data,
    input            tx_rd
);
reg [7:0] control;
assign control_q = control;
wire rx_empty, rx_full, tx_full;
wire [7:0] rx_q;
wire mreset = we && !rs && wdata[1:0] == 2'b11;
fifo #(.W(8), .AW(6)) rxf (.clk(clk), .rst_n(rst_n), .clr(mreset), .wr(rx_valid), .din(rx_data),
    .rd(re && rs), .dout(rx_q), .empty(rx_empty), .full(rx_full), .count());
fifo #(.W(8), .AW(4)) txf (.clk(clk), .rst_n(rst_n), .clr(1'b0), .wr(we && rs), .din(wdata),
    .rd(tx_rd), .dout(tx_data), .empty(tx_empty), .full(tx_full), .count());
wire rdrf = !rx_empty;
wire tdre = !tx_full;
assign irq = (control[7] && rdrf) || (control[6:5] == 2'b01 && tdre);
assign rdata = rs ? (rx_empty ? 8'hff : rx_q) : {irq, 4'b0000, 1'b0, tdre, rdrf};
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) control <= 8'd0;
    else if (we && !rs) control <= (wdata[1:0] == 2'b11) ? 8'd0 : wdata;
end
endmodule

// ---------------- 50 Hz timer ($FFDD) ----------------
module mc_timer #(parameter TICK = 640000) (  // 32 MHz / 50
    input            clk,
    input            rst_n,
    input            we,
    input      [7:0] wdata,
    input            freeze,     // the CPU is stopped by the ICE
    output reg [7:0] timer
);
reg [19:0] cnt;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin timer <= 8'd0; cnt <= 20'd0; end
    else begin
        if (!freeze) begin
            if (cnt == TICK - 1) begin
                cnt <= 20'd0;
                if (timer[1]) timer[7] <= 1'b1;
            end else cnt <= cnt + 20'd1;
        end
        if (we) begin
            timer[1] <= wdata[1];
            if (wdata[7]) timer[7] <= 1'b0;
        end
    end
end
endmodule

// ---------------- SD controller ($FFD8 data, $FFD9 command/status,
// $FFDA-$FFDC LBA) ----------------
// Status: $90 card not ready, $80 idle, $A0 reading from the card (busy),
// $E0 a byte to read, $A0 a byte may be written, $20 writing to the card.
module mc_sd #(parameter SIMULATE = 0, parameter [31:0] LBA_BASE = 32'd0) (
    input            clk,
    input            rst_n,
    input      [2:0] reg_,         // address - $FFD8
    input            we,
    input            re,
    input      [7:0] wdata,
    output reg [7:0] rdata,
    output     [2:0] state_q,

    output           sdclk,
`ifdef VERILATOR
    output           sdcmd,
    input            sdcmd_in,
    output     [3:0] sddat,
    input      [3:0] sddat_in
`else
    inout            sdcmd,
    inout      [3:0] sddat
`endif
);
localparam IDLE = 3'd0, READ = 3'd1, WRITE = 3'd2, LOAD = 3'd3, FLUSH = 3'd4;
reg [2:0]  st;
assign state_q = st;
reg [22:0] lba;
reg [8:0]  idx;
reg        start_rd, start_wr, started;
wire       busy, card_ready;
wire [7:0] bq;

sd_sector #(.SIMULATE(SIMULATE)) sec (
    .clk(clk), .rst_n(rst_n),
    .rd_start(start_rd), .wr_start(start_wr), .lba(LBA_BASE + {9'd0, lba}),
    .busy(busy), .card_ready(card_ready),
    .baddr(idx), .bwe(we && reg_ == 3'd0 && st == WRITE), .bwdata(wdata), .brdata(bq),
    .sdclk(sdclk), .sdcmd(sdcmd), .sddat(sddat)
`ifdef VERILATOR
    , .sdcmd_in(sdcmd_in), .sddat_in(sddat_in)
`endif
);

always @* begin
    case (reg_)
    3'd0: rdata = (st == READ) ? bq : 8'hff;
    3'd1: rdata = !card_ready && st == IDLE ? 8'h90 :
                  st == IDLE ? 8'h80 : st == READ ? 8'he0 : st == FLUSH ? 8'h20 : 8'ha0;
    default: rdata = 8'hff;
    endcase
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        st <= IDLE; lba <= 23'd0; idx <= 9'd0; start_rd <= 1'b0; start_wr <= 1'b0; started <= 1'b0;
    end else begin
        start_rd <= 1'b0; start_wr <= 1'b0;
        case (st)
        IDLE: if (we && reg_ == 3'd1 && card_ready && !busy) begin
            idx <= 9'd0;
            if (wdata == 8'd0) begin start_rd <= 1'b1; started <= 1'b0; st <= LOAD; end
            else if (wdata == 8'd1) st <= WRITE;
        end
        LOAD: begin
            if (busy) started <= 1'b1;
            else if (started) st <= READ;
        end
        READ: if (re && reg_ == 3'd0) begin
            idx <= idx + 9'd1;
            if (idx == 9'd511) st <= IDLE;
        end
        WRITE: if (we && reg_ == 3'd0) begin
            idx <= idx + 9'd1;
            if (idx == 9'd511) begin start_wr <= 1'b1; started <= 1'b0; st <= FLUSH; end
        end
        FLUSH: begin
            if (busy) started <= 1'b1;
            else if (started) begin st <= IDLE; idx <= 9'd0; end
        end
        default: st <= IDLE;
        endcase
        if (we && reg_ == 3'd2) lba[7:0] <= wdata;
        if (we && reg_ == 3'd3) lba[15:8] <= wdata;
        if (we && reg_ == 3'd4) lba[22:16] <= wdata[6:0];
    end
end
endmodule
