// Unit test for asic65_sim: replays the ASIC65 command/parameter/result
// stream MAME logged (mame/oracle.lua, RD_LOG, the .asic65.log file) and
// checks every result the 68010 read.  Stimulus lines: R <reset state>,
// C <command>, P <parameter>, X <expected result>; built by
// tools/sim.py asic65-test.
`timescale 1ns/1ps
module tb_asic65;
  logic clk = 0;
  always #10 clk = ~clk;
  logic rst = 1;
  logic reset_we = 0, reset_state = 0, param_we = 0, cmd_we = 0, rd_req = 0, rd_ack;
  logic [15:0] wdata = 0, rdata;
  asic65_sim #(.SIN_TABLE_FILE(`SIN_FILE)) dut (
    .clk_i(clk), .rst_i(rst), .reset_we_i(reset_we), .reset_state_i(reset_state),
    .param_we_i(param_we), .cmd_we_i(cmd_we), .wdata_i(wdata),
    .rd_req_i(rd_req), .rd_ack_o(rd_ack), .rdata_o(rdata)
  );
  initial begin
    int fd, n, errors = 0, checks = 0, val, line = 0;
    string kind, file;
    if (!$value$plusargs("stim=%s", file)) file = "asic65_stim.txt";
    fd = $fopen(file, "r");
    if (fd == 0) begin $display("tb_asic65: cannot open %s", file); $finish; end
    repeat (4) @(posedge clk);
    rst <= 0;
    @(posedge clk);
    while (!$feof(fd)) begin
      n = $fscanf(fd, "%s %h\n", kind, val);
      if (n != 2) break;
      line++;
      case (kind)
        "R": begin reset_we <= 1; reset_state <= val[0]; @(posedge clk); reset_we <= 0; end
        "C": begin cmd_we <= 1; wdata <= val[15:0]; @(posedge clk); cmd_we <= 0; end
        "P": begin param_we <= 1; wdata <= val[15:0]; @(posedge clk); param_we <= 0; end
        "X": begin
          rd_req <= 1; @(posedge clk); rd_req <= 0;
          @(negedge clk);
          while (!rd_ack) @(negedge clk);
          checks++;
          if (rdata !== val[15:0]) begin
            errors++;
            if (errors <= 20) $display("MISMATCH line %0d (result #%0d): got %04x expected %04x", line, checks, rdata, val[15:0]);
          end
        end
        default: ;
      endcase
      @(posedge clk);
    end
    $display("tb_asic65: %0d stimulus lines, %0d results checked, %0d mismatches", line, checks, errors);
    $finish;
  end
endmodule
