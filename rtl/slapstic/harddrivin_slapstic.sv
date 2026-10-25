`default_nettype none

// Atari slapstic 137412-111..118 class, as MAME's src/mame/atari/slapstic.cpp
// models it; the defaults are chip 137412-117, the one on the Race Drivin'
// main board (200K), banking 0x0E0000-0x0E7FFF (mirrored through 0x0FFFFF)
// over four 32 KiB banks of the 200Y/210Y ROM pair.
//
// The chip watches every CPU access (A1-A14 plus the chip select for the
// window).  An access to offset 0 of the window arms it; then one of four
// bank addresses switches directly, an "alternate" sequence (A7:A1 pattern
// anywhere, then an in-window address, then a select pattern anywhere whose
// A3:A2 names the bank, then an in-window commit) switches too, and an
// "additive" sequence loads the current bank, adds 1 or 2 per matching
// access and commits the same way.  Any access to offset 0 re-arms.  The
// mask/value pairs are on A14:A1 (CPU byte address bits 14:1).  MAME applies
// a bank change after the access that caused it, so the ROM address for the
// present access uses the bank value before this clock's update.
module harddrivin_slapstic #(
  parameter logic [1:0]  BANK_START = 2'd0,
  parameter logic [13:0] BANK0 = 14'h0008, BANK1 = 14'h001a, BANK2 = 14'h002c, BANK3 = 14'h003e,
  parameter logic [13:0] ALT1_MASK = 14'h007f, ALT1_VAL = 14'h007d,   // anywhere
  parameter logic [13:0] ALT2_MASK = 14'h3fff, ALT2_VAL = 14'h3580,   // in window
  parameter logic [13:0] ALT3_MASK = 14'h0079, ALT3_VAL = 14'h0020,   // anywhere; bank = A3:A2
  parameter logic [13:0] ALT4_MASK = 14'h3fc9, ALT4_VAL = 14'h0008,   // in window
  parameter logic [13:0] ADD1_MASK = 14'h3fff, ADD1_VAL = 14'h0676,   // in window
  parameter logic [13:0] ADD2_MASK = 14'h3fff, ADD2_VAL = 14'h0677,
  parameter logic [13:0] ADDP1_MASK = 14'h3e62, ADDP1_VAL = 14'h1a42,
  parameter logic [13:0] ADDP2_MASK = 14'h3e35, ADDP2_VAL = 14'h1a11,
  parameter logic [13:0] ADD3_MASK = 14'h3fff, ADD3_VAL = 14'h1a42
) (
  input  logic        clk_i,
  input  logic        rst_i,
  input  logic        access_i,     // pulse: the CPU performs a bus cycle at addr_i
  input  logic [23:0] addr_i,
  output logic [1:0]  bank_o
);
  typedef enum logic [2:0] {
    IDLE, ACTIVE, ALT_VALID, ALT_SELECT, ALT_COMMIT, ADD_LOAD, ADD_SET
  } state_t;
  state_t state_q;
  logic [1:0] bank_q, loaded_q;
  assign bank_o = bank_q;

  logic        in_window;
  logic [13:0] a;
  assign in_window = addr_i[23:17] == 7'h07;   // 0x0e0000-0x0fffff
  assign a = addr_i[14:1];
  function automatic logic t_in(input logic [13:0] m, input logic [13:0] v);
    return in_window && ((a & m) == v);
  endfunction
  function automatic logic t_any(input logic [13:0] m, input logic [13:0] v);
    return (a & m) == v;
  endfunction
  logic is_reset;
  assign is_reset = in_window && (a == 14'd0);

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q  <= IDLE;
      bank_q   <= BANK_START;
      loaded_q <= 2'd0;
    end else if (access_i) begin
      unique case (state_q)
        IDLE: if (is_reset) state_q <= ACTIVE;
        ACTIVE: begin
          if      (t_in(14'h3fff, BANK0)) begin bank_q <= 2'd0; state_q <= IDLE; end
          else if (t_in(14'h3fff, BANK1)) begin bank_q <= 2'd1; state_q <= IDLE; end
          else if (t_in(14'h3fff, BANK2)) begin bank_q <= 2'd2; state_q <= IDLE; end
          else if (t_in(14'h3fff, BANK3)) begin bank_q <= 2'd3; state_q <= IDLE; end
          else if (t_any(ALT1_MASK, ALT1_VAL)) state_q <= ALT_VALID;
          else if (t_in(ADD1_MASK, ADD1_VAL))  state_q <= ADD_LOAD;
        end
        ALT_VALID: begin
          if      (is_reset)                   state_q <= ACTIVE;
          else if (t_in(ALT2_MASK, ALT2_VAL))  state_q <= ALT_SELECT;
          else if (t_in(ADD1_MASK, ADD1_VAL))  state_q <= ADD_LOAD;
          else                                 state_q <= ACTIVE;
        end
        ALT_SELECT: begin
          if (is_reset) state_q <= ACTIVE;
          else if (t_any(ALT3_MASK, ALT3_VAL)) begin
            loaded_q <= addr_i[3:2];
            state_q  <= ALT_COMMIT;
          end else state_q <= ACTIVE;
        end
        ALT_COMMIT: begin
          if (is_reset) state_q <= ACTIVE;
          else if (t_in(ALT4_MASK, ALT4_VAL)) begin
            bank_q  <= loaded_q;
            state_q <= IDLE;
          end
        end
        ADD_LOAD: begin
          if (is_reset) state_q <= ACTIVE;
          else if (t_in(ADD2_MASK, ADD2_VAL)) begin
            loaded_q <= bank_q;
            state_q  <= ADD_SET;
          end else state_q <= ACTIVE;
        end
        ADD_SET: begin
          if      (is_reset)                     state_q <= ACTIVE;
          else if (t_in(ADDP1_MASK, ADDP1_VAL))  loaded_q <= loaded_q + 2'd1;
          else if (t_in(ADDP2_MASK, ADDP2_VAL))  loaded_q <= loaded_q + 2'd2;
          else if (t_in(ADD3_MASK, ADD3_VAL))    state_q <= ALT_COMMIT;
        end
        default: state_q <= IDLE;
      endcase
    end
  end
endmodule

`default_nettype wire
