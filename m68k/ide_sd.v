// ide_sd.v - the Tiny68K's IDE (CompactFlash) registers at $FFE000 on an SD
// card, as rs6809's Tiny68K model behaves (src/m68k/tiny68k.rs): LBA PIO
// READ SECTORS ($20/$21), WRITE SECTORS ($30/$31), IDENTIFY DEVICE ($EC),
// SET FEATURES and the power commands accepted. The data register is 16
// bits with the bytes swapped (a sector's first byte is the low byte of the
// word); byte reads take one byte. Register = (address & 31) >> 1; status
// is at 7 and 14. Device 1 is not fitted. Unlike the model, the card takes
// time: BSY ($80) is shown while a sector moves between the card and the
// buffer.
//
// $FFE800-$FFE803 (not on the board): the card sector where the disk
// starts, written by the boot ROM. $FFE804: bit 0 the card is initialised.
// GPL-3.0-or-later.
module ide_sd #(parameter SIMULATE = 0) (
    input             clk,
    input             rst_n,
    input             req,          // held until ack
    input             we,
    input             word,         // both bytes (UDS and LDS)
    input             peek,         // no side effects (the ICE)
    input      [11:0] off,          // byte address within $FFE000-$FFEFFF
    input      [15:0] wdata,
    output reg        ack,
    output reg [15:0] rdata,

    output            sdclk,
`ifdef VERILATOR
    output            sdcmd,
    input             sdcmd_in,
    output     [3:0]  sddat,
    input      [3:0]  sddat_in
`else
    inout             sdcmd,
    inout      [3:0]  sddat
`endif
);
localparam ST_ERR = 8'h01, ST_DRQ = 8'h08, ST_DRDY = 8'h40, ST_BSY = 8'h80;
localparam IDLE = 3'd0, LOAD = 3'd1, RD = 3'd2, WR = 3'd3, FLUSH = 3'd4, IDENT = 3'd5;

reg  [2:0]  st;
reg  [7:0]  err, cnt, lba0, lba1, lba2, head;
reg         failed;
reg  [31:0] base;
reg  [27:0] cur;
reg  [8:0]  left;
reg  [8:0]  pos;
reg         started;

reg         rd_start, wr_start;
wire        busy, card_ready;
reg  [8:0]  baddr;
reg         bwe;
reg  [7:0]  bwdata;
wire [7:0]  bq;

sd_sector #(.SIMULATE(SIMULATE)) sec (
    .clk(clk), .rst_n(rst_n), .rd_start(rd_start), .wr_start(wr_start), .lba(base + {4'd0, cur}),
    .busy(busy), .card_ready(card_ready),
    .baddr(baddr), .bwe(bwe), .bwdata(bwdata), .brdata(bq),
    .sdclk(sdclk), .sdcmd(sdcmd), .sddat(sddat)
`ifdef VERILATOR
    , .sdcmd_in(sdcmd_in), .sddat_in(sddat_in)
`endif
);

wire absent = head[4];
wire [7:0] status = absent ? 8'h00 :
    (st == LOAD || st == FLUSH || st == IDENT) ? ST_BSY :
    (st == RD || st == WR) ? (ST_DRDY | ST_DRQ) :
    (failed ? (ST_DRDY | ST_ERR) : ST_DRDY);
wire [3:0] r = off[4:1];
wire extra = off[11];

// IDENTIFY DEVICE data: word i, little-endian on the wire
function [15:0] ident;
    input [7:0] i;
    reg [7:0] c0, c1;
    reg [8*40-1:0] s;
    begin
        s = "rs6809 IDE disk on SD                   ";
        c0 = s[8*40-1 - 8*(2*(i-27)) -: 8];
        c1 = s[8*40-1 - 8*(2*(i-27)+1) -: 8];
        case (i)
        8'd0: ident = 16'h0040;
        8'd1: ident = 16'd1024;
        8'd3: ident = 16'd16;
        8'd6: ident = 16'd63;
        8'd49: ident = 16'h0200;
        8'd60: ident = 16'h0000;   // 2^21 sectors (1 GiB)
        8'd61: ident = 16'h0020;
        default: ident = (i >= 8'd27 && i <= 8'd46) ? {c0, c1} : 16'h0000;
        endcase
    end
endfunction

wire [15:0] ident_w = ident(pos[8:1]);
localparam A_IDLE = 3'd0, A_LO = 3'd1, A_HI = 3'd2, A_SETTLE = 3'd3, A_WAIT = 3'd4;
reg [2:0] as_;
reg [7:0] lo_byte;

task sector_done;   // pos wrapped after the last byte of a sector
begin
    if (st == RD) begin
        if (left == 9'd1) st <= IDLE;
        else begin left <= left - 9'd1; cur <= cur + 28'd1; rd_start <= 1'b1; started <= 1'b0; st <= LOAD; end
    end else begin
        wr_start <= 1'b1; started <= 1'b0; st <= FLUSH;
    end
end
endtask

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        st <= IDLE; err <= 0; cnt <= 8'd1; lba0 <= 0; lba1 <= 0; lba2 <= 0; head <= 8'he0;
        failed <= 1'b0; base <= 32'd0; cur <= 0; left <= 0; pos <= 0; started <= 1'b0;
        rd_start <= 1'b0; wr_start <= 1'b0; baddr <= 0; bwe <= 1'b0; bwdata <= 0;
        ack <= 1'b0; rdata <= 16'hffff; as_ <= A_IDLE; lo_byte <= 0;
    end else begin
        ack <= 1'b0;
        rd_start <= 1'b0;
        wr_start <= 1'b0;
        bwe <= 1'b0;
        case (st)
        LOAD: if (busy) started <= 1'b1; else if (started) begin st <= RD; pos <= 9'd0; baddr <= 9'd0; end
        FLUSH: if (busy) started <= 1'b1; else if (started) begin
                if (left == 9'd1) st <= IDLE;
                else begin left <= left - 9'd1; cur <= cur + 28'd1; st <= WR; pos <= 9'd0; baddr <= 9'd0; end
            end
        IDENT: begin
            // two bytes per word, from IDENTIFY's words
            bwe <= 1'b1;
            baddr <= pos;
            bwdata <= pos[0] ? ident_w[15:8] : ident_w[7:0];
            pos <= pos + 9'd1;
            if (pos == 9'd511) begin st <= RD; left <= 9'd1; end
        end
        default: ;
        endcase
        if (st == IDENT && pos == 9'd511) begin pos <= 9'd0; end

        if (as_ == A_IDLE && (st == RD || st == WR)) baddr <= pos;
        case (as_)
        A_IDLE: if (req && !ack) begin
            if (extra) begin
                if (we && !peek) case (off[2:0])
                    3'd0: base[31:24] <= word ? wdata[15:8] : wdata[7:0];
                    3'd1: base[23:16] <= wdata[7:0];
                    3'd2: base[15:8] <= word ? wdata[15:8] : wdata[7:0];
                    3'd3: base[7:0] <= wdata[7:0];
                    default: ;
                endcase
                if (we && !peek && word && off[2:0] == 3'd0) base[23:16] <= wdata[7:0];
                if (we && !peek && word && off[2:0] == 3'd2) base[7:0] <= wdata[7:0];
                case (off[2:0])
                3'd0: rdata <= base[31:16];
                3'd2: rdata <= base[15:0];
                3'd4: rdata <= {8'd0, 7'd0, card_ready};
                default: rdata <= 16'hffff;
                endcase
                if (off[2:0] == 3'd1) rdata <= {2{base[23:16]}};
                if (off[2:0] == 3'd3) rdata <= {2{base[7:0]}};
                if (off[2:0] == 3'd5) rdata <= {8'd0, 7'd0, card_ready};
                ack <= 1'b1;
            end else if (r == 4'd0 && !peek && (st == RD || st == WR) && !absent) begin
                baddr <= pos;
                as_ <= A_LO;
            end else begin
                case (r)
                4'd0: rdata <= (st == RD) ? {bq, bq} : 16'hffff;
                4'd1: rdata <= {2{err}};
                4'd2: rdata <= {2{cnt}};
                4'd3: rdata <= {2{lba0}};
                4'd4: rdata <= {2{lba1}};
                4'd5: rdata <= {2{lba2}};
                4'd6: rdata <= {2{head}};
                4'd7, 4'd14: rdata <= {2{status}};
                default: rdata <= 16'hffff;
                endcase
                if (we && !peek) case (r)
                4'd1: err <= wdata[7:0];
                4'd2: cnt <= wdata[7:0];
                4'd3: lba0 <= wdata[7:0];
                4'd4: lba1 <= wdata[7:0];
                4'd5: lba2 <= wdata[7:0];
                4'd6: head <= wdata[7:0];
                4'd7: if (!absent && (st == IDLE)) begin
                    err <= 8'd0;
                    failed <= 1'b0;
                    case (wdata[7:0])
                    8'h20, 8'h21, 8'h30, 8'h31: begin
                        if (!head[6]) begin failed <= 1'b1; err <= 8'h04; end
                        else begin
                            cur <= {head[3:0], lba2, lba1, lba0};
                            left <= (cnt == 8'd0) ? 9'd256 : {1'b0, cnt};
                            pos <= 9'd0; baddr <= 9'd0;
                            if (wdata[4]) st <= WR;
                            else begin rd_start <= 1'b1; started <= 1'b0; st <= LOAD; end
                        end
                    end
                    8'hec: begin st <= IDENT; pos <= 9'd0; end
                    8'hef, 8'h91, 8'he0, 8'he1, 8'he2, 8'he3, 8'he4, 8'he5, 8'he6, 8'he7: ;
                    default: if (wdata[7:4] != 4'h1) begin failed <= 1'b1; err <= 8'h04; end
                    endcase
                end
                default: ;
                endcase
                ack <= 1'b1;
            end
        end
        A_LO: begin
            // the data register: bq is the byte at pos one clock after baddr
            if (st == RD) begin
                if (!word) begin
                    rdata <= {bq, bq};
                    pos <= pos + 9'd1; baddr <= pos + 9'd1;
                    ack <= 1'b1; as_ <= A_SETTLE;
                    if (pos == 9'd511) sector_done;
                end else begin
                    lo_byte <= bq;
                    pos <= pos + 9'd1; baddr <= pos + 9'd1;
                    as_ <= A_WAIT;
                end
            end else begin
                bwe <= 1'b1; baddr <= pos; bwdata <= wdata[7:0];
                if (!word) begin
                    pos <= pos + 9'd1; ack <= 1'b1; as_ <= A_SETTLE;
                    if (pos == 9'd511) sector_done;
                end else begin
                    pos <= pos + 9'd1; as_ <= A_HI;
                end
            end
        end
        A_HI: begin
            if (st == RD) begin
                rdata <= {bq, lo_byte};
                pos <= pos + 9'd1; baddr <= pos + 9'd1;
            end else begin
                bwe <= 1'b1; baddr <= pos; bwdata <= wdata[15:8];
                pos <= pos + 9'd1;
            end
            ack <= 1'b1; as_ <= A_SETTLE;
            if (pos == 9'd511) sector_done;
        end
        A_WAIT: as_ <= A_HI;    // bq follows the new baddr
        A_SETTLE: begin
            // wait for the requester to drop req, and bq to follow baddr
            baddr <= pos;
            if (!req) as_ <= A_IDLE;
        end
        endcase
    end
end
endmodule
