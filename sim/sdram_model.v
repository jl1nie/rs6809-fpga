// sdram_model.v - behavioural model of the Tang Nano 20K's SDRAM for
// simulation (64 Mbit x32, CAS latency 2, burst 1). Commands are sampled on
// the rising edge of sd_clk (the falling edge of the system clock); read
// data is driven CAS latency clocks after the READ and held for one clock.
// It checks the controller: an ACTIVE to an open bank, or READ/WRITE to a
// closed one, stops the simulation.
// GPL-3.0-or-later.
module sdram_model (
    input             sd_clk,
    input             sd_cs_n,
    input             sd_ras_n,
    input             sd_cas_n,
    input             sd_we_n,
    input      [10:0] sd_addr,
    input      [1:0]  sd_ba,
    input      [3:0]  sd_dqm,
    input      [31:0] sd_dq_out,
    input             sd_dq_oe,
    output reg [31:0] sd_dq_in
);

reg [31:0] mem [0:(1<<21)-1];
reg [10:0] row [0:3];
reg        open_ [0:3];
reg        mode_set;
reg [20:0] rd_addr1, rd_addr2;
reg        rd1, rd2;

integer i;
initial begin
    for (i = 0; i < 4; i = i + 1) open_[i] = 1'b0;
    mode_set = 1'b0;
    rd1 = 1'b0; rd2 = 1'b0;
    sd_dq_in = 32'hxxxxxxxx;
end

wire [3:0] cmd = {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n};
wire [20:0] cel = {sd_ba, row[sd_ba], sd_addr[7:0]};

always @(posedge sd_clk) begin
    // read pipeline (CAS 2)
    rd2 <= rd1;
    rd_addr2 <= rd_addr1;
    rd1 <= 1'b0;
    if (rd2) sd_dq_in <= mem[rd_addr2];
    else sd_dq_in <= 32'hdeadbeef;
    case (cmd)
    4'b0011: begin // ACTIVE
        if (open_[sd_ba]) begin
            $display("SDRAM model: ACTIVE to open bank %0d", sd_ba);
            $finish;
        end
        open_[sd_ba] <= 1'b1;
        row[sd_ba] <= sd_addr;
    end
    4'b0101, 4'b0100: begin // READ / WRITE
        if (!open_[sd_ba] || !mode_set) begin
            $display("SDRAM model: access to closed bank %0d", sd_ba);
            $finish;
        end
        if (cmd == 4'b0101) begin
            rd1 <= 1'b1;
            rd_addr1 <= cel;
        end else begin
            if (!sd_dq_oe) begin
                $display("SDRAM model: WRITE without data");
                $finish;
            end
            if (!sd_dqm[3]) mem[cel][31:24] <= sd_dq_out[31:24];
            if (!sd_dqm[2]) mem[cel][23:16] <= sd_dq_out[23:16];
            if (!sd_dqm[1]) mem[cel][15:8]  <= sd_dq_out[15:8];
            if (!sd_dqm[0]) mem[cel][7:0]   <= sd_dq_out[7:0];
        end
        if (sd_addr[10]) open_[sd_ba] <= 1'b0; // auto-precharge
    end
    4'b0010: begin // PRECHARGE
        if (sd_addr[10]) for (i = 0; i < 4; i = i + 1) open_[i] <= 1'b0;
        else open_[sd_ba] <= 1'b0;
    end
    4'b0001: begin // REFRESH
        for (i = 0; i < 4; i = i + 1)
            if (open_[i]) begin
                $display("SDRAM model: REFRESH with bank %0d open", i);
                $finish;
            end
    end
    4'b0000: mode_set <= 1'b1;
    default: ;
    endcase
end

endmodule
