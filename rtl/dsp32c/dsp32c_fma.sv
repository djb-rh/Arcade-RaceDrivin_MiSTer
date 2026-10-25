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
// Three clocks: multiply, align and add, normalise and round.  The product
// is exact (106 bits) and the addend is aligned into a 170-bit field with a
// sticky bit, so there is exactly one rounding.
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
  localparam int W = 170;           // working width

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

  // stage 2: align into a common scale and add ------------------------------
  logic         s2_v;
  logic         sum_neg_q, zero_q, zero_sign_q;
  logic [W-1:0] mag_q;
  logic signed [13:0] scale_q;      // value = mag * 2^(scale) (with the sticky LSB below)

  always_ff @(posedge clk_i) begin
    s2_v <= s1_v;
    if (s1_v) begin
      logic signed [13:0] lp, ly, mmax, L;
      logic signed [13:0] shp, shy;
      logic [W-1:0] fp, fy, stk_p, stk_y;
      logic         sp_stk, sy_stk;
      logic signed [W:0] sum;
      // LSB scales of the two operands and their MSB positions
      lp = 14'(ep_q) - 14'sd104;
      ly = 14'(ey_q) - 14'sd52;
      mmax = (lp + 14'sd105 > ly + 14'sd52) ? lp + 14'sd105 : ly + 14'sd52;
      L = (lp < ly) ? lp : ly;
      if (L < mmax - 14'(W - 4)) L = mmax - 14'(W - 4);
      shp = lp - L;  shy = ly - L;
      // place each operand; bit 0 of the field is the sticky position, the
      // operand proper starts at bit 1
      fp = 170'd0; fy = 170'd0; sp_stk = 1'b0; sy_stk = 1'b0;
      if (!pz_q) begin
        if (shp >= 0) fp = {64'd0, mp_q} << (shp + 1);
        else begin
          fp = {64'd0, mp_q} >> (-shp - 1);
          stk_p = ({64'd0, mp_q} << (W - (-shp - 1)));   // bits shifted out
          sp_stk = (-shp - 1) >= W ? (mp_q != 0) : (stk_p != 0);
          if ((-shp - 1) >= W) fp = 170'd0;
        end
        fp[0] = sp_stk;
      end
      if (!yz_q) begin
        if (shy >= 0) fy = {117'd0, my_q} << (shy + 1);
        else begin
          fy = {117'd0, my_q} >> (-shy - 1);
          stk_y = ({117'd0, my_q} << (W - (-shy - 1)));
          sy_stk = (-shy - 1) >= W ? (my_q != 0) : (stk_y != 0);
          if ((-shy - 1) >= W) fy = 170'd0;
        end
        fy[0] = sy_stk;
      end
      sum = (sp_q ? -$signed({1'b0, fp}) : $signed({1'b0, fp})) +
            (sy_q ? -$signed({1'b0, fy}) : $signed({1'b0, fy}));
      sum_neg_q <= sum[W];
      mag_q     <= sum[W] ? (W)'(-sum) : sum[W-1:0];
      scale_q   <= L - 14'sd1;                               // bit 1 is 2^L
      zero_q    <= (sum == 0);
      zero_sign_q <= (pz_q && yz_q) ? (sp_q && sy_q) : 1'b0;  // IEEE exact-zero sign
    end
  end

  // stage 3: normalise and round --------------------------------------------
  always_ff @(posedge clk_i) begin
    done_o <= s2_v;
    if (s2_v) begin
      if (zero_q || mag_q == 0) result_o <= {zero_sign_q, 63'd0};
      else begin
        int msb;
        logic [W-1:0] norm;
        logic [52:0]  kept;
        logic         guard, sticky, roundup;
        logic [53:0]  r;
        logic signed [13:0] e;
        msb = 0;
        for (int i = W - 1; i >= 0; i--) if (mag_q[i]) begin msb = i; break; end
        norm = mag_q << (W - 1 - msb);               // MSB at W-1
        kept = norm[W-1 -: 53];
        guard = norm[W-54];
        sticky = norm[W-55:0] != 0;
        roundup = guard && (sticky || kept[0]);
        r = {1'b0, kept} + (roundup ? 54'd1 : 54'd0);
        e = scale_q + 14'(msb) + 14'sd1023;          // biased exponent of 2^msb
        if (r[53]) begin e = e + 14'sd1; r = r >> 1; end
        result_o <= {sum_neg_q, e[10:0], r[51:0]};
      end
    end
  end
endmodule

`default_nettype wire
