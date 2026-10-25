// Behavioural model of the cabinet I/O board's ESP32 side (docs/cabinet-io.md)
// for simulation: sends an input frame every 1 ms from its input ports,
// queues serial bytes for either channel, and decodes the output frames into
// the force byte, the outputs and the serial bytes the core transmitted.
`timescale 1ps/1ps
module sim_cabinet_io #(
  parameter int LINK_BAUD = 2_000_000,
  parameter real FRAME_US = 1000.0
) (
  input  logic        uart_rx_i,        // from the core
  output logic        uart_tx_o,        // to the core
  input  logic [15:0] switches_i,
  input  logic [11:0] wheel12_i,
  input  logic [11:0] brake12_i,
  input  logic [7:0]  gas_i, clutch_i, seat_i, shifter_x_i, shifter_y_i, brake8_i,
  input  logic        corrupt_i,        // send the next frame with a bad CRC
  output logic [7:0]  force_o,
  output logic [7:0]  outputs_o,
  output int          frames_out        // output frames decoded
);
  localparam real BIT_PS = 1.0e12 / LINK_BAUD;
  logic [7:0] ser_a [$], ser_b [$];     // bytes to send to the core (pushed by the testbench)
  logic [7:0] got_a [$], got_b [$];     // bytes the core transmitted (popped by the testbench)
  logic [7:0] seq = 0;

  function automatic logic [7:0] crc8(input logic [7:0] crc, input logic [7:0] d);
    logic [7:0] c; c = crc ^ d;
    for (int i = 0; i < 8; i++) c = c[7] ? ((c << 1) ^ 8'h07) : (c << 1);
    return c;
  endfunction

  task automatic send_byte(input logic [7:0] b);
    uart_tx_o = 0; #(BIT_PS);
    for (int i = 0; i < 8; i++) begin uart_tx_o = b[i]; #(BIT_PS); end
    uart_tx_o = 1; #(BIT_PS);
  endtask

  initial begin
    uart_tx_o = 1; frames_out = 0; force_o = 0; outputs_o = 0;
    forever begin
      logic [7:0] f [0:25]; logic [7:0] c; int na, nb;
      #(FRAME_US * 1.0e6);
      na = ser_a.size() > 4 ? 4 : ser_a.size();
      nb = ser_b.size() > 4 ? 4 : ser_b.size();
      f[0] = 8'ha5; f[1] = 8'h10; f[2] = seq; seq++;
      f[3] = switches_i[7:0]; f[4] = switches_i[15:8];
      f[5] = wheel12_i[7:0]; f[6] = {4'd0, wheel12_i[11:8]};
      f[7] = brake12_i[7:0]; f[8] = {4'd0, brake12_i[11:8]};
      f[9] = gas_i; f[10] = clutch_i; f[11] = seat_i; f[12] = shifter_x_i; f[13] = shifter_y_i; f[14] = brake8_i;
      f[15] = na[7:0]; f[16] = nb[7:0];
      for (int i = 0; i < 4; i++) begin f[17 + i] = (i < na) ? ser_a[i] : 8'h00; f[21 + i] = (i < nb) ? ser_b[i] : 8'h00; end
      c = 0; for (int i = 1; i <= 24; i++) c = crc8(c, f[i]);
      f[25] = corrupt_i ? c ^ 8'h55 : c;
      for (int i = 0; i < 26; i++) send_byte(f[i]);
      if (!corrupt_i) begin
        repeat (na) void'(ser_a.pop_front());
        repeat (nb) void'(ser_b.pop_front());
      end
    end
  end

  // receive output frames
  logic [7:0] rx_byte;
  task automatic recv_byte(output logic [7:0] b);
    @(negedge uart_rx_i); #(BIT_PS * 1.5);
    for (int i = 0; i < 8; i++) begin b[i] = uart_rx_i; #(BIT_PS); end
  endtask
  initial begin
    logic [7:0] b, f [0:15], c;
    forever begin
      recv_byte(b);
      if (b != 8'ha5) continue;
      f[0] = b;
      for (int i = 1; i < 16; i++) recv_byte(f[i]);
      c = 0; for (int i = 1; i <= 14; i++) c = crc8(c, f[i]);
      if (f[1] == 8'h20 && c == f[15]) begin
        force_o = f[3]; outputs_o = f[4];
        for (int i = 0; i < f[5]; i++) got_a.push_back(f[7 + i]);
        for (int i = 0; i < f[6]; i++) got_b.push_back(f[11 + i]);
        frames_out++;
      end else $display("sim_cabinet_io: bad output frame (type %02x crc %02x/%02x)", f[1], f[15], c);
    end
  end
endmodule
