`default_nettype none

// Core side of the cabinet I/O board link (docs/cabinet-io.md): a 2 Mbaud
// UART to the ESP32-S3 board, input frames decoded into the cabinet
// controls, output frames carrying the force byte, lamps, coin counters,
// the DSK LED and the two serial channels.  The MC68681's channels stay
// serial lines: bytes from input frames are re-serialised onto its RX pins
// at the rate the game programmed, bytes it transmits are received from its
// TX pins and sent in output frames.
module rd_cabinet_io #(
  parameter int CLK_HZ   = 48_000_000,
  parameter int LINK_BAUD = 2_000_000,
  parameter int TIMEOUT_MS = 50
) (
  input  logic        clk_i,
  input  logic        rst_i,

  input  logic        uart_rx_i,          // from the board
  output logic        uart_tx_o,          // to the board

  // cabinet inputs from the last good frame (released when the board is silent)
  output logic [15:0] switches_o,         // docs/cabinet-io.md bit assignment, 1 = active
  output logic [11:0] wheel12_o,
  output logic [11:0] brake12_o,          // 0 released
  output logic [7:0]  gas_o,
  output logic [7:0]  clutch_o,
  output logic [7:0]  seat_o,
  output logic [7:0]  shifter_x_o,
  output logic [7:0]  shifter_y_o,
  output logic [7:0]  brake8_o,           // compact transducer, 0xf0 released
  output logic        board_ok_o,         // a valid frame within TIMEOUT_MS
  output logic        frame_o,            // pulse: input frame accepted

  // the DUART's serial lines and programmed rates
  output logic        duart_rxa_o,
  output logic        duart_rxb_o,
  input  logic        duart_txa_i,
  input  logic        duart_txb_i,
  input  logic [31:0] rx_rate_a_i,
  input  logic [31:0] rx_rate_b_i,
  input  logic [31:0] tx_rate_a_i,
  input  logic [31:0] tx_rate_b_i,

  // outputs to the board
  input  logic [7:0]  force_i,
  input  logic [7:0]  outputs_i           // bit 0 seat lamp, 1 abort lamp, 2 counter 1, 3 counter 2, 4 DSK LED
);
  localparam int BIT_CLKS = CLK_HZ / LINK_BAUD;
  localparam int TIMEOUT_CLKS = (CLK_HZ / 1000) * TIMEOUT_MS;

  function automatic logic [7:0] crc8(input logic [7:0] crc, input logic [7:0] d);
    logic [7:0] c;
    c = crc ^ d;
    for (int i = 0; i < 8; i++) c = c[7] ? ((c << 1) ^ 8'h07) : (c << 1);
    return c;
  endfunction

  // ---- link UART receiver (fixed rate) --------------------------------------
  logic        rx_sync1, rx_sync2;
  logic [7:0]  rx_byte;
  logic        rx_valid;
  logic [3:0]  rx_bit;
  logic [15:0] rx_cnt;
  logic        rx_busy;
  always_ff @(posedge clk_i) begin
    rx_sync1 <= uart_rx_i; rx_sync2 <= rx_sync1;
    rx_valid <= 1'b0;
    if (rst_i) begin rx_busy <= 1'b0; rx_bit <= 0; rx_cnt <= 0; end
    else if (!rx_busy) begin
      if (!rx_sync2) begin rx_busy <= 1'b1; rx_cnt <= 16'(BIT_CLKS + BIT_CLKS / 2 - 1); rx_bit <= 0; end
    end else if (rx_cnt != 0) rx_cnt <= rx_cnt - 16'd1;
    else begin
      rx_cnt <= 16'(BIT_CLKS - 1);
      if (rx_bit < 4'd8) begin rx_byte <= {rx_sync2, rx_byte[7:1]}; rx_bit <= rx_bit + 4'd1; end
      else begin rx_busy <= 1'b0; if (rx_sync2) rx_valid <= 1'b1; end     // stop bit
    end
  end

  // ---- input frame parser -----------------------------------------------------
  logic [4:0]  fr_idx;
  logic        fr_active;
  logic [7:0]  fr_crc;
  logic [7:0]  fr_buf [0:24];
  logic        frame_ok;
  logic [31:0] timeout_q;
  logic [7:0]  seq_q;
  always_ff @(posedge clk_i) begin
    frame_ok <= 1'b0;
    if (rst_i) begin fr_active <= 1'b0; fr_idx <= 0; end
    else if (rx_valid) begin
      if (!fr_active) begin
        if (rx_byte == 8'ha5) begin fr_active <= 1'b1; fr_idx <= 5'd1; fr_crc <= 8'h00; end
      end else begin
        if (fr_idx == 5'd1 && rx_byte != 8'h10) fr_active <= 1'b0;    // not an input frame
        else if (fr_idx < 5'd25) begin
          fr_buf[fr_idx] <= rx_byte;
          fr_crc <= crc8(fr_crc, rx_byte);
          fr_idx <= fr_idx + 5'd1;
        end else begin
          fr_active <= 1'b0;
          if (rx_byte == fr_crc) frame_ok <= 1'b1;
        end
      end
    end
  end

  // decoded inputs with the silence fallback
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      switches_o <= 0; wheel12_o <= 12'h800; brake12_o <= 0; gas_o <= 0; clutch_o <= 0;
      seat_o <= 8'h80; shifter_x_o <= 8'h80; shifter_y_o <= 8'h80; brake8_o <= 8'hf0;
      board_ok_o <= 1'b0; timeout_q <= 0; seq_q <= 0;
    end else begin
      frame_o <= frame_ok;
      if (frame_ok) begin
        seq_q       <= fr_buf[2];
        switches_o  <= {fr_buf[4], fr_buf[3]};
        wheel12_o   <= {fr_buf[6][3:0], fr_buf[5]};
        brake12_o   <= {fr_buf[8][3:0], fr_buf[7]};
        gas_o       <= fr_buf[9];
        clutch_o    <= fr_buf[10];
        seat_o      <= fr_buf[11];
        shifter_x_o <= fr_buf[12];
        shifter_y_o <= fr_buf[13];
        brake8_o    <= fr_buf[14];
        board_ok_o  <= 1'b1;
        timeout_q   <= 0;
      end else if (timeout_q < TIMEOUT_CLKS) timeout_q <= timeout_q + 1;
      else if (board_ok_o) begin
        board_ok_o <= 1'b0;
        switches_o <= 0; wheel12_o <= 12'h800; brake12_o <= 0; gas_o <= 0; clutch_o <= 0;
        seat_o <= 8'h80; shifter_x_o <= 8'h80; shifter_y_o <= 8'h80; brake8_o <= 8'hf0;
      end
    end
  end

  // ---- serial bytes from frames onto the DUART RX pins -------------------------
  // one 16-byte FIFO and a byte serialiser per channel, at the DUART's receive
  // rate.  A frame's up to four bytes per channel are pushed one per clock
  // after the frame is accepted (fr_buf stays valid until the next frame's
  // bytes arrive, 17 byte-times later): four write ports cost ~500 ALMs.
  logic [7:0] fa_mem [0:15], fb_mem [0:15];
  logic [4:0] fa_wr, fa_rd, fb_wr, fb_rd;
  logic [2:0] pa_left, pb_left, pa_idx, pb_idx;
  logic [31:0] sa_acc, sb_acc;
  logic        sa_tick, sb_tick;
  logic [9:0]  sa_shift, sb_shift;
  logic [3:0]  sa_bits, sb_bits;
  always_ff @(posedge clk_i) begin
    sa_tick <= 1'b0; sb_tick <= 1'b0;
    if (rst_i) begin sa_acc <= 0; sb_acc <= 0; end
    else begin
      if (sa_acc + rx_rate_a_i >= CLK_HZ) begin sa_acc <= sa_acc + rx_rate_a_i - CLK_HZ; sa_tick <= rx_rate_a_i != 0; end else sa_acc <= sa_acc + rx_rate_a_i;
      if (sb_acc + rx_rate_b_i >= CLK_HZ) begin sb_acc <= sb_acc + rx_rate_b_i - CLK_HZ; sb_tick <= rx_rate_b_i != 0; end else sb_acc <= sb_acc + rx_rate_b_i;
    end
  end
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      fa_wr <= 0; fa_rd <= 0; fb_wr <= 0; fb_rd <= 0; pa_left <= 0; pb_left <= 0;
      sa_bits <= 0; sb_bits <= 0; duart_rxa_o <= 1'b1; duart_rxb_o <= 1'b1;
    end else begin
      if (frame_ok) begin
        pa_left <= (fr_buf[15][2:0] > 3'd4) ? 3'd4 : fr_buf[15][2:0]; pa_idx <= 0;
        pb_left <= (fr_buf[16][2:0] > 3'd4) ? 3'd4 : fr_buf[16][2:0]; pb_idx <= 0;
      end else begin
        if (pa_left != 0) begin
          if ((fa_wr - fa_rd) < 5'd16) begin fa_mem[fa_wr[3:0]] <= fr_buf[17 + pa_idx]; fa_wr <= fa_wr + 5'd1; end
          pa_left <= pa_left - 3'd1; pa_idx <= pa_idx + 3'd1;
        end
        if (pb_left != 0) begin
          if ((fb_wr - fb_rd) < 5'd16) begin fb_mem[fb_wr[3:0]] <= fr_buf[21 + pb_idx]; fb_wr <= fb_wr + 5'd1; end
          pb_left <= pb_left - 3'd1; pb_idx <= pb_idx + 3'd1;
        end
      end
      // serialiser A: start, 8 data, stop
      if (sa_tick) begin
        if (sa_bits != 0) begin
          duart_rxa_o <= sa_shift[0]; sa_shift <= {1'b1, sa_shift[9:1]}; sa_bits <= sa_bits - 4'd1;
        end else if (fa_rd != fa_wr) begin
          sa_shift <= {1'b1, fa_mem[fa_rd[3:0]], 1'b0}; sa_bits <= 4'd10; fa_rd <= fa_rd + 5'd1;
        end
      end
      if (sb_tick) begin
        if (sb_bits != 0) begin
          duart_rxb_o <= sb_shift[0]; sb_shift <= {1'b1, sb_shift[9:1]}; sb_bits <= sb_bits - 4'd1;
        end else if (fb_rd != fb_wr) begin
          sb_shift <= {1'b1, fb_mem[fb_rd[3:0]], 1'b0}; sb_bits <= 4'd10; fb_rd <= fb_rd + 5'd1;
        end
      end
    end
  end

  // ---- bytes from the DUART TX pins into output frames --------------------------
  // receivers at the DUART's transmit rate (16x sampling), 16-byte FIFOs
  logic [7:0] ta_mem [0:15], tb_mem [0:15];
  logic [4:0] ta_wr, ta_rd, tb_wr, tb_rd;
  logic       pop_a, pop_b;
  logic [31:0] ra_acc, rb_acc;
  logic        ra_tick, rb_tick;
  always_ff @(posedge clk_i) begin
    ra_tick <= 1'b0; rb_tick <= 1'b0;
    if (rst_i) begin ra_acc <= 0; rb_acc <= 0; end
    else begin
      if (ra_acc + (tx_rate_a_i << 4) >= CLK_HZ) begin ra_acc <= ra_acc + (tx_rate_a_i << 4) - CLK_HZ; ra_tick <= tx_rate_a_i != 0; end else ra_acc <= ra_acc + (tx_rate_a_i << 4);
      if (rb_acc + (tx_rate_b_i << 4) >= CLK_HZ) begin rb_acc <= rb_acc + (tx_rate_b_i << 4) - CLK_HZ; rb_tick <= tx_rate_b_i != 0; end else rb_acc <= rb_acc + (tx_rate_b_i << 4);
    end
  end
  logic ra_sync, rb_sync, ra_busy, rb_busy;
  logic [4:0] ra_sub, rb_sub;
  logic [3:0] ra_bit, rb_bit;
  logic [7:0] ra_sh, rb_sh;
  always_ff @(posedge clk_i) begin
    ra_sync <= duart_txa_i; rb_sync <= duart_txb_i;
    if (rst_i) begin ra_busy <= 0; rb_busy <= 0; ta_wr <= 0; tb_wr <= 0; end
    else begin
      if (ra_tick) begin
        if (!ra_busy) begin if (!ra_sync) begin ra_busy <= 1; ra_sub <= 5'd23; ra_bit <= 0; end end
        else if (ra_sub != 0) ra_sub <= ra_sub - 5'd1;
        else begin
          ra_sub <= 5'd15;
          if (ra_bit < 4'd8) begin ra_sh <= {ra_sync, ra_sh[7:1]}; ra_bit <= ra_bit + 4'd1; end
          else begin ra_busy <= 0; if (ra_sync && (ta_wr - ta_rd) < 16) begin ta_mem[ta_wr[3:0]] <= ra_sh; ta_wr <= ta_wr + 5'd1; end end
        end
      end
      if (rb_tick) begin
        if (!rb_busy) begin if (!rb_sync) begin rb_busy <= 1; rb_sub <= 5'd23; rb_bit <= 0; end end
        else if (rb_sub != 0) rb_sub <= rb_sub - 5'd1;
        else begin
          rb_sub <= 5'd15;
          if (rb_bit < 4'd8) begin rb_sh <= {rb_sync, rb_sh[7:1]}; rb_bit <= rb_bit + 4'd1; end
          else begin rb_busy <= 0; if (rb_sync && (tb_wr - tb_rd) < 16) begin tb_mem[tb_wr[3:0]] <= rb_sh; tb_wr <= tb_wr + 5'd1; end end
        end
      end
      if (pop_a) ta_rd <= ta_rd + 5'd1;
      if (pop_b) tb_rd <= tb_rd + 5'd1;
    end
  end

  // ---- output frame builder and link UART transmitter -----------------------------
  // The frame is assembled one byte per clock after an input frame is
  // accepted, the CRC accumulating a byte at a time (a 14-byte CRC chain in
  // one cycle cost ~400 ALMs), then sent one byte at a time from of_buf.
  logic [7:0]  of_buf [0:15];
  logic [4:0]  of_idx;
  logic        of_active, of_fill;
  logic [3:0]  of_fi;
  logic [2:0]  of_na, of_nb;
  logic [7:0]  of_crc, of_byte;
  logic        of_pop_a, of_pop_b;
  logic [7:0]  tx_sh;
  logic [3:0]  tx_bit;
  logic [15:0] tx_cnt;
  logic        tx_busy;
  always_comb begin
    of_pop_a = 1'b0; of_pop_b = 1'b0; of_byte = 8'h00;
    case (of_fi)
      4'd0: of_byte = 8'ha5;
      4'd1: of_byte = 8'h20;
      4'd2: of_byte = fr_buf[2];
      4'd3: of_byte = force_i;
      4'd4: of_byte = outputs_i;
      4'd5: of_byte = {5'd0, of_na};
      4'd6: of_byte = {5'd0, of_nb};
      4'd7, 4'd8, 4'd9, 4'd10:
        if (of_fi - 4'd7 < {1'b0, of_na}) begin of_byte = ta_mem[ta_rd[3:0]]; of_pop_a = 1'b1; end
      4'd11, 4'd12, 4'd13, 4'd14:
        if (of_fi - 4'd11 < {1'b0, of_nb}) begin of_byte = tb_mem[tb_rd[3:0]]; of_pop_b = 1'b1; end
      default: of_byte = of_crc;
    endcase
  end
  assign pop_a = of_fill && of_pop_a;
  assign pop_b = of_fill && of_pop_b;
  always_ff @(posedge clk_i) begin
    if (rst_i) begin of_active <= 0; of_fill <= 0; of_idx <= 0; tx_busy <= 0; uart_tx_o <= 1'b1; of_na <= 0; of_nb <= 0; end
    else begin
      if (frame_ok && !of_active && !of_fill) begin
        of_na <= 3'((ta_wr - ta_rd) > 4 ? 4 : (ta_wr - ta_rd));
        of_nb <= 3'((tb_wr - tb_rd) > 4 ? 4 : (tb_wr - tb_rd));
        of_fill <= 1'b1; of_fi <= 0; of_crc <= 8'h00;
      end else if (of_fill) begin
        of_buf[of_fi] <= of_byte;
        if (of_fi != 0 && of_fi != 4'd15) of_crc <= crc8(of_crc, of_byte);
        of_fi <= of_fi + 4'd1;
        if (of_fi == 4'd15) begin of_fill <= 1'b0; of_active <= 1'b1; of_idx <= 0; end
      end
      // transmitter: one byte at a time from of_buf
      if (of_active && !tx_busy) begin
        tx_sh <= of_buf[of_idx[3:0]]; tx_bit <= 0; tx_cnt <= 16'(BIT_CLKS - 1); tx_busy <= 1'b1; uart_tx_o <= 1'b0;   // start bit
      end else if (tx_busy) begin
        if (tx_cnt != 0) tx_cnt <= tx_cnt - 16'd1;
        else begin
          tx_cnt <= 16'(BIT_CLKS - 1);
          if (tx_bit < 4'd8) begin uart_tx_o <= tx_sh[0]; tx_sh <= tx_sh >> 1; tx_bit <= tx_bit + 4'd1; end
          else if (tx_bit == 4'd8) begin uart_tx_o <= 1'b1; tx_bit <= 4'd9; end         // stop bit
          else begin
            tx_busy <= 1'b0;
            if (of_idx == 5'd15) of_active <= 1'b0; else of_idx <= of_idx + 5'd1;
          end
        end
      end
    end
  end
endmodule

`default_nettype wire
