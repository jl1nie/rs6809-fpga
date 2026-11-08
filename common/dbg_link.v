// dbg_link.v - shares the one USB serial port of the Tang Nano 20K (the
// BL616's UART) between the guest console and the ICE.
//
// Both directions carry console bytes as they are, except DLE (0x10):
//   DLE DLE              a console byte 0x10
//   DLE code len data... a debug command (host to board) or response/event
//                        (board to host); len data bytes follow (0-255)
// so a terminal program sees the console, and rs6809's ICE (--fpga) sees
// the console and the debugger at once. The host sends one command at a
// time and waits for its response; events (the CPU stopped) come unasked.
//
// The engine (dbg6809, dbg68k) reads a command's data from the payload
// buffer (asynchronous read), writes a response into the
// response buffer and asks for it to be sent.
// GPL-3.0-or-later.
module dbg_link #(parameter DIV = 278) (
    input            clk,
    input            rst_n,
    input            uart_rx,
    output           uart_tx,

    // console: bytes to the guest, bytes from the guest
    output reg       con_rx_valid,
    output reg [7:0] con_rx_data,
    input            con_tx_empty,
    input      [7:0] con_tx_data,
    output reg       con_tx_rd,

    // commands to the engine
    output reg       cmd_valid,      // one cycle; code, len and payload valid
    output reg [7:0] cmd_code,
    output reg [7:0] cmd_len,
    input      [7:0] pay_raddr,
    output     [7:0] pay_rdata,      // pay[pay_raddr] (asynchronous)

    // responses from the engine
    input            rsp_we,
    input      [7:0] rsp_waddr,
    input      [7:0] rsp_wdata,
    input            rsp_send,       // one cycle, when !rsp_busy
    input      [7:0] rsp_code,
    input      [7:0] rsp_len,
    output           rsp_busy
);
localparam DLE = 8'h10;

wire       rx_valid;
wire [7:0] rx_data;
uart_rx #(.DIV(DIV)) urx (.clk(clk), .rst_n(rst_n), .rx(uart_rx), .valid(rx_valid), .data(rx_data));

reg        tx_start;
reg  [7:0] tx_data;
wire       tx_busy;
uart_tx #(.DIV(DIV)) utx (.clk(clk), .rst_n(rst_n), .start(tx_start), .data(tx_data), .busy(tx_busy), .tx(uart_tx));

// ---- receive: console bytes and commands ----
reg [7:0] pay [0:255];
reg [7:0] rsp [0:255];
assign pay_rdata = pay[pay_raddr];
always @(posedge clk)
    if (rx_valid && rs == R_PAY) pay[ridx] <= rx_data;

localparam R_DATA = 2'd0, R_ESC = 2'd1, R_LEN = 2'd2, R_PAY = 2'd3;
reg [1:0] rs;
reg [7:0] rcount, ridx;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rs <= R_DATA; con_rx_valid <= 1'b0; cmd_valid <= 1'b0;
        cmd_code <= 8'd0; cmd_len <= 8'd0; rcount <= 0; ridx <= 0; con_rx_data <= 0;
    end else begin
        con_rx_valid <= 1'b0;
        cmd_valid <= 1'b0;
        if (rx_valid) case (rs)
        R_DATA: if (rx_data == DLE) rs <= R_ESC;
                else begin con_rx_valid <= 1'b1; con_rx_data <= rx_data; end
        R_ESC:  if (rx_data == DLE) begin
                    con_rx_valid <= 1'b1; con_rx_data <= DLE; rs <= R_DATA;
                end else begin cmd_code <= rx_data; rs <= R_LEN; end
        R_LEN:  begin
                    cmd_len <= rx_data; rcount <= rx_data; ridx <= 8'd0;
                    if (rx_data == 8'd0) begin cmd_valid <= 1'b1; rs <= R_DATA; end
                    else rs <= R_PAY;
                end
        R_PAY:  begin
                    ridx <= ridx + 8'd1;
                    rcount <= rcount - 8'd1;
                    if (rcount == 8'd1) begin cmd_valid <= 1'b1; rs <= R_DATA; end
                end
        endcase
    end
end

// ---- transmit: responses first, then console bytes (DLE doubled) ----
always @(posedge clk) if (rsp_we) rsp[rsp_waddr] <= rsp_wdata;
reg [7:0] rsp_q;
always @(posedge clk) rsp_q <= rsp[tidx];   // valid long before a byte is due

localparam T_IDLE = 3'd0, T_CODE = 3'd1, T_LEN = 3'd2, T_PAY = 3'd3, T_DLE2 = 3'd4, T_WAIT = 3'd5;
reg [2:0] ts, tnext;
reg       pending;
reg [7:0] pcode, plen, tidx;
reg [7:0] tbyte;
assign rsp_busy = pending;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ts <= T_IDLE; tnext <= T_IDLE; pending <= 1'b0; tx_start <= 1'b0; tx_data <= 0;
        con_tx_rd <= 1'b0; pcode <= 0; plen <= 0; tidx <= 0; tbyte <= 0;
    end else begin
        tx_start <= 1'b0;
        con_tx_rd <= 1'b0;
        if (rsp_send && !pending) begin
            pending <= 1'b1; pcode <= rsp_code; plen <= rsp_len;
        end
        case (ts)
        T_IDLE: if (!tx_busy) begin
            if (pending) begin
                tx_data <= DLE; tx_start <= 1'b1; ts <= T_WAIT; tnext <= T_CODE;
            end else if (!con_tx_empty) begin
                tx_data <= con_tx_data; tx_start <= 1'b1; con_tx_rd <= 1'b1;
                ts <= T_WAIT; tnext <= (con_tx_data == DLE) ? T_DLE2 : T_IDLE;
            end
        end
        T_DLE2: if (!tx_busy) begin tx_data <= DLE; tx_start <= 1'b1; ts <= T_WAIT; tnext <= T_IDLE; end
        T_CODE: if (!tx_busy) begin tx_data <= pcode; tx_start <= 1'b1; ts <= T_WAIT; tnext <= T_LEN; end
        T_LEN:  if (!tx_busy) begin
            tx_data <= plen; tx_start <= 1'b1; ts <= T_WAIT; tidx <= 8'd0;
            if (plen == 8'd0) begin tnext <= T_IDLE; pending <= 1'b0; end
            else tnext <= T_PAY;
        end
        T_PAY:  if (!tx_busy) begin
            tx_data <= rsp_q; tx_start <= 1'b1; ts <= T_WAIT;
            tidx <= tidx + 8'd1;
            if (tidx + 8'd1 == plen) begin tnext <= T_IDLE; pending <= 1'b0; end
            else tnext <= T_PAY;
        end
        T_WAIT: begin
            // tx_busy rises with start; wait one cycle, then for the byte
            ts <= tnext;
        end
        default: ts <= T_IDLE;
        endcase
    end
end
endmodule
