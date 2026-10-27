`default_nettype none

// Double-precision fused multiply-add for the DSP32C DAU model:
//   result = round_nearest_even( (neg_y ? -y : y) + (neg_p ? -(a * x) : a * x) )
// with IEEE-754 binary64 operands and result, as the one rounding clang
// gives MAME's `yval + a * xval` on this host.  Operands are never denormal,
// infinite or NaN here (the DAU flushes below 5.88e-39 and saturates above
// 3.40e38), so an exponent field of zero means zero and nothing else is
// special-cased.  An exact zero sum takes IEEE's sign rules: both terms zero
// with equal signs keep that sign, everything else gives +0.
//
// Four clocks: multiply, align and add, leading-one count, normalise and round.  The product
// is exact (106 bits) and anchored in a 163-bit frame; only the addend is
// shifted, right from a reference position three bits above the product,
// with a sticky bit for whatever falls below the frame.  An addend more
// than 108 bits above the product's LSB sits at the reference position and
// the product collapses into the sticky bit, which is exact for rounding
// since it is then entirely below the guard bit.  One rounding.
module dsp32c_fma (
  input  logic        clk_i,
  input  logic        start_i,
  input  logic [63:0] a_i,
  input  logic [63:0] x_i,
  input  logic [63:0] y_i,
  input  logic        neg_p_i,
  input  logic        neg_y_i,
  output logic        done_o,       // pulse, result_o valid
  output logic [63:0] result_o
);
  localparam int W = 163;           // frame width

  // stage 1 ------------------------------------------------------------------
  logic        s1_v;
  logic        sp_q, sy_q, pz_q, yz_q;
  logic signed [12:0] ep_q, ey_q;   // unbiased exponents
  logic [105:0] mp_q;
  logic [52:0]  my_q;

  wire az = a_i[62:0] == 63'd0 || a_i[62:52] == 11'd0;
  wire xz = x_i[62:0] == 63'd0 || x_i[62:52] == 11'd0;
  wire yz = y_i[62:0] == 63'd0 || y_i[62:52] == 11'd0;
  wire [52:0] ma = {1'b1, a_i[51:0]};
  wire [52:0] mx = {1'b1, x_i[51:0]};

  always_ff @(posedge clk_i) begin
    s1_v <= start_i;
    if (start_i) begin
      sp_q <= a_i[63] ^ x_i[63] ^ neg_p_i;
      sy_q <= y_i[63] ^ neg_y_i;
      pz_q <= az || xz;
      yz_q <= yz;
      mp_q <= ma * mx;
      my_q <= {1'b1, y_i[51:0]};
      // product value = mp * 2^(ep - 104), addend = my * 2^(ey - 52)
      ep_q <= $signed({2'b0, a_i[62:52]}) + $signed({2'b0, x_i[62:52]}) - 13'sd2046;
      ey_q <= $signed({2'b0, y_i[62:52]}) - 13'sd1023;
    end
  end

  // stage 2: align the addend to the anchored product and add ----------------
  // frame: bit 0 sticky, product at [106:1], addend reference LSB at bit 109
  logic         s2_v;
  logic         sum_neg_q, zero_q, zero_sign_q;
  logic [W-1:0] mag_q;
  logic signed [13:0] scale_q;      // value = mag * 2^(scale) (with the sticky LSB below)

  always_ff @(posedge clk_i) begin
    s2_v <= s1_v;
    if (s1_v) begin
      logic signed [13:0] lp, ly, d, L;
      logic signed [14:0] s;        // right shift of the addend from its reference position
      logic         clamp, sticky_y;
      logic [6:0]   k;
      logic [52:0]  lost_mask;
      logic [W-1:0] fp, fy;
      logic signed [W:0] sum;
      lp = 14'(ep_q) - 14'sd104;    // scale of the product's LSB
      ly = 14'(ey_q) - 14'sd52;     // scale of the addend's LSB
      d = ly - lp;
      clamp = (d > 14'sd108);
      s = clamp ? 15'sd0 : 15'(14'sd108 - d);
      fp = '0;
      if (!pz_q) begin
        if (clamp) fp[0] = 1'b1;    // entirely below the guard bit: sticky only
        else fp[106:1] = mp_q;
      end
      fy = '0; sticky_y = 1'b0;
      if (!yz_q) begin
        if (s >= 15'sd162) sticky_y = 1'b1;              // all of it below the frame
        else begin
          fy = ({{(W-53){1'b0}}, my_q} << 109) >> s;
          k = (s > 15'sd109) ? 7'(s - 15'sd109) : 7'd0;  // addend bits lost below bit 0
          lost_mask = (k >= 7'd53) ? '1 : ((53'd1 << k) - 53'd1);
          sticky_y = (my_q & lost_mask) != 53'd0;
        end
        fy[0] = fy[0] | sticky_y;
      end
      L = clamp ? (ly - 14'sd108) : lp;                  // value of frame bit 1
      if (sp_q == sy_q) begin
        sum = $signed({1'b0, fp}) + $signed({1'b0, fy});
        sum_neg_q <= sp_q;
      end else begin
        sum = $signed({1'b0, fp}) - $signed({1'b0, fy});
        sum_neg_q <= sum[W] ? sy_q : sp_q;
        if (sum[W]) sum = -sum;
      end
      mag_q       <= sum[W-1:0];
      scale_q     <= L - 14'sd1;                               // bit 1 is 2^L
      zero_q      <= (sum == 0);
      zero_sign_q <= (pz_q && yz_q) ? (sp_q && sy_q) : 1'b0;  // IEEE exact-zero sign
    end
  end

  // stage 3: leading-one position ---------------------------------------------
  // (the count, the normalising shift and the rounding in one cycle were a
  // 33 ns path; the count gets its own clock)
  logic         s3_v;
  logic         sum_neg3_q, zero3_q, zero_sign3_q;
  logic [W-1:0] mag3_q;
  logic signed [13:0] scale3_q;
  logic [7:0]   msb_q;
  always_ff @(posedge clk_i) begin
    s3_v <= s2_v;
    if (s2_v) begin
      int msb;
      msb = 0;
      for (int i = W - 1; i >= 0; i--) if (mag_q[i]) begin msb = i; break; end
      msb_q <= 8'(msb);
      mag3_q <= mag_q; scale3_q <= scale_q; sum_neg3_q <= sum_neg_q;
      zero3_q <= zero_q || (mag_q == 0); zero_sign3_q <= zero_sign_q;
    end
  end

  // stage 4: normalise and round --------------------------------------------
  always_ff @(posedge clk_i) begin
    done_o <= s3_v;
    if (s3_v) begin
      if (zero3_q) result_o <= {zero_sign3_q, 63'd0};
      else begin
        logic [W-1:0] norm;
        logic [52:0]  kept;
        logic         guard, sticky, roundup;
        logic [53:0]  r;
        logic signed [13:0] e;
        norm = mag3_q << (8'(W - 1) - msb_q);        // MSB at W-1
        kept = norm[W-1 -: 53];
        guard = norm[W-54];
        sticky = norm[W-55:0] != 0;
        roundup = guard && (sticky || kept[0]);
        r = {1'b0, kept} + (roundup ? 54'd1 : 54'd0);
        e = scale3_q + 14'(msb_q) + 14'sd1023;       // biased exponent of 2^msb
        if (r[53]) begin e = e + 14'sd1; r = r >> 1; end
        result_o <= {sum_neg3_q, e[10:0], r[51:0]};
      end
    end
  end
endmodule

`default_nettype wire
