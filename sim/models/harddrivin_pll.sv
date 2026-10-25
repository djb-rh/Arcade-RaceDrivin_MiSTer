// Simulation replacement for rtl/harddrivin_pll.sv (which wraps an Altera PLL).
// Generates the same four clocks from scratch with Verilator --timing. The
// 50 MHz reference input is only used to hold the outputs still in reset.
`timescale 1ps/1ps
module harddrivin_pll #(parameter bit COCKPIT = 0) (
  input  logic refclk_i,
  input  logic rst_i,
  output logic clk_gsp_48_o,
  output logic clk_msp_50_o,
  output logic clk_100_o,
  output logic clk_video_6_o,
  output logic locked_o
);
  // half periods in ps
  localparam integer HP48  = 10417;   // 48 MHz
  localparam integer HP50  = 10000;   // 50 MHz
  localparam integer HP100 = 5000;    // 100 MHz
  localparam integer HPVID = COCKPIT ? 125000 : 83333;  // 4 MHz / 6 MHz

  initial begin
    clk_gsp_48_o = 0; clk_msp_50_o = 0; clk_100_o = 0; clk_video_6_o = 0;
  end
  always #(HP48)  clk_gsp_48_o  = ~clk_gsp_48_o;
  always #(HP50)  clk_msp_50_o  = ~clk_msp_50_o;
  always #(HP100) clk_100_o     = ~clk_100_o;
  always #(HPVID) clk_video_6_o = ~clk_video_6_o;
  assign locked_o = !rst_i;
endmodule
