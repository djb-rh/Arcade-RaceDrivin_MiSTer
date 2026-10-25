`default_nettype none

// Race Drivin' DSK board as the 68010 sees it, without the DSP32C (M2):
//
//   0x85c000-0x85c7ff  DSP32C parallel I/O (PIO) registers   placeholder, M3
//   0x85c800-0x85c81f  control latch, 74LS259: A3:A1 function, A4 value
//                      0 DSPRESTN  1 DSPZN (halt)  2 ZW1  3 ZW2
//                      4 ASIC65 reset (0 = held)   7 LED
//   0x900000-0x90ffff  64 KiB RAM (shared with the DSP32C through its PIO)
//   0x910000-0x910fff  zero-power RAM, two MK48Z02 (2816 pinout): 10C on
//                      the high byte, 30C on the low byte
//   0x914000-0x917fff  ASIC65 parameter (even word) / command (odd) / result
//   0x918000-0x91bfff  ASIC65 status, always 0x4000 (ready)
//   0x940000-0x9fffff  track ROM window, served from DDR by the main bus
//
// Everything else inside the two decoded ranges reads 0xffff, as MAME's
// unmapped bus does.  MAME ignores the ZW1/ZW2 write-protect bits for the
// DSK zero-power RAM and so does this module.  One access at a time: the
// request is held until ack_o pulses; RAM and latch accesses take two
// clocks, an ASIC65 result read five.
module harddrivin_dsk_board #(
  parameter ASIC65_SIN_FILE = "rtl/asic65/asic65_sin.hex"
) (
  input  logic        clk_i,
  input  logic        rst_i,

  input  logic        req_i,
  input  logic        we_i,
  input  logic [23:1] addr_i,
  input  logic [1:0]  be_i,          // {upper, lower} byte lane
  input  logic [15:0] wdata_i,
  output logic [15:0] rdata_o,
  output logic        ack_o,

  output logic [7:0]  latch_o,
  output logic        dsp_reset_n_o, // DSPRESTN: 0 holds the DSP32C in reset
  output logic        dsp_halt_n_o,  // DSPZN: 0 halts the DSP32C
  output logic        led_o
);
  logic ram_sel, zram_sel, asic_sel, asic_io_sel, ctl_sel, pio_sel;
  assign ram_sel     = addr_i[23:16] == 8'h90;
  assign zram_sel    = addr_i[23:12] == 12'h910;
  assign asic_sel    = addr_i[23:14] == 10'h245;
  assign asic_io_sel = addr_i[23:14] == 10'h246;
  assign ctl_sel     = addr_i[23:5]  == 19'h42e40;
  assign pio_sel     = addr_i[23:11] == 13'h10b8;

  logic pend_q, asic_wait_q;
  logic start;
  assign start = req_i && !ack_o && !pend_q && !asic_wait_q;

  logic [7:0] latch_q;
  assign latch_o       = latch_q;
  assign dsp_reset_n_o = latch_q[0];
  assign dsp_halt_n_o  = latch_q[1];
  assign led_o         = latch_q[7];

  logic [15:0] ram_rdata, zram_rdata;
  harddrivin_lane_ram #(.ADDR_WIDTH(15)) u_ram (
    .clk_i(clk_i), .en_i(start && ram_sel), .addr_i(addr_i[15:1]),
    .we_hi_i(start && ram_sel && we_i && be_i[1]),
    .we_lo_i(start && ram_sel && we_i && be_i[0]),
    .wdata_i(wdata_i), .rdata_o(ram_rdata)
  );
  harddrivin_lane_ram #(.ADDR_WIDTH(11), .INIT_ONES(1)) u_zram (
    .clk_i(clk_i), .en_i(start && zram_sel), .addr_i(addr_i[11:1]),
    .we_hi_i(start && zram_sel && we_i && be_i[1]),
    .we_lo_i(start && zram_sel && we_i && be_i[0]),
    .wdata_i(wdata_i), .rdata_o(zram_rdata)
  );

  logic        asic_rd_ack;
  logic [15:0] asic_rdata;
  asic65_sim #(.SIN_TABLE_FILE(ASIC65_SIN_FILE)) u_asic65 (
    .clk_i(clk_i), .rst_i(rst_i),
    .reset_we_i(start && we_i && ctl_sel && addr_i[3:1] == 3'd4),
    .reset_state_i(!addr_i[4]),
    .param_we_i(start && we_i && asic_sel && !addr_i[1]),
    .cmd_we_i(start && we_i && asic_sel && addr_i[1]),
    .wdata_i(wdata_i),
    .rd_req_i(start && !we_i && asic_sel),
    .rd_ack_o(asic_rd_ack), .rdata_o(asic_rdata)
  );

  always_ff @(posedge clk_i) begin
    ack_o <= 1'b0;
    if (rst_i) begin
      pend_q      <= 1'b0;
      asic_wait_q <= 1'b0;
      latch_q     <= 8'h00;
      rdata_o     <= 16'hffff;
    end else begin
      if (start) begin
        if (!we_i && asic_sel) asic_wait_q <= 1'b1;
        else pend_q <= 1'b1;
        if (we_i && ctl_sel) latch_q[addr_i[3:1]] <= addr_i[4];
      end
      if (pend_q) begin
        pend_q <= 1'b0;
        ack_o  <= 1'b1;
        rdata_o <= ram_sel     ? ram_rdata :
                   zram_sel    ? zram_rdata :
                   asic_io_sel ? 16'h4000 :
                   pio_sel     ? 16'h0000 :    // M3: DSP32C PIO registers
                                 16'hffff;
      end
      if (asic_wait_q && asic_rd_ack) begin
        asic_wait_q <= 1'b0;
        ack_o       <= 1'b1;
        rdata_o     <= asic_rdata;
      end
    end
  end
endmodule

`default_nettype wire
