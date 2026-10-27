`default_nettype none

// MC68681 DUART as MAME models it (src/devices/machine/mc68681.cpp,
// BSD-3-Clause), register for register: two asynchronous channels with
// three-deep receive FIFOs, mode registers MR1/MR2 behind a pointer, clock
// select from the two baud-rate tables, command register with the enable
// and reset commands, status with TxRDY/TxEMT/RxRDY/FFULL and the error
// bits, interrupt status and mask with a single IRQ output, counter/timer
// with the start/stop command reads and CUR/CLR, input port with change
// detection, output port with set/reset and ISR routing, interrupt vector.
//
// Timing follows MAME's behavioural model rather than the chip's: a byte
// written to THR goes to the shift register at once if it is empty, TxRDY
// re-asserts one bit time later (MAME: after the start bit) when nothing is
// buffered, TxEMT when the last stop bit has gone out.  Local loopback feeds
// the transmitter's bits straight into the receiver and leaves the pin
// alone.  Baud rates are generated from clk_i with phase accumulators; the
// counter/timer runs from the X1 crystal rate (3.6864 MHz) divided per ACR.
//
// Register access: one clock pulse on req_i with addr_i (A4:A1 of the 68010)
// and we_i; rdata_o is the value MAME returns for that read, with the read's
// side effects (RHR pop, IPCR clear, counter start/stop) applied at the
// clock.
module mc68681 #(
  parameter int CLK_HZ = 48_000_000,
  parameter int X1_HZ  = 3_686_400
) (
  input  logic       clk_i,
  input  logic       rst_i,

  input  logic       req_i,
  input  logic       we_i,
  input  logic [3:0] addr_i,
  input  logic [7:0] wdata_i,
  output logic [7:0] rdata_o,
  output logic       irq_o,

  output logic       tx_a_o,
  input  logic       rx_a_i,
  output logic       tx_b_o,
  input  logic       rx_b_i,
  input  logic [6:0] ip_i,          // IP0-IP6 (bit 7 reads as 1)
  output logic [7:0] op_o,          // OP0-OP7, as pins (inverted OPR)
  // the programmed bit rates, for whatever serialises the lines outside
  output logic [31:0] tx_a_rate_o,
  output logic [31:0] rx_a_rate_o,
  output logic [31:0] tx_b_rate_o,
  output logic [31:0] rx_b_rate_o
);
  // ---- global registers ------------------------------------------------------
  logic [7:0] acr_q, imr_q, isr_q, opcr_q, opr_q, ipcr_q, ivr_q;
  logic [15:0] ctr_q;
  logic [6:0] ip_q;                 // last sampled input port

  // ---- channel state ---------------------------------------------------------
  typedef struct packed {
    logic [7:0] mr1, mr2, csr, cr, sr;
    logic       mr_ptr;
    logic       rx_enabled, tx_enabled, tx_break;
    // receive FIFO: 4 slots (3 plus the holding position MAME keeps), data | errors<<8
    logic [15:0] fifo0, fifo1, fifo2, fifo3;
    logic [1:0]  fifo_rd, fifo_wr;
    logic [2:0]  fifo_num;
    // transmitter
    logic [7:0]  tx_buf;            // THR copy when the shift register is busy
    logic        tx_buf_full;       // m_tx_data_in_buffer
    logic [10:0] tx_shift;          // start, data, parity, stop bits (lsb first)
    logic [3:0]  tx_bits_left;
    logic        tx_busy;           // shift register not empty
    logic [7:0]  tx_bits_sent;      // m_bits_transmitted (255 = none)
    logic        tx_pin;
    // receiver
    logic        rx_sync;           // start bit seen, sampling
    logic [3:0]  rx_bit;            // bits sampled so far
    logic [4:0]  rx_sub;            // 16x sub-bit counter
    logic [9:0]  rx_shift;
    logic        rx_line;
  } chan_t;
  chan_t ca, cb;

  // ---- baud rates and phase accumulators ---------------------------------------
  function automatic logic [31:0] baud_rate(input logic acr7, input logic [3:0] sel);
    if (!acr7) case (sel)
      4'd0: return 50;   4'd1: return 110;  4'd2: return 134;  4'd3: return 200;
      4'd4: return 300;  4'd5: return 600;  4'd6: return 1200; 4'd7: return 1050;
      4'd8: return 2400; 4'd9: return 4800; 4'd10: return 7200; 4'd11: return 9600;
      4'd12: return 38400; default: return 0;        // 13 timer, 14/15 IP3/IP5 clocks: none here
    endcase
    else case (sel)
      4'd0: return 75;   4'd1: return 110;  4'd2: return 134;  4'd3: return 150;
      4'd4: return 300;  4'd5: return 600;  4'd6: return 1200; 4'd7: return 2000;
      4'd8: return 2400; 4'd9: return 4800; 4'd10: return 1800; 4'd11: return 9600;
      4'd12: return 19200; default: return 0;
    endcase
  endfunction

  logic [31:0] txa_acc, rxa_acc, txb_acc, rxb_acc;
  logic txa_tick, rxa_tick, txb_tick, rxb_tick;   // tx: one per bit; rx: 16 per bit
  wire [31:0] txa_rate = baud_rate(acr_q[7], ca.csr[3:0]);
  wire [31:0] rxa_rate = baud_rate(acr_q[7], ca.csr[7:4]) << 4;
  wire [31:0] txb_rate = baud_rate(acr_q[7], cb.csr[3:0]);
  wire [31:0] rxb_rate = baud_rate(acr_q[7], cb.csr[7:4]) << 4;
  assign tx_a_rate_o = txa_rate;
  assign rx_a_rate_o = baud_rate(acr_q[7], ca.csr[7:4]);
  assign tx_b_rate_o = txb_rate;
  assign rx_b_rate_o = baud_rate(acr_q[7], cb.csr[7:4]);
  always_ff @(posedge clk_i) begin
    txa_tick <= 1'b0; rxa_tick <= 1'b0; txb_tick <= 1'b0; rxb_tick <= 1'b0;
    if (rst_i) begin txa_acc <= 0; rxa_acc <= 0; txb_acc <= 0; rxb_acc <= 0; end
    else begin
      if (txa_acc + txa_rate >= CLK_HZ) begin txa_acc <= txa_acc + txa_rate - CLK_HZ; txa_tick <= txa_rate != 0; end else txa_acc <= txa_acc + txa_rate;
      if (rxa_acc + rxa_rate >= CLK_HZ) begin rxa_acc <= rxa_acc + rxa_rate - CLK_HZ; rxa_tick <= rxa_rate != 0; end else rxa_acc <= rxa_acc + rxa_rate;
      if (txb_acc + txb_rate >= CLK_HZ) begin txb_acc <= txb_acc + txb_rate - CLK_HZ; txb_tick <= txb_rate != 0; end else txb_acc <= txb_acc + txb_rate;
      if (rxb_acc + rxb_rate >= CLK_HZ) begin rxb_acc <= rxb_acc + rxb_rate - CLK_HZ; rxb_tick <= rxb_rate != 0; end else rxb_acc <= rxb_acc + rxb_rate;
    end
  end

  // ---- counter / timer -----------------------------------------------------------
  // rate per ACR 6:4: counter mode 0 IP2 (MAME: X1), 1 TxCA, 2 TxCB, 3 X1/16;
  // timer mode 0,1 IP2 (MAME: X1), 2 X1, 3 X1/16.
  logic [31:0] ct_rate;
  always_comb begin
    if (acr_q[6]) ct_rate = (acr_q[5:4] == 2'd3) ? X1_HZ / 16 : X1_HZ;
    else case (acr_q[5:4])
      2'd0: ct_rate = X1_HZ;
      2'd1: ct_rate = txa_rate;
      2'd2: ct_rate = txb_rate;
      default: ct_rate = X1_HZ / 16;
    endcase
  end
  logic [31:0] ct_acc;
  logic        ct_tick, ct_running, ct_half;
  logic [15:0] ct_count;
  always_ff @(posedge clk_i) begin
    ct_tick <= 1'b0;
    if (rst_i) ct_acc <= 0;
    else if (ct_acc + ct_rate >= CLK_HZ) begin ct_acc <= ct_acc + ct_rate - CLK_HZ; ct_tick <= ct_rate != 0; end
    else ct_acc <= ct_acc + ct_rate;
  end

  // ---- helpers -------------------------------------------------------------------
  function automatic logic [3:0] data_bits(input logic [7:0] mr1);  return 4'd5 + {2'b0, mr1[1:0]}; endfunction
  function automatic logic has_parity(input logic [7:0] mr1);       return mr1[4:3] != 2'b10 && mr1[4:3] != 2'b11; endfunction
  function automatic logic parity_bit(input logic [7:0] mr1, input logic [7:0] d, input logic [3:0] n);
    logic p; logic [7:0] m;
    m = d & ((8'd1 << n) - 8'd1);
    p = ^m;
    case (mr1[4:3])
      2'b00: return mr1[2] ? ~p : p;          // odd : even
      2'b01: return mr1[2];                   // mark : space
      default: return 1'b0;
    endcase
  endfunction
  // stop bits: MR2 3:2 = 00/01 -> 1, 10 -> 1.5 (treated as 2 here), 11 -> 2
  function automatic logic [1:0] stop_bits(input logic [7:0] mr2); return (mr2[3:2] >= 2'd2) ? 2'd2 : 2'd1; endfunction

  localparam logic [7:0] SR_BREAK = 8'h80, SR_FRAME = 8'h40, SR_PARITY = 8'h20, SR_OVERRUN = 8'h10,
                         SR_TXEMT = 8'h08, SR_TXRDY = 8'h04, SR_FFULL = 8'h02, SR_RXRDY = 8'h01;
  localparam logic [7:0] INT_IPC = 8'h80, INT_DBB = 8'h40, INT_RXB = 8'h20, INT_TXB = 8'h10,
                         INT_CT = 8'h08, INT_DBA = 8'h04, INT_RXA = 8'h02, INT_TXA = 8'h01;

  // the ISR bits a channel's status implies (duart_channel::update_interrupts)
  function automatic logic [1:0] chan_isr(input chan_t c);   // {rx, tx}
    logic tx, rx; logic [7:0] sr;
    sr = c.sr;
    if (c.mr2[7:6] == 2'b01 || c.mr2[7:6] == 2'b11) sr[2] = 1'b0;   // echo / remote loopback: no TxRDY
    tx = sr[2];
    rx = c.mr1[6] ? sr[1] : sr[0];
    return {rx, tx};
  endfunction

  assign irq_o = (isr_q & imr_q) != 8'h00;
  assign op_o  = ~opr_q;

  // ---- combinational read data (before this access's side effects) ----------------
  function automatic logic [7:0] chan_read(input chan_t c, input logic [1:0] r);
    case (r)
      2'd0: return c.mr_ptr ? c.mr2 : c.mr1;
      2'd1: return c.sr;
      2'd3: return c.fifo_num == 0 ? 8'h00 :
                   (c.fifo_rd == 0 ? c.fifo0[7:0] : c.fifo_rd == 1 ? c.fifo1[7:0] : c.fifo_rd == 2 ? c.fifo2[7:0] : c.fifo3[7:0]);
      default: return 8'hff;
    endcase
  endfunction
  always_comb begin
    case (addr_i)
      4'h0, 4'h1, 4'h3: rdata_o = chan_read(ca, addr_i[1:0]);
      4'h4: rdata_o = ipcr_q;
      4'h5: rdata_o = isr_q;
      4'h6: rdata_o = ct_count[15:8];
      4'h7: rdata_o = ct_count[7:0];
      4'h8, 4'h9, 4'hb: rdata_o = chan_read(cb, addr_i[1:0]);
      4'ha: rdata_o = 8'h61;
      4'hc: rdata_o = ivr_q;
      4'hd: rdata_o = {1'b1, ip_q};
      default: rdata_o = 8'hff;                       // start/stop counter commands
    endcase
  end

  // ---- channel procedures ---------------------------------------------------------
  function automatic logic [15:0] fifo_at(input chan_t c, input logic [1:0] i);
    case (i) 2'd0: return c.fifo0; 2'd1: return c.fifo1; 2'd2: return c.fifo2; default: return c.fifo3; endcase
  endfunction
  function automatic chan_t fifo_set(input chan_t c, input logic [1:0] i, input logic [15:0] v);
    chan_t n; n = c;
    case (i) 2'd0: n.fifo0 = v; 2'd1: n.fifo1 = v; 2'd2: n.fifo2 = v; default: n.fifo3 = v; endcase
    return n;
  endfunction

  // duart_channel::rx_fifo_push
  function automatic chan_t fifo_push(input chan_t c, input logic [7:0] d, input logic [7:0] errors);
    chan_t n; n = c;
    if (n.fifo_num == 3'd4) begin
      n.sr |= SR_OVERRUN;
      n.fifo_wr = n.fifo_wr - 2'd1;            // overwrite the tail
    end
    n = fifo_set(n, n.fifo_wr, {errors, d});
    n.fifo_wr = n.fifo_wr + 2'd1;
    if (n.fifo_num <= 3'd3) n.fifo_num = n.fifo_num + 3'd1;
    if (n.fifo_num == 3'd1) begin
      n.sr |= SR_RXRDY;
      if (!n.mr1[5]) n.sr &= ~(SR_BREAK | SR_FRAME | SR_PARITY);
      n.sr |= errors;
    end
    if (n.fifo_num == 3'd3) n.sr |= SR_FFULL;
    return n;
  endfunction

  // duart_channel::read_rx_fifo side effects
  function automatic chan_t fifo_pop(input chan_t c);
    chan_t n; logic [15:0] head;
    n = c;
    if (n.fifo_num == 3'd0) return n;
    n.fifo_rd = n.fifo_rd + 2'd1;
    n.fifo_num = n.fifo_num - 3'd1;
    if (n.fifo_num == 3'd2) n.sr &= ~SR_FFULL;
    if (!n.mr1[5]) n.sr &= ~(SR_BREAK | SR_FRAME | SR_PARITY);
    // Quartus cannot bit-select a function call result directly.
    head = fifo_at(n, n.fifo_rd);
    if (n.fifo_num == 3'd0) n.sr &= ~SR_RXRDY;
    else n.sr |= head[15:8];
    return n;
  endfunction

  // duart_channel::write_CR (the ISR effects are applied by the caller from chan_isr)
  function automatic chan_t chan_cr(input chan_t c, input logic [7:0] data, output logic set_dbrk, output logic clr_dbrk, output logic brk_push);
    chan_t n; n = c;
    set_dbrk = 1'b0; clr_dbrk = 1'b0; brk_push = 1'b0;
    case (data[6:4])
      3'd1: n.mr_ptr = 1'b0;
      3'd2: begin
        n.rx_enabled = 1'b0;
        n.sr &= ~(SR_RXRDY | SR_BREAK | SR_FRAME | SR_PARITY | SR_OVERRUN);
        n.fifo_rd = 0; n.fifo_wr = 0; n.fifo_num = 0;
        n.rx_sync = 1'b0;
      end
      3'd3: begin
        n.sr &= ~(SR_TXRDY | SR_TXEMT);
        n.tx_pin = 1'b1; n.tx_busy = 1'b0; n.tx_bits_sent = 8'd255; n.tx_buf_full = 1'b0; n.tx_enabled = 1'b0;
      end
      3'd4: n.sr &= ~(SR_BREAK | SR_FRAME | SR_PARITY | SR_OVERRUN);
      3'd5: clr_dbrk = 1'b1;
      3'd6: if (!n.tx_break) begin
        n.tx_break = 1'b1;
        if (n.mr2[7:6] == 2'b10) begin set_dbrk = 1'b1; brk_push = 1'b1; end
      end
      3'd7: if (n.tx_break) begin
        n.tx_break = 1'b0;
        if (n.mr2[7:6] == 2'b10) set_dbrk = 1'b1;
      end
      default: ;
    endcase
    if (data[0]) n.rx_enabled = 1'b1;
    if (data[1]) begin n.rx_enabled = 1'b0; n.sr &= ~SR_RXRDY; end
    if (!c.cr[2] && data[2]) begin
      n.sr |= SR_TXRDY | SR_TXEMT;
      n.tx_buf_full = 1'b0; n.tx_enabled = 1'b1;
    end
    if (data[3]) begin
      n.sr &= ~(SR_TXRDY | SR_TXEMT);
      n.tx_buf_full = 1'b0; n.tx_enabled = 1'b0;
    end
    n.cr = data;
    return n;
  endfunction

  // load the transmit shift register: start, data (lsb first), parity, stop bits
  function automatic chan_t tx_load(input chan_t c, input logic [7:0] d);
    chan_t n; logic [3:0] nd; logic [10:0] sh; logic [3:0] total; logic p;
    n = c;
    nd = data_bits(n.mr1);
    p = parity_bit(n.mr1, d, nd);
    sh = 11'h7ff;                                   // idle/stop bits are 1
    sh[0] = 1'b0;                                   // start
    for (int i = 0; i < 8; i++) if (i < nd) sh[1 + i] = d[i];
    total = 4'd1 + nd;
    if (has_parity(n.mr1)) begin sh[total] = p; total = total + 4'd1; end
    total = total + {2'b0, stop_bits(n.mr2)};
    n.tx_shift = sh; n.tx_bits_left = total; n.tx_busy = 1'b1; n.tx_bits_sent = 8'd0;
    return n;
  endfunction

  // one transmit bit time (tra_callback / tra_complete)
  function automatic chan_t tx_tick(input chan_t c, output logic loop_bit, output logic loop_valid);
    chan_t n; n = c;
    loop_valid = 1'b0; loop_bit = 1'b1;
    if (!n.tx_busy) return n;
    // output the next bit
    if (n.mr2[7:6] != 2'b10) n.tx_pin = n.tx_shift[0];
    else begin loop_valid = 1'b1; loop_bit = n.tx_shift[0]; end
    n.tx_shift = {1'b1, n.tx_shift[10:1]};
    n.tx_bits_left = n.tx_bits_left - 4'd1;
    if (n.tx_bits_sent != 8'd255) n.tx_bits_sent = n.tx_bits_sent + 8'd1;
    if (n.tx_bits_sent > 8'd1 && !n.tx_buf_full && n.tx_enabled) n.sr |= SR_TXRDY;
    if (n.tx_bits_left == 4'd0) begin
      // tra_complete
      if (n.tx_buf_full) begin
        n = tx_load(n, n.tx_buf);
        n.tx_buf_full = 1'b0;
        n.sr |= SR_TXRDY;
      end else begin
        n.tx_busy = 1'b0;
        n.sr |= SR_TXEMT;
      end
    end
    return n;
  endfunction

  // one receive sub-bit time (16 per bit); returns a completed character
  function automatic chan_t rx_tick(input chan_t c, input logic line, output logic got, output logic [7:0] d, output logic [7:0] errors);
    chan_t n; logic [3:0] nd; logic [3:0] nbits; logic p; logic [7:0] data;
    n = c; got = 1'b0; d = 8'h00; errors = 8'h00;
    nd = data_bits(n.mr1);
    nbits = nd + (has_parity(n.mr1) ? 4'd1 : 4'd0) + 4'd1;     // data, parity, one stop sampled
    if (!n.rx_sync) begin
      if (!line) begin n.rx_sync = 1'b1; n.rx_sub = 5'd24; n.rx_bit = 4'd0; n.rx_shift = 10'd0; end  // sample mid-bit of bit 1
    end else begin
      if (n.rx_sub == 5'd0) begin
        n.rx_sub = 5'd15;
        n.rx_shift[n.rx_bit] = line;
        n.rx_bit = n.rx_bit + 4'd1;
        if (n.rx_bit == nbits) begin
          n.rx_sync = 1'b0;
          got = 1'b1;
          data = 8'd0;
          for (int i = 0; i < 8; i++) if (i < nd) data[i] = n.rx_shift[i];
          d = data;
          if (!line) errors |= SR_FRAME;                       // stop bit low
          if (has_parity(n.mr1)) begin
            p = n.rx_shift[nd];
            if (p != parity_bit(n.mr1, data, nd)) errors |= SR_PARITY;
          end
        end
      end else n.rx_sub = n.rx_sub - 5'd1;
    end
    return n;
  endfunction

  function automatic chan_t chan_reset(input chan_t c);
    chan_t n; logic a, b, p;
    n = c;
    n = chan_cr(n, 8'h10, a, b, p); n = chan_cr(n, 8'h20, a, b, p);
    n = chan_cr(n, 8'h30, a, b, p); n = chan_cr(n, 8'h40, a, b, p);
    n.csr = 8'h00; n.tx_break = 1'b0; n.mr1 = 8'h00; n.mr2 = 8'h00;
    return n;
  endfunction

  // ---- the register machine --------------------------------------------------------
  logic loop_a, loop_a_v, loop_b, loop_b_v;
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      acr_q <= 0; imr_q <= 0; isr_q <= 0; opcr_q <= 0; opr_q <= 0; ipcr_q <= 0; ivr_q <= 8'h0f; ctr_q <= 0;
      ct_running <= 1'b0; ct_half <= 1'b0; ct_count <= 16'd0;
      ca <= chan_reset('0); cb <= chan_reset('0);
      ca.tx_pin <= 1'b1; cb.tx_pin <= 1'b1; ca.rx_line <= 1'b1; cb.rx_line <= 1'b1;
      ip_q <= ip_i;
    end else begin
      chan_t na, nb; logic [7:0] isr; logic set_dbrk, clr_dbrk, brk_push;
      logic got; logic [7:0] rd, rerr; logic lb, lv;
      na = ca; nb = cb; isr = isr_q;

      // ---- serial timing: transmit bits, receive sampling ----
      if (txa_tick) begin na = tx_tick(na, lb, lv); if (lv) na.rx_line = lb; end
      if (txb_tick) begin nb = tx_tick(nb, lb, lv); if (lv) nb.rx_line = lb; end
      if (na.mr2[7:6] != 2'b10) na.rx_line = rx_a_i;
      if (nb.mr2[7:6] != 2'b10) nb.rx_line = rx_b_i;
      if (rxa_tick) begin
        na = rx_tick(na, na.rx_line, got, rd, rerr);
        if (got && (na.rx_enabled || na.mr2[7:6] == 2'b10)) na = fifo_push(na, rd, rerr);
      end
      if (rxb_tick) begin
        nb = rx_tick(nb, nb.rx_line, got, rd, rerr);
        if (got && (nb.rx_enabled || nb.mr2[7:6] == 2'b10)) nb = fifo_push(nb, rd, rerr);
      end

      // ---- counter / timer ----
      if (ct_running && ct_tick) begin
        if (ct_count <= 16'd1) begin
          if (acr_q[6]) begin                                   // timer mode
            ct_half <= !ct_half;
            if (opcr_q[3:2] == 2'b01) opr_q[3] <= !opr_q[3];
            if (ct_half) isr |= INT_CT;                         // falling half period
            ct_count <= (ctr_q == 16'd0) ? 16'd1 : ctr_q;
          end else begin
            if (opcr_q[3:2] == 2'b01) opr_q[3] <= 1'b1;
            isr |= INT_CT;
            ct_count <= 16'hffff;
          end
        end else ct_count <= ct_count - 16'd1;
      end

      // ---- input port change detection ----
      ip_q <= ip_i;
      for (int i = 0; i < 4; i++) if (ip_i[i] != ip_q[i]) begin
        ipcr_q[4 + i] <= 1'b1;
        if (acr_q[i]) isr |= INT_IPC;
      end
      ipcr_q[3:0] <= ip_i[3:0];

      // ---- register access ----
      if (req_i && we_i) begin
        case (addr_i)
          4'h0, 4'h8: begin                                     // MR1/MR2
            if (addr_i[3]) begin if (!nb.mr_ptr) begin nb.mr1 = wdata_i; nb.mr_ptr = 1'b1; end else nb.mr2 = wdata_i; end
            else          begin if (!na.mr_ptr) begin na.mr1 = wdata_i; na.mr_ptr = 1'b1; end else na.mr2 = wdata_i; end
          end
          4'h1: na.csr = wdata_i;
          4'h9: nb.csr = wdata_i;
          4'h2, 4'ha: begin
            if (addr_i[3]) begin
              nb = chan_cr(nb, wdata_i, set_dbrk, clr_dbrk, brk_push);
              if (set_dbrk) isr |= INT_DBB; if (clr_dbrk) isr &= ~INT_DBB;
              if (brk_push) nb = fifo_push(nb, 8'h00, SR_BREAK);
            end else begin
              na = chan_cr(na, wdata_i, set_dbrk, clr_dbrk, brk_push);
              if (set_dbrk) isr |= INT_DBA; if (clr_dbrk) isr &= ~INT_DBA;
              if (brk_push) na = fifo_push(na, 8'h00, SR_BREAK);
            end
          end
          4'h3, 4'hb: begin                                     // THR: write_TX
            if (addr_i[3]) begin
              if (nb.sr[2]) begin
                nb.sr &= ~(SR_TXRDY | SR_TXEMT);
                if (nb.tx_busy) begin nb.tx_buf = wdata_i; nb.tx_buf_full = 1'b1; end
                else nb = tx_load(nb, wdata_i);
              end
            end else begin
              if (na.sr[2]) begin
                na.sr &= ~(SR_TXRDY | SR_TXEMT);
                if (na.tx_busy) begin na.tx_buf = wdata_i; na.tx_buf_full = 1'b1; end
                else na = tx_load(na, wdata_i);
              end
            end
          end
          4'h4: begin                                           // ACR
            if ((acr_q[6] ^ wdata_i[6])) begin
              if (wdata_i[6]) begin ct_half <= 1'b0; ct_count <= (ctr_q == 0) ? 16'd1 : ctr_q; ct_running <= 1'b1; end
              else ct_running <= 1'b0;
            end
            if ((ipcr_q[7:4] & wdata_i[3:0]) != 4'd0) isr |= INT_IPC;
            acr_q <= wdata_i;
          end
          4'h5: imr_q <= wdata_i;
          4'h6: ctr_q[15:8] <= wdata_i;
          4'h7: ctr_q[7:0] <= wdata_i;
          4'hd: opcr_q <= wdata_i;
          4'he: opr_q <= opr_q | wdata_i;
          4'hf: opr_q <= opr_q & ~wdata_i;
          default: ;
        endcase
      end else if (req_i) begin
        case (addr_i)
          4'h0: na.mr_ptr = 1'b1;
          4'h8: nb.mr_ptr = 1'b1;
          4'h3: na = fifo_pop(na);
          4'hb: nb = fifo_pop(nb);
          4'h4: begin ipcr_q[7:4] <= 4'd0; isr &= ~INT_IPC; end
          4'he: begin                                           // start counter/timer
            if (acr_q[6]) ct_half <= 1'b0;
            ct_count <= (ctr_q == 0) ? 16'd1 : ctr_q;
            ct_running <= 1'b1;
          end
          4'hf: begin                                           // stop counter
            if (!acr_q[6]) begin
              ct_running <= 1'b0;
              if (opcr_q[3:2] == 2'b01) opr_q[3] <= 1'b0;
            end
            isr &= ~INT_CT;
          end
          default: ;
        endcase
      end

      // ---- channel status -> ISR (duart_channel::update_interrupts) ----
      begin
        logic [1:0] fa, fb;
        fa = chan_isr(na); fb = chan_isr(nb);
        isr = (isr & ~(INT_TXA | INT_RXA | INT_TXB | INT_RXB)) |
              (fa[0] ? INT_TXA : 8'h00) | (fa[1] ? INT_RXA : 8'h00) |
              (fb[0] ? INT_TXB : 8'h00) | (fb[1] ? INT_RXB : 8'h00);
        // ISR routed to OP7:4 when enabled
        if (opcr_q[4]) opr_q[4] <= isr[1];
        if (opcr_q[5]) opr_q[5] <= isr[5];
        if (opcr_q[6]) opr_q[6] <= isr[0];
        if (opcr_q[7]) opr_q[7] <= isr[4];
      end
      ca <= na; cb <= nb; isr_q <= isr;
    end
  end
  assign tx_a_o = ca.tx_pin;
  assign tx_b_o = cb.tx_pin;
endmodule

`default_nettype wire
