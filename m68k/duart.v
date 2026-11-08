// duart.v - the MC68681 DUART as rs6809's Tiny68K model has it
// (src/m68k/tiny68k.rs is the specification): two channels with receive
// FIFOs, MR1/MR2, command register, ISR/IMR, IVR, the counter/timer from
// X1/16 or X1 (ACR bits 6-4; counter mode unless ACR bit 6), and OPR.
// Channel transmitters push into FIFOs that real UARTs drain, so TxRDY
// follows the FIFO. Registers: (address >> 1) & 15 on odd addresses.
// GPL-3.0-or-later.
module duart #(parameter SYS_HZ = 32400000) (
    input            clk,
    input            rst_n,
    input      [3:0] rs,           // register of the strobes
    input      [3:0] prs,          // register read now
    input            we,           // write strobe (once per access)
    input            re,           // read strobe (side effects)
    input      [7:0] wdata,
    output reg [7:0] rdata,        // value of register prs (no side effects)
    output           irq,
    output     [7:0] ivr_q,
    input            freeze,       // the ICE has the CPU stopped
    // channel A (console) and B
    input            a_rx_valid,
    input      [7:0] a_rx_data,
    output           a_tx_empty,
    output     [7:0] a_tx_data,
    input            a_tx_rd,
    input            b_rx_valid,
    input      [7:0] b_rx_data,
    output           b_tx_empty,
    output     [7:0] b_tx_data,
    input            b_tx_rd
);
// ---- channels ----
reg [7:0] mra [0:1], mrb [0:1];
reg       mrpa, mrpb, rxa_on, txa_on, rxb_on, txb_on;
wire      arx_empty, arx_full, atx_full, brx_empty, brx_full, btx_full;
wire [7:0] arx_q, brx_q;
wire      cra_rxreset = we && rs == 4'd2 && wdata[6:4] == 3'd2;
wire      crb_rxreset = we && rs == 4'd10 && wdata[6:4] == 3'd2;
fifo #(.W(8), .AW(6)) arx (.clk(clk), .rst_n(rst_n), .clr(cra_rxreset), .wr(a_rx_valid), .din(a_rx_data),
    .rd(re && rs == 4'd3), .dout(arx_q), .empty(arx_empty), .full(arx_full), .count());
fifo #(.W(8), .AW(4)) atx (.clk(clk), .rst_n(rst_n), .clr(1'b0), .wr(we && rs == 4'd3 && txa_on), .din(wdata),
    .rd(a_tx_rd), .dout(a_tx_data), .empty(a_tx_empty), .full(atx_full), .count());
fifo #(.W(8), .AW(6)) brx (.clk(clk), .rst_n(rst_n), .clr(crb_rxreset), .wr(b_rx_valid), .din(b_rx_data),
    .rd(re && rs == 4'd11), .dout(brx_q), .empty(brx_empty), .full(brx_full), .count());
fifo #(.W(8), .AW(4)) btx (.clk(clk), .rst_n(rst_n), .clr(1'b0), .wr(we && rs == 4'd11 && txb_on), .din(wdata),
    .rd(b_tx_rd), .dout(b_tx_data), .empty(b_tx_empty), .full(btx_full), .count());

// SR: RxRDY (bit 0), TxRDY (2), TxEMT (3)
wire [7:0] sra = {4'd0, txa_on && a_tx_empty, txa_on && !atx_full, 1'b0, !arx_empty};
wire [7:0] srb = {4'd0, txb_on && b_tx_empty, txb_on && !btx_full, 1'b0, !brx_empty};

// ---- counter/timer ----
reg [7:0]  acr, imr, ivr, opr;
reg [15:0] preload;
reg        isr_ct, ct_running;
reg [16:0] ct;                 // counts left (timer: twice the preload)
assign ivr_q = ivr;
wire timer_mode = acr[6];
// X1 = 3.6864 MHz; X1/16 unless ACR[6:4] = 6
wire [31:0] inc = (acr[6:4] == 3'd6) ? 32'd3686400 : 32'd230400;
reg  [31:0] acc;
reg         ctick;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin acc <= 0; ctick <= 1'b0; end
    else begin
        ctick <= 1'b0;
        if (!freeze) begin
            if (acc + inc >= SYS_HZ) begin acc <= acc + inc - SYS_HZ; ctick <= 1'b1; end
            else acc <= acc + inc;
        end
    end
end
wire [16:0] period = timer_mode ? {preload == 16'd0 ? 16'd1 : preload, 1'b0} : {1'b0, preload == 16'd0 ? 16'd1 : preload};

wire [7:0] isr = {2'd0, !brx_empty, srb[2], isr_ct, 1'b0, !arx_empty, sra[2]};
assign irq = (isr & imr) != 8'd0;

always @* begin
    case (prs)
    4'd0: rdata = mra[mrpa];
    4'd1: rdata = sra;
    4'd3: rdata = arx_empty ? 8'h00 : arx_q;
    4'd5: rdata = isr;
    4'd8: rdata = mrb[mrpb];
    4'd9: rdata = srb;
    4'd11: rdata = brx_empty ? 8'h00 : brx_q;
    4'd12: rdata = ivr;
    default: rdata = 8'hff;
    endcase
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        mra[0] <= 0; mra[1] <= 0; mrb[0] <= 0; mrb[1] <= 0; mrpa <= 0; mrpb <= 0;
        rxa_on <= 1'b1; txa_on <= 1'b1; rxb_on <= 1'b1; txb_on <= 1'b1;
        acr <= 0; imr <= 0; ivr <= 8'h0f; opr <= 0; preload <= 16'hffff;
        isr_ct <= 1'b0; ct_running <= 1'b0; ct <= 17'd0;
    end else begin
        if ((ct_running || timer_mode) && ctick) begin
            if (ct <= 17'd1) begin
                isr_ct <= 1'b1;
                ct <= period;
                if (!timer_mode) ct_running <= 1'b0;
            end else ct <= ct - 17'd1;
        end
        if (re) case (rs)
            4'd0: mrpa <= 1'b1;
            4'd8: mrpb <= 1'b1;
            4'd14: begin ct_running <= 1'b1; ct <= period; end      // start counter
            4'd15: begin isr_ct <= 1'b0; if (!timer_mode) ct_running <= 1'b0; end
            default: ;
        endcase
        if (we) case (rs)
            4'd0: begin mra[mrpa] <= wdata; mrpa <= 1'b1; end
            4'd2: begin
                if (wdata[1:0] == 2'd1) rxa_on <= 1'b1; else if (wdata[1:0] == 2'd2) rxa_on <= 1'b0;
                if (wdata[3:2] == 2'd1) txa_on <= 1'b1; else if (wdata[3:2] == 2'd2) txa_on <= 1'b0;
                if (wdata[6:4] == 3'd1) mrpa <= 1'b0;
            end
            4'd4: begin acr <= wdata; if (wdata[6]) ct <= {preload == 16'd0 ? 16'd1 : preload, 1'b0}; end
            4'd5: imr <= wdata;
            4'd6: preload[15:8] <= wdata;
            4'd7: preload[7:0] <= wdata;
            4'd8: begin mrb[mrpb] <= wdata; mrpb <= 1'b1; end
            4'd10: begin
                if (wdata[1:0] == 2'd1) rxb_on <= 1'b1; else if (wdata[1:0] == 2'd2) rxb_on <= 1'b0;
                if (wdata[3:2] == 2'd1) txb_on <= 1'b1; else if (wdata[3:2] == 2'd2) txb_on <= 1'b0;
                if (wdata[6:4] == 3'd1) mrpb <= 1'b0;
            end
            4'd12: ivr <= wdata;
            4'd14: opr <= opr | wdata;
            4'd15: opr <= opr & ~wdata;
            default: ;
        endcase
    end
end
endmodule
