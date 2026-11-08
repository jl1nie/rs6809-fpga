// sd_sector.v - one 512-byte sector buffer in front of sd_rw (MiSTeryNano's
// native 4-bit SD host): the client fills or empties the buffer at its own
// pace and asks for the buffer to be read from or written to a sector.
// GPL-3.0-or-later.
module sd_sector #(parameter SIMULATE = 0, parameter [2:0] CLK_DIV = 3'd2) (
    input             clk,
    input             rst_n,

    input             rd_start,     // one cycle, when !busy
    input             wr_start,
    input      [31:0] lba,
    output            busy,         // a transfer is running, or the card is initialising
    output            card_ready,

    input      [8:0]  baddr,        // client side of the buffer
    input             bwe,
    input      [7:0]  bwdata,
    output reg [7:0]  brdata,       // one cycle after baddr

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
// One write port (the card and the client never write at once) and two
// read ports, so that it maps onto block RAM.
reg [7:0] buf_ [0:511];

wire       rbusy, rdone, outen;
wire [8:0] outaddr;
wire [7:0] outbyte;
reg  [7:0] inbyte;
wire [3:0] card_stat;
wire [1:0] card_type;
wire       w_en = outen | bwe;
wire [8:0] w_addr = outen ? outaddr : baddr;
wire [7:0] w_data = outen ? outbyte : bwdata;
always @(posedge clk) if (w_en) buf_[w_addr] <= w_data;
always @(posedge clk) brdata <= buf_[baddr];
always @(posedge clk) inbyte <= buf_[outaddr];

reg rstart, wstart, running;
reg [31:0] sector;
// sd_rw reports READY (8) once initialised and between transfers
assign card_ready = (card_stat == 4'd8);
assign busy = running | rstart | wstart | !card_ready;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rstart <= 1'b0; wstart <= 1'b0; running <= 1'b0; sector <= 32'd0;
    end else begin
        if ((rd_start || wr_start) && !running) begin
            rstart <= rd_start; wstart <= wr_start; sector <= lba; running <= 1'b1;
        end else if (running && rbusy) begin
            rstart <= 1'b0; wstart <= 1'b0;
        end else if (running && !rstart && !wstart && !rbusy) begin
            running <= 1'b0;
        end
    end
end

sd_rw #(.CLK_DIV(CLK_DIV), .SIMULATE(SIMULATE)) sd (
    .rstn(rst_n), .clk(clk), .sdclk(sdclk), .sdcmd(sdcmd), .sddat(sddat),
`ifdef VERILATOR
    .sdcmd_in(sdcmd_in), .sddat_in(sddat_in),
`endif
    .card_stat(card_stat), .card_type(card_type),
    .rstart(rstart), .wstart(wstart), .sector(sector),
    .rbusy(rbusy), .rdone(rdone),
    .outen(outen), .outaddr(outaddr), .inbyte(inbyte), .outbyte(outbyte)
);
endmodule
