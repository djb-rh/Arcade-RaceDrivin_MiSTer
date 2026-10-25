// Replay a mame/duart_test.lua log against mc68681: the writes are applied
// and the reads compared at the same spacing in time.  The log's steps are
// one video frame (16.68 ms) apart, far more than any bit time, so the
// behavioural timing differences between MAME's model and the RTL (where
// within a bit a TxRDY appears) do not matter; the counter/timer values are
// compared with a small tolerance.  Lines: "t reg = val" (write), "t reg val"
// (read), "# ..." comments.  Plusarg +log=<file>.
`timescale 1ns/1ps
module tb_duart;
  logic clk = 0;
  always #10.4166667 clk = ~clk;          // 48 MHz
  logic rst = 1;
  logic req = 0, we = 0; logic [3:0] addr = 0; logic [7:0] wdata = 0, rdata; logic irq;
  logic txa, txb;
  mc68681 dut (.clk_i(clk), .rst_i(rst), .req_i(req), .we_i(we), .addr_i(addr), .wdata_i(wdata), .rdata_o(rdata), .irq_o(irq),
               .tx_a_o(txa), .rx_a_i(1'b1), .tx_b_o(txb), .rx_b_i(1'b1), .ip_i(7'h40), .op_o(), .tx_a_rate_o(), .rx_a_rate_o(), .tx_b_rate_o(), .rx_b_rate_o());
  // the game's own initialisation (from the MAME DUART log) so the test starts from the same state
  task automatic access(input bit w, input int reg_, input logic [7:0] wd, output logic [7:0] rd);
    @(posedge clk); req <= 1; we <= w; addr <= reg_[3:0]; wdata <= wd;
    #1 rd = rdata;
    @(posedge clk); req <= 0;
  endtask
  initial begin
    string file, line; int fd, n, reg_, val, checks = 0, errors = 0; real t, tlast; logic [7:0] rd; string eq;
    if (!$value$plusargs("log=%s", file)) file = "duart_test.log";
    repeat (4) @(posedge clk); rst <= 0; repeat (4) @(posedge clk);
    // game init at 1.59 s: CRA resets, MR1A 13, MR2A 07, CSRA cc, ACR 30, IMR 00, OPCR 00, IMR 22, CRA 05, same for B, OPR set 01, reset 10, 20
    begin
      int init_reg [0:21] = '{2,2,2,0,0,1,4,5,13,5,2,10,10,10,8,8,9,10,14,15,15,15};
      int init_val [0:21] = '{16'h10,16'h20,16'h30,16'h13,16'h07,16'hcc,16'h30,16'h00,16'h00,16'h22,16'h05,16'h10,16'h20,16'h30,16'h13,16'h07,16'hcc,16'h05,16'h01,16'h10,16'h20,16'h30};
      for (int i = 0; i < 22; i++) begin access(1, init_reg[i], init_val[i][7:0], rd); repeat (20) @(posedge clk); end
    end
    fd = $fopen(file, "r");
    if (fd == 0) begin $display("tb_duart: cannot open %s", file); $finish; end
    tlast = -1;
    while (!$feof(fd)) begin
      if ($fgets(line, fd) == 0) break;
      if (line[0] == "#") continue;
      n = $sscanf(line, "%f %d = %h", t, reg_, val);
      if (n == 3) begin
        if (tlast >= 0 && t > tlast) #((t - tlast) * 1e9);
        tlast = t;
        access(1, reg_, val[7:0], rd);
        continue;
      end
      n = $sscanf(line, "%f %d %h", t, reg_, val);
      if (n != 3) continue;
      if (tlast >= 0 && t > tlast) #((t - tlast) * 1e9);
      tlast = t;
      access(0, reg_, 8'h00, rd);
      checks++;
      if (reg_ == 6 || reg_ == 7) begin
        // counter/timer: compare within a few ticks (6 = high byte, 7 = low byte)
        if (reg_ == 7 ? ($signed({1'b0, rd}) - $signed({1'b0, val[7:0]}) > 3 || $signed({1'b0, val[7:0]}) - $signed({1'b0, rd}) > 3) : (rd !== val[7:0]))
          begin errors++; $display("MISMATCH t=%.6f reg %0d: rtl %02x mame %02x (counter)", t, reg_, rd, val[7:0]); end
      end else if (rd !== val[7:0]) begin
        errors++; $display("MISMATCH t=%.6f reg %0d: rtl %02x mame %02x", t, reg_, rd, val[7:0]);
      end
    end
    $display("tb_duart: %0d reads compared, %0d mismatches", checks, errors);
    $finish;
  end
endmodule
