// Unit test of the cabinet I/O link: the ESP32 model (sim_cabinet_io) against
// rd_cabinet_io with a real MC68681 between the link and the "game":
//   inputs in a frame appear on the decoded outputs; a corrupt frame is
//   dropped; silence releases the inputs; bytes the DUART transmits reach
//   the board in output frames; bytes the board sends reach the DUART's
//   receive FIFO; the force byte and outputs go out.
`timescale 1ps/1ps
module tb_cabio;
  logic clk = 0;
  always #10417 clk = ~clk;      // 48 MHz
  logic rst = 1;
  logic link_to_core, link_to_board;
  logic [15:0] sw = 0; logic [11:0] wheel = 12'h800, brake = 0;
  logic [7:0] gas = 0, clutch = 0, seat = 8'h80, shx = 8'h80, shy = 8'h80, brake8 = 8'hf0;
  logic corrupt = 0;
  logic [7:0] force_b, outs_b; int frames_out;
  logic [15:0] sw_o; logic [11:0] wheel_o, brake_o; logic [7:0] gas_o, clutch_o, seat_o, shx_o, shy_o, brake8_o;
  logic board_ok, frame;
  logic rxa, rxb, txa, txb; logic [31:0] ra, rb, ta, tb_;
  logic [7:0] force_c = 8'h3c, outs_c = 8'h15;

  sim_cabinet_io u_board (
    .uart_rx_i(link_to_board), .uart_tx_o(link_to_core),
    .switches_i(sw), .wheel12_i(wheel), .brake12_i(brake), .gas_i(gas), .clutch_i(clutch),
    .seat_i(seat), .shifter_x_i(shx), .shifter_y_i(shy), .brake8_i(brake8), .corrupt_i(corrupt),
    .force_o(force_b), .outputs_o(outs_b), .frames_out(frames_out)
  );
  rd_cabinet_io u_io (
    .clk_i(clk), .rst_i(rst), .uart_rx_i(link_to_core), .uart_tx_o(link_to_board),
    .switches_o(sw_o), .wheel12_o(wheel_o), .brake12_o(brake_o), .gas_o(gas_o), .clutch_o(clutch_o),
    .seat_o(seat_o), .shifter_x_o(shx_o), .shifter_y_o(shy_o), .brake8_o(brake8_o),
    .board_ok_o(board_ok), .frame_o(frame),
    .duart_rxa_o(rxa), .duart_rxb_o(rxb), .duart_txa_i(txa), .duart_txb_i(txb),
    .rx_rate_a_i(ra), .rx_rate_b_i(rb), .tx_rate_a_i(ta), .tx_rate_b_i(tb_),
    .force_i(force_c), .outputs_i(outs_c)
  );
  logic req = 0, we = 0; logic [3:0] addr = 0; logic [7:0] wdata = 0, rdata; logic irq;
  mc68681 u_duart (
    .clk_i(clk), .rst_i(rst), .req_i(req), .we_i(we), .addr_i(addr), .wdata_i(wdata), .rdata_o(rdata), .irq_o(irq),
    .tx_a_o(txa), .rx_a_i(rxa), .tx_b_o(txb), .rx_b_i(rxb), .ip_i(7'h40), .op_o(),
    .tx_a_rate_o(ta), .rx_a_rate_o(ra), .tx_b_rate_o(tb_), .rx_b_rate_o(rb)
  );
  task automatic dw(input int r, input logic [7:0] d);
    @(posedge clk); req <= 1; we <= 1; addr <= r[3:0]; wdata <= d; @(posedge clk); req <= 0; repeat (4) @(posedge clk);
  endtask
  task automatic dr(input int r, output logic [7:0] d);
    @(posedge clk); req <= 1; we <= 0; addr <= r[3:0]; #1 d = rdata; @(posedge clk); req <= 0; repeat (4) @(posedge clk);
  endtask
  int errors = 0;
  task automatic check(input bit ok, input string what);
    if (!ok) begin errors++; $display("FAIL: %s", what); end else $display("ok: %s", what);
  endtask

  initial begin
    logic [7:0] d;
    repeat (10) @(posedge clk); rst <= 0;
    // the game's DUART setup: 8N1, 38400 both ways, enable both channels
    dw(2, 8'h10); dw(0, 8'h13); dw(0, 8'h07); dw(1, 8'hcc); dw(4, 8'h30); dw(2, 8'h05);
    dw(10, 8'h10); dw(8, 8'h13); dw(8, 8'h07); dw(9, 8'hcc); dw(10, 8'h05);
    // inputs through a frame
    sw = 16'h0031; wheel = 12'hABC; brake = 12'h123; gas = 8'hfe; clutch = 8'h11; seat = 8'h22; shx = 8'h33; shy = 8'h44; brake8 = 8'h20;
    #(2.5ms);
    check(board_ok, "board_ok after frames");
    check(sw_o == 16'h0031 && wheel_o == 12'habc && brake_o == 12'h123 && gas_o == 8'hfe && clutch_o == 8'h11 &&
          seat_o == 8'h22 && shx_o == 8'h33 && shy_o == 8'h44 && brake8_o == 8'h20, "inputs decoded from the frame");
    check(force_b == 8'h3c && outs_b == 8'h15 && frames_out >= 1, "force byte and outputs in the output frame");
    // a corrupt frame changes nothing
    corrupt = 1; gas = 8'h01; #(1.2ms); corrupt = 0;
    check(gas_o == 8'hfe, "corrupt frame dropped");
    #(1.5ms);
    check(gas_o == 8'h01, "next good frame applied");
    // serial: DUART transmits on A and B, the board receives them in output frames
    dw(3, 8'h5a); dw(11, 8'ha5);
    #(2ms);
    check(u_board.got_a.size() == 1 && u_board.got_a[0] == 8'h5a, "DUART A byte reached the board");
    check(u_board.got_b.size() == 1 && u_board.got_b[0] == 8'ha5, "DUART B byte reached the board");
    // serial: the board sends bytes, the DUART receives them
    u_board.ser_a.push_back(8'h77); u_board.ser_a.push_back(8'h88); u_board.ser_b.push_back(8'h99);
    #(3ms);
    dr(1, d); check(d[0] == 1'b1, "SRA RxRDY after board bytes");
    dr(3, d); check(d == 8'h77, "RHRA first byte"); dr(3, d); check(d == 8'h88, "RHRA second byte");
    dr(11, d); check(d == 8'h99, "RHRB byte");
    // silence releases the inputs
    force u_board.uart_tx_o = 1'b1;
    #(60ms);
    check(!board_ok && gas_o == 8'h00 && sw_o == 16'h0000 && wheel_o == 12'h800, "inputs released after 50 ms of silence");
    $display("tb_cabio: %0d failures", errors);
    $finish;
  end
endmodule
