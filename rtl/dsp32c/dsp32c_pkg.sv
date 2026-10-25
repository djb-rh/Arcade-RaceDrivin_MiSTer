`default_nettype none

// AT&T DSP32C as modelled by MAME (src/devices/cpu/dsp32, BSD-3-Clause,
// Aaron Giles): instruction classes decoded from opcode bits 31:21 the way
// MAME's dispatch table does, and the number conversions MAME performs
// between the DSP32C's 32-bit float (sign, 23-bit fraction, 8-bit exponent
// in the low byte, two's-complement mantissa for negatives) and the IEEE
// double it computes in.  The core keeps accumulators as doubles so that
// it can be compared bit for bit with MAME; see docs/dsp32c.md.
package dsp32c_pkg;

  typedef enum logic [4:0] {
    OP_ILLEGAL,
    OP_NOP,        // table 0: op == 0 nothing, otherwise an unconditional goto
    OP_GOTO,       // 0x001-0x019: condition = table index; 0x024-0x027 PDF/PIF
    OP_DEC_GOTO,   // 0x060-0x07f
    OP_CALL,       // 0x080-0x09f
    OP_ADD_SI,     // 0x0a0-0x0bf  (0x4a0-0x4bf: 24-bit)
    OP_ALU_SS,     // 0x0c0-0x0cf  (0x4c0: 24-bit)
    OP_ALU_DI,     // 0x0d0-0x0df  (0x4d0: 24-bit)
    OP_LDST,       // 0x0e0-0x0ff
    OP_D1, OP_D2, OP_D3, OP_D4, OP_D5,
    OP_GOTO24,     // 0x500-0x5ff
    OP_LOAD24,     // 0x600-0x6ff
    OP_CALL24      // 0x700-0x7ff
  } opclass_t;

  typedef struct packed {
    opclass_t   cls;
    logic       e24;      // 24-bit CAU variant
    logic [4:0] cond;     // OP_GOTO: branch condition code (MAME condition())
    logic       pio_flag; // OP_GOTO 0x24-0x27: PDF/PIF conditions
    logic [3:0] sub;      // ALU sub-op, load/store kind, d5 kind
    logic [2:0] am;       // DAU accumulator field (op[28:26])
    logic [1:0] sgn;      // DAU sign pattern: 00 ++, 01 +-, 10 -+, 11 --
  } decode_t;

  function automatic decode_t decode(input logic [31:0] op);
    decode_t d;
    logic [10:0] t;
    t = op[31:21];
    d = '{cls: OP_ILLEGAL, e24: 1'b0, cond: 5'd0, pio_flag: 1'b0, sub: 4'd0, am: op[28:26], sgn: t[3:2]};
    if (t == 11'h000) d.cls = OP_NOP;
    else if (t >= 11'h001 && t <= 11'h019) begin d.cls = OP_GOTO; d.cond = t[4:0]; end
    else if (t >= 11'h024 && t <= 11'h027) begin d.cls = OP_GOTO; d.cond = t[4:0]; d.pio_flag = 1'b1; end
    else if (t[10:5] == 6'h03) d.cls = OP_DEC_GOTO;                       // 0x60-0x7f
    else if (t[10:5] == 6'h04) d.cls = OP_CALL;                           // 0x80-0x9f
    else if (t[10:5] == 6'h05 || t[10:5] == 6'h25) begin d.cls = OP_ADD_SI; d.e24 = t[10]; end
    else if (t[10:4] == 7'h0c || t[10:4] == 7'h4c) begin d.cls = OP_ALU_SS; d.e24 = t[10]; d.sub = t[3:0]; end
    else if (t[10:4] == 7'h0d || t[10:4] == 7'h4d) begin
      d.e24 = t[10]; d.sub = t[3:0];
      case (t[3:0])
        4'h0, 4'h2, 4'h4, 4'h6, 4'h7, 4'h8, 4'ha, 4'he, 4'hf: d.cls = OP_ALU_DI;
        default: d.cls = OP_ILLEGAL;                                     // 1,3(addr),5,9,b,c,d
      endcase
    end
    else if (t[10:5] == 6'h07) begin d.cls = OP_LDST; d.sub = t[4:1]; end  // 0xe0-0xff
    else if (t[10:8] == 3'd1) begin                                       // 0x100-0x1ff
      if (t[4]) d.cls = OP_ILLEGAL;                                       // 'r' variants: MAME unimplemented
      else if (t[7:5] == 3'd6) d.cls = OP_D4;
      else if (t[7:5] == 3'd7) d.cls = OP_ILLEGAL;
      else d.cls = OP_D1;                                                 // am 0-3 aM, 4 "0", 5 "1"
    end
    else if (t[10:8] == 3'd2) d.cls = (t[4] || t[7:5] > 3'd5) ? OP_ILLEGAL : OP_D2;
    else if (t[10:8] == 3'd3) begin
      if (t[7:6] == 2'b11) begin                                          // 0x3c0-0x3ff
        d.sub = t[5:2];
        case (t[5:2])
          4'd2, 4'd3, 4'd4, 4'd5, 4'd6, 4'd7, 4'd10, 4'd11, 4'd14: d.cls = OP_D5;
          default: d.cls = OP_ILLEGAL;                                   // ic, oc, ieee, dsp: unimplemented
        endcase
      end else d.cls = (t[4] || t[7:5] > 3'd5) ? OP_ILLEGAL : OP_D3;
    end
    else if (t[10:8] == 3'd5) d.cls = OP_GOTO24;
    else if (t[10:8] == 3'd6) d.cls = OP_LOAD24;
    else if (t[10:8] == 3'd7) d.cls = OP_CALL24;
    return d;
  endfunction

  // MAME WRITEABLE_REGS = 0x6f3efffe
  function automatic logic reg_writeable(input logic [4:0] r);
    return (32'h6f3efffe >> r) & 1'b1;
  endfunction

  // ---- MAME dsp_to_double / double_to_dsp, bit for bit ------------------
  function automatic logic [63:0] dsp_to_double(input logic [31:0] val);
    logic [31:0] exponent, nv, hi, lo;
    if (val == 32'd0) return 64'd0;
    exponent = ({24'd0, val[7:0]} + 32'd895) << 20;        // (e - 128 + 1023) << 20
    if (!val[31]) begin
      hi = exponent + (val >> 11);
      lo = (val << 21) & 32'he0000000;
    end else begin
      nv = 32'd0 - (val & 32'hffffff00);
      hi = 32'h80000000 + exponent + ((nv >> 11) & 32'h001fffff);
      lo = (nv << 21) & 32'he0000000;
    end
    return {hi, lo};
  endfunction

  function automatic logic [31:0] double_to_dsp(input logic [63:0] d);
    logic [31:0] hi, lo, mantissa;
    logic signed [31:0] exponent;
    hi = d[63:32]; lo = d[31:0];
    mantissa = ((hi & 32'h000fffff) << 11) | ((lo & 32'he0000000) >> 21);
    exponent = $signed({21'd0, hi[30:20]}) - 32'sd1023 + 32'sd128;
    if (exponent < 0) return 32'h00000000;
    else if (exponent > 255) return hi[31] ? 32'h800000ff : 32'h7fffffff;
    else if (!hi[31]) return exponent[31:0] | mantissa;
    else begin
      mantissa = 32'd0 - mantissa;
      if (mantissa == 32'd0) begin mantissa = 32'h80000000; exponent = exponent - 32'sd1; end
      return 32'h80000000 | exponent[31:0] | (mantissa & 32'hffffff00);
    end
  endfunction

  // exact (double)(int32)
  function automatic logic [63:0] int_to_double(input logic signed [31:0] v);
    logic [31:0] mag;
    logic [5:0]  lz;
    logic [10:0] e;
    logic [52:0] m;
    if (v == 0) return 64'd0;
    mag = v[31] ? (32'd0 - v) : v;
    lz = 6'd0;
    for (int i = 31; i >= 0; i--) if (mag[i]) begin lz = 6'(31 - i); break; end
    e = 11'd1023 + 11'(31 - lz);
    m = {21'd0, mag} << (lz + 21);                           // hidden bit at 52
    return {v[31], e, m[51:0]};
  endfunction

  // the double's sign and zero test as MAME's `< 0` and `== 0` see them
  function automatic logic dbl_is_zero(input logic [63:0] d);
    return d[62:0] == 63'd0;
  endfunction
  function automatic logic dbl_is_neg(input logic [63:0] d);
    return d[63] && !dbl_is_zero(d);
  endfunction

  // floor / ceil of a double that is not huge (|d| < 2^52 handled exactly,
  // larger values are already integral), then truncation to a saturated
  // int32 as clang's fcvtzs does.
  function automatic logic [63:0] dbl_floor(input logic [63:0] d, input logic ceil_mode);
    logic signed [11:0] e;         // unbiased exponent
    logic [52:0] m;                // with hidden bit
    logic [52:0] frac_mask, mi;
    logic has_frac, bump;
    logic [53:0] mp;
    logic [10:0] eb;
    if (dbl_is_zero(d)) return d;
    e = $signed({1'b0, d[62:52]}) - 12'sd1023;
    if (e >= 52) return d;
    if (e < 0) begin
      // |d| < 1: floor -> -1 or +0, ceil -> +1 or -0
      if (ceil_mode) return d[63] ? 64'h8000000000000000 : 64'h3ff0000000000000;
      else           return d[63] ? 64'hbff0000000000000 : 64'h0000000000000000;
    end
    m = {1'b1, d[51:0]};
    frac_mask = (53'd1 << (52 - e)) - 53'd1;
    has_frac = (m & frac_mask) != 53'd0;
    mi = m & ~frac_mask;
    bump = has_frac && (ceil_mode ? !d[63] : d[63]);     // away from zero
    if (bump) begin
      mp = {1'b0, mi} + {1'b0, (53'd1 << (52 - e))};
      if (mp[53]) begin eb = d[62:52] + 11'd1; return {d[63], eb, mp[52:1]}; end
      return {d[63], d[62:52], mp[51:0]};
    end
    return {d[63], d[62:52], mi[51:0]};
  endfunction

  function automatic logic signed [31:0] dbl_to_int32(input logic [63:0] d);
    logic signed [11:0] e;
    logic [52:0] m;
    logic [31:0] mag;
    if (dbl_is_zero(d)) return 32'sd0;
    e = $signed({1'b0, d[62:52]}) - 12'sd1023;
    if (e < 0) return 32'sd0;
    if (e >= 31) return d[63] ? 32'sh80000000 : 32'sh7fffffff;
    m = {1'b1, d[51:0]};
    mag = 32'(m >> (52 - e));
    return d[63] ? -$signed(mag) : $signed(mag);
  endfunction

  // (double)(float)d: round to nearest even at 24 significant bits, with
  // single-precision denormals for exponents below -126.
  function automatic logic [63:0] dbl_round_to_float(input logic [63:0] d);
    logic signed [11:0] e;
    logic [52:0] m;
    logic [5:0]  drop;            // bits to drop: 29 for normals, more for denormals
    logic [52:0] kept, half, lowmask;
    logic [53:0] r;
    logic guard, sticky, lsb, roundup;
    logic [10:0] eb;
    if (dbl_is_zero(d)) return d;
    e = $signed({1'b0, d[62:52]}) - 12'sd1023;
    m = {1'b1, d[51:0]};
    drop = 6'd29;
    if (e < -126) begin
      if (e < -150) return {d[63], 63'd0};
      drop = 6'(29 + (-126 - e));
    end
    guard = m[drop - 1];
    lowmask = (53'd1 << (drop - 1)) - 53'd1;
    sticky = (m & lowmask) != 53'd0;
    lsb = m[drop];
    roundup = guard && (sticky || lsb);
    kept = (m >> drop) << drop;
    half = 53'd1 << drop;
    r = {1'b0, kept} + (roundup ? {1'b0, half} : 54'd0);
    if (r[53]) begin eb = d[62:52] + 11'd1; return {d[63], eb, r[52:1]}; end
    if (r[52:0] == 53'd0) return {d[63], 63'd0};
    // renormalise if a denormal rounded up into a higher exponent, or if it is
    // zero in the top bit (cannot happen for kept normals)
    return {d[63], d[62:52], r[51:0]};
  endfunction

endpackage

`default_nettype wire
