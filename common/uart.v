// uart.v - 8N1 UART receiver and transmitter.
// GPL-3.0-or-later.
module uart_rx #(parameter DIV = 278) (   // clocks per bit (32 MHz / 115200)
    input            clk,
    input            rst_n,
    input            rx,
    output reg       valid,               // one cycle
    output reg [7:0] data
);
reg [2:0] sync;
always @(posedge clk) sync <= {sync[1:0], rx};
wire r = sync[2];
reg [15:0] cnt;
reg [3:0]  bitn;
reg        busy;
reg [7:0]  sh;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        busy <= 1'b0; valid <= 1'b0; cnt <= 0; bitn <= 0; sh <= 0; data <= 0;
    end else begin
        valid <= 1'b0;
        if (!busy) begin
            if (!r) begin busy <= 1'b1; cnt <= DIV / 2; bitn <= 4'd0; end
        end else if (cnt != 0) cnt <= cnt - 16'd1;
        else begin
            cnt <= DIV - 1;
            bitn <= bitn + 4'd1;
            if (bitn == 4'd0) begin
                if (r) busy <= 1'b0;          // false start bit
            end else if (bitn <= 4'd8) sh <= {r, sh[7:1]};
            else begin
                busy <= 1'b0;
                if (r) begin data <= sh; valid <= 1'b1; end
            end
        end
    end
end
endmodule

module uart_tx #(parameter DIV = 278) (
    input       clk,
    input       rst_n,
    input       start,                     // with data, when !busy
    input [7:0] data,
    output      busy,
    output reg  tx
);
reg [15:0] cnt;
reg [3:0]  bitn;
reg [9:0]  sh;
reg        run;
assign busy = run | start;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        run <= 1'b0; tx <= 1'b1; cnt <= 0; bitn <= 0; sh <= 10'h3ff;
    end else if (!run) begin
        tx <= 1'b1;
        if (start) begin
            sh <= {1'b1, data, 1'b0};
            run <= 1'b1; cnt <= 0; bitn <= 0;
        end
    end else if (cnt != 0) cnt <= cnt - 16'd1;
    else begin
        cnt <= DIV - 1;
        if (bitn == 4'd10) run <= 1'b0;
        else begin
            tx <= sh[0];
            sh <= {1'b1, sh[9:1]};
            bitn <= bitn + 4'd1;
        end
    end
end
endmodule

// A small synchronous FIFO.
module fifo #(parameter W = 8, parameter AW = 4) (
    input              clk,
    input              rst_n,
    input              clr,
    input              wr,
    input      [W-1:0] din,
    input              rd,
    output     [W-1:0] dout,
    output             empty,
    output             full,
    output     [AW:0]  count
);
reg [W-1:0] m [0:(1<<AW)-1];
reg [AW:0] wp, rp;
assign count = wp - rp;
assign empty = (wp == rp);
assign full = (count == (1 << AW));
assign dout = m[rp[AW-1:0]];
always @(posedge clk)
    if (wr && !full) m[wp[AW-1:0]] <= din;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin wp <= 0; rp <= 0; end
    else if (clr) begin wp <= 0; rp <= 0; end
    else begin
        if (wr && !full) wp <= wp + 1'b1;
        if (rd && !empty) rp <= rp + 1'b1;
    end
end
endmodule
