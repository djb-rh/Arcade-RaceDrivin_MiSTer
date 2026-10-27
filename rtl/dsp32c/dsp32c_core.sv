`default_nettype none

// AT&T DSP32C, the DSK board's physics processor, written to behave exactly
// like MAME's model of it (src/devices/cpu/dsp32, BSD-3-Clause, Aaron Giles)
// so the two can be compared instruction by instruction (sim/tb_dsp32.sv).
// MAME is behavioural, not cycle-exact: it executes one instruction at a
// time with a few pipeline effects modelled explicitly, and so does this
// core, in a multi-clock sequence per instruction:
//
//   - CAU: 22 registers of 24 bits (r0 = 0, r22 = -1, r23 = +1 constants, pc
//     is r15, dauc r26), flags N Z C V kept in MAME's 32-bit nzcflags/vflags
//     encodings, loads/stores with post-increment pointers, branches with one
//     delay slot whose target is computed after the slot has run.
//   - DAU: four accumulators held as IEEE doubles, results from a fused
//     multiply-add (dsp32c_fma) then MAME's flush-to-zero below 5.88e-39 and
//     saturation above 3.40e38; the DSP32C 32-bit float format only exists
//     in memory (dsp32c_pkg conversions).  MAME's modelled latencies are
//     reproduced: a DAU memory write lands four instructions later, an
//     accumulator used as a multiplier reads its value from before the last
//     two instructions' writes, DAU flags tested by branches come from
//     before the last three.
//   - PIO: the parallel host port (PAR/PARE, PDR/PDR2, EMR, ESR, PCR, PIR)
//     with DMA autoincrement, PCR bit 0 as run/reset, PIF/PDF pins.
//
// The host port is served between instructions, as MAME's scheduler does.
// step_hold_i parks the core between instructions for the lock-step test.
module dsp32c_core
  import dsp32c_pkg::*;
(
  input  logic        clk_i,
  input  logic        rst_i,          // power-up reset
  input  logic        reset_n_i,      // DSPRESTN from the DSK latch: low holds, rising edge resets
  input  logic        halt_n_i,       // DSPZN: low stops instruction execution
  input  logic        step_hold_i,    // test: pause between instructions

  // memory (dsp32c_ram or the DSK board's RAMs)
  output logic        mem_req_o,
  output logic        mem_we_o,
  output logic [23:0] mem_addr_o,
  output logic [2:0]  mem_size_o,
  output logic [31:0] mem_wdata_o,
  input  logic [31:0] mem_rdata_i,
  input  logic        mem_ack_i,

  // host parallel port: request held until ack
  input  logic        host_req_i,
  input  logic        host_we_i,
  input  logic [3:0]  host_reg_i,
  input  logic [15:0] host_wdata_i,
  output logic [15:0] host_rdata_o,
  output logic        host_ack_o,
  output logic        pif_o,
  output logic        pdf_o,

  // observation (lock-step test and board debug)
  output logic        boundary_o,     // pulse: about to execute boundary_op_o at boundary_pc_o
  output logic [23:0] boundary_pc_o,
  output logic [31:0] boundary_op_o,
  output logic        running_o
);
  // ---- architectural state -------------------------------------------------
  logic [31:0] r [0:31];
  logic [31:0] nzc_q, vfl_q;          // MAME m_nzcflags / m_vflags
  logic [63:0] a [0:3];
  logic [63:0] nz_q;                  // MAME m_NZflags (a double)
  logic [1:0]  vu_q;                  // bit0 U, bit1 V
  logic [15:0] par_q, pdr_q, pdr2_q, pir_q, pcr_q, emr_q, esr_q, pcw_q;
  logic [7:0]  pare_q;
  logic [31:0] ibuf_q, obuf_q, piop_q;
  logic [3:0]  lastp_q;
  logic [1:0]  lastpins_q;
  logic [47:0] icount_q;              // instructions begun (MAME rdlog.instructions)

  localparam logic [63:0] DBL_FLUSH = 64'h37ffffff5fc5cfec;   // 5.87747e-39
  localparam logic [63:0] DBL_SAT   = 64'h47effffdbd19d02c;   // 3.40282e38
  localparam logic [63:0] DBL_HALF  = 64'h3fe0000000000000;
  localparam logic [63:0] DBL_ONE   = 64'h3ff0000000000000;

  // accumulator history (MAME abuf): old value, register, old flags, time
  logic [63:0] ab_val  [0:3];
  logic [1:0]  ab_reg  [0:3];
  logic        ab_n    [0:3], ab_z [0:3];
  logic [1:0]  ab_vu   [0:3];
  logic [2:0]  ab_age  [0:3];         // instructions since the push, saturating at 4
  logic        ab_valid[0:3];
  logic [1:0]  ab_idx_q;
  // deferred memory writes (MAME mbuf)
  logic [23:0] mb_addr [0:3];
  logic [31:0] mb_data [0:3];
  logic        mb_long [0:3], mb_valid [0:3];
  logic [1:0]  mb_idx_q;

  // ---- flag helpers --------------------------------------------------------
  wire n_f = nzc_q[23];
  wire z_f = nzc_q[23:0] == 24'd0;
  wire c_f = nzc_q[24];
  wire v_f = vfl_q[23];

  function automatic logic [63:0] amult(input logic [1:0] aidx);
    logic [63:0] val;
    logic [1:0] bi;
    val = a[aidx];
    bi = ab_idx_q - 2'd1;
    for (int k = 0; k < 4; k++) begin
      if (!ab_valid[bi] || ab_age[bi] > 3'd2) break;
      if (ab_reg[bi] == aidx) val = ab_val[bi];
      bi = bi - 2'd1;
    end
    return val;
  endfunction

  function automatic logic [3:0] deferred_flags();  // {V, U, N, Z}
    logic [3:0] f;
    logic [1:0] bi;
    f = {vu_q[1], vu_q[0], dbl_is_neg(nz_q), dbl_is_zero(nz_q)};
    bi = ab_idx_q - 2'd1;
    for (int k = 0; k < 4; k++) begin
      if (!ab_valid[bi] || ab_age[bi] > 3'd3) break;
      f = {ab_vu[bi][1], ab_vu[bi][0], ab_n[bi], ab_z[bi]};
      bi = bi - 2'd1;
    end
    return f;
  endfunction

  // MAME condition() for CAU-conditional ops and goto 1..0x19, with the
  // goto handlers' own N^V tests for codes 10/11.
  function automatic logic condition(input logic [4:0] c, input logic is_goto, input logic [3:0] df);
    case (c)
      5'd0: return 1'b0;      5'd1: return 1'b1;
      5'd2: return !n_f;      5'd3: return n_f;
      5'd4: return !z_f;      5'd5: return z_f;
      5'd6: return !v_f;      5'd7: return v_f;
      5'd8: return !c_f;      5'd9: return c_f;
      5'd10: return is_goto ? !(n_f ^ v_f) : !(n_f ^ c_f);
      5'd11: return is_goto ?  (n_f ^ v_f) :  (n_f ^ c_f);
      5'd12: return !(z_f | (n_f ^ v_f));
      5'd13: return  (z_f | (n_f ^ v_f));
      5'd14: return !(c_f | z_f);
      5'd15: return  (c_f | z_f);
      5'd16: return !df[2];   5'd17: return df[2];          // U
      5'd18: return !df[1];   5'd19: return df[1];          // N  (NZ < 0)
      5'd20: return !df[0];   5'd21: return df[0];          // Z
      5'd22: return !df[3];   5'd23: return df[3];          // V
      5'd24: return !(df[1] | df[0]);  5'd25: return (df[1] | df[0]);   // NZ <= 0
      default: return 1'b0;
    endcase
  endfunction

  // ---- sequencer -----------------------------------------------------------
  typedef enum logic [5:0] {
    S_IDLE, S_HOST, S_HOST_MEM, S_DEFER, S_DEFER_W, S_FETCH, S_FETCH_W, S_EXEC,
    S_CAU_MEM, S_CAU_W,
    S_DX, S_DX_W, S_DY, S_DY_W, S_DCOMP, S_DFMA_W, S_DROUND_W, S_DINT, S_DZ, S_DFIN, S_DSET, S_DONE
  } state_t;
  state_t st_q;

  logic [31:0] op_q;
  logic [23:0] pc_fetch_q;
  decode_t     dec;
  assign dec = decode(op_q);

  // pending branch: target evaluated after the delay slot
  logic        br_pend_q;
  logic [1:0]  br_slots_q;
  logic        br_abs_q;              // call24: target = imm24 only
  logic [4:0]  br_reg_q;
  logic [23:0] br_imm_q;

  // DAU working registers
  logic [63:0] dx_q, dy_q, dres_q, dz_q;
  logic        dz_is_res_q;           // Z gets res (else y)
  logic [31:0] dword_q;               // raw 32-bit operand for float24/seed/int24
  logic        d_mult_x, d_mult_y;
  logic        d_cond_skip_q;         // d5 ifXX: condition false, no operand read
  logic [3:0]  lastp_x_q;
  logic [31:0] cau_addr_q, cau_val_q;
  logic [2:0]  cau_size_q;
  logic [4:0]  cau_p_q, cau_i_q;

  // Three shared read ports on r, indexed by state: the sequencer's reads
  // through ten separately indexed 32:1 muxes were most of the core's logic.
  //   A: the CAU destination / pointer register   B: the second source or
  //   the DAU post-increment register r16-r23     C: the CAU third operand
  logic [4:0]  rdA_idx, rdB_idx, rdC_idx;
  logic [31:0] rA, rB, rC;
  logic [3:0]  dy_p, dz_p;               // the Y and Z pointer fields after p=15 inheritance
  assign dy_p = (dec.cls != OP_D5 && yp == 4'd15) ? lastp_q : yp;
  assign dz_p = (zp == 4'd15) ? lastp_q : zp;
  always_comb begin
    rdA_idx = dr_lo; rdB_idx = op_q[9:5]; rdC_idx = op_q[4:0];
    case (st_q)
      S_EXEC: rdA_idx = (dec.cls == OP_DEC_GOTO) ? dr_hi : dr_lo;
      S_DX:   begin rdA_idx = {1'b0, xp};   rdB_idx = {2'b10, xi}; end
      S_DY:   begin rdA_idx = {1'b0, dy_p}; rdB_idx = {2'b10, yi}; end
      S_DFIN: begin rdA_idx = {1'b0, dz_p}; rdB_idx = {2'b10, zi}; end
      S_DONE: rdA_idx = br_reg_q;
      default: ;
    endcase
  end
  assign rA = r[rdA_idx];
  assign rB = r[rdB_idx];
  assign rC = r[rdC_idx];

  // One instance each of the DSP<->double conversions and of the
  // accumulator-history lookup, their inputs chosen by state (seven copies
  // of dsp_to_double alone were ~700 ALUTs).
  logic [1:0]  am_idx;
  logic [63:0] am_out;
  logic [31:0] d2d_in, i2d_in, res32_c;
  logic [63:0] d2d_out, i2d_out, dtd_in, zval_c, rounded_c;
  logic [31:0] dtd_out, res32_q;
  logic [63:0] fres_q, rounded_q;      // int / int24: the FMA result, then its floor/ceil
  logic signed [31:0] iv_c;
  wire   is_word_c = (dec.cls == OP_D5 && dec.sub == 4'd3);
  assign zval_c    = dz_is_res_q ? dres_q : dy_q;
  // int / int24 result over three states (S_DROUND_W, S_DINT, S_DZ): the
  // floor/ceil of val +- 0.5, the saturated and clamped int32, then the
  // DSP float of it; in one cycle the chain was a 38 ns path
  assign rounded_c = dbl_floor(fres_q, r[26][4]);
  assign iv_c      = dbl_to_int32(rounded_q);
  always_comb begin
    logic signed [31:0] iv;
    iv = iv_c;
    if (dec.sub == 4'd3) res32_c = {16'd0, iv[15:0]};           // (int16_t) of a saturated int32
    else begin
      // std::clamp<double>(val, -0x800000, 0x7fffff) on an integral value
      if (iv > 32'sh007fffff) iv = 32'sh007fffff;
      if (iv < -32'sh00800000) iv = -32'sh00800000;
      res32_c = iv;
    end
  end
  always_comb begin
    am_idx = dec.am[1:0];
    d2d_in = mem_rdata_i;                                        // S_DX_W, S_DY_W
    case (st_q)
      S_DX:     am_idx = xi[1:0];
      S_DY:     am_idx = yi[1:0];
      S_DCOMP:  d2d_in = dword_q ^ 32'h7fffffff;                 // seed
      S_DZ:     d2d_in = (dec.sub == 4'd3) ? (res32_q << 16) : (res32_q << 8);
      S_DFIN:   d2d_in = is_word_c ? (dword_q << 16) : dword_q;
      default: ;
    endcase
  end
  assign am_out  = amult(am_idx);
  assign d2d_out = dsp_to_double(d2d_in);
  assign i2d_in  = (dec.sub == 4'd2) ? {{16{dword_q[15]}}, dword_q[15:0]} : {{8{dword_q[23]}}, dword_q[23:0]};
  assign i2d_out = int_to_double(i2d_in);
  assign dtd_in  = (st_q == S_DY) ? a[yi[1:0]] : zval_c;
  assign dtd_out = double_to_dsp(dtd_in);

  dsp32c_fma u_fma (
    .clk_i(clk_i), .start_i(fma_start), .a_i(fma_a), .x_i(fma_x), .y_i(fma_y),
    .neg_p_i(fma_negp), .neg_y_i(fma_negy), .done_o(fma_done), .result_o(fma_res)
  );
  logic        fma_start, fma_done, fma_negp, fma_negy;
  logic [63:0] fma_a, fma_x, fma_y, fma_res;

  // host PIO decode (MAME s_regmap)
  typedef enum logic [3:0] { P_PAR, P_PDR, P_EMR, P_ESR, P_PCR, P_PIR, P_PARE, P_PDR2, P_RES } pioreg_t;
  function automatic void regmap(input logic [1:0] mode, input logic [3:0] reg_i,
                                 output pioreg_t pr, output logic [15:0] mask);
    // mask 0x0000 full, 0xff00 low byte (LOWER), 0x00ff high byte (UPPER)
    pr = P_RES; mask = 16'h0000;
    case (mode)
      2'd0: case (reg_i)   // DSP32 compatible
        4'd0: begin pr = P_PAR; mask = 16'hff00; end  4'd1: begin pr = P_PAR; mask = 16'h00ff; end
        4'd2: begin pr = P_PDR; mask = 16'hff00; end  4'd3: begin pr = P_PDR; mask = 16'h00ff; end
        4'd4: begin pr = P_EMR; mask = 16'hff00; end  4'd5: begin pr = P_EMR; mask = 16'h00ff; end
        4'd6: begin pr = P_ESR; mask = 16'hff00; end  4'd7: begin pr = P_PCR; mask = 16'hff00; end
        default: begin pr = P_PIR; mask = 16'h00ff; end
      endcase
      2'd1: case (reg_i)   // DSP32C 8-bit
        4'd0: begin pr = P_PAR; mask = 16'hff00; end  4'd1: begin pr = P_PAR; mask = 16'h00ff; end
        4'd2: begin pr = P_PDR; mask = 16'hff00; end  4'd3: begin pr = P_PDR; mask = 16'h00ff; end
        4'd4: begin pr = P_EMR; mask = 16'hff00; end  4'd5: begin pr = P_EMR; mask = 16'h00ff; end
        4'd6: begin pr = P_ESR; mask = 16'hff00; end  4'd7: begin pr = P_PCR; mask = 16'hff00; end
        4'd8: begin pr = P_PIR; mask = 16'hff00; end  4'd9: begin pr = P_PIR; mask = 16'h00ff; end
        4'd10: begin pr = P_PCR; mask = 16'h00ff; end 4'd11: begin pr = P_PARE; mask = 16'hff00; end
        4'd12: begin pr = P_PDR2; mask = 16'hff00; end 4'd13: begin pr = P_PDR2; mask = 16'h00ff; end
        default: pr = P_RES;
      endcase
      2'd3: case (reg_i)   // DSP32C 16-bit
        4'd0: pr = P_PAR;  4'd2: pr = P_PDR;  4'd4: pr = P_EMR;
        4'd6: begin pr = P_ESR; mask = 16'hff00; end
        4'd7: pr = P_PCR;  4'd8: pr = P_PIR;
        4'd11: begin pr = P_PARE; mask = 16'hff00; end
        4'd12: pr = P_PDR2;
        default: pr = P_RES;
      endcase
      default: pr = P_RES;
    endcase
  endfunction

  // host access bookkeeping
  logic        host_done_q;           // ack given, waiting for req to drop
  logic        host_dma_load_q, host_dma_store_q, host_dma_inc_q, host_dma_pins_q;
  logic [15:0] host_result_q;
  logic        host_is_read_q;

  logic        reset_n_q;
  wire         held = !reset_n_i;     // DSPRESTN low
  wire         dev_reset_edge = reset_n_i && !reset_n_q;
  wire         can_run = !held && halt_n_i && pcr_q[0] && !step_hold_i;
  assign running_o = pcr_q[0] && !held;

  // post-increment amount for DAU pointer field i (0-7): r[i+16], x4 for i>=6
  // (rv is r[i], read through port B / C)
  function automatic logic [31:0] dau_inc(input logic [31:0] rv, input logic [2:0] i, input logic [2:0] size);
    logic [31:0] v;
    v = rv;                            // r16..r23
    if (i >= 3'd6) v = (size == 3'd2) ? (v << 1) : (v << 2);
    return v;
  endfunction
  function automatic logic [31:0] cau_inc(input logic [31:0] rv, input logic [4:0] i, input logic [2:0] size);
    logic [31:0] v;
    v = rv;
    if (i == 5'd22 || i == 5'd23) begin
      if (size == 3'd2) v = v << 1;
      else if (size == 3'd4) v = v << 2;
    end
    return v;
  endfunction

  // DAU flush/saturate (dau_set_val_flags)
  function automatic logic [63:0] dau_sat(input logic [63:0] v, output logic [1:0] vu);
    logic [62:0] mag;
    mag = v[62:0];
    vu = 2'b00;
    if (mag < DBL_FLUSH[62:0]) begin
      if (mag != 63'd0) vu = 2'b01;
      return 64'd0;
    end else if (mag > DBL_SAT[62:0]) begin
      vu = 2'b10;
      return {v[63], DBL_SAT[62:0]};
    end
    return v;
  endfunction

  // ---- the machine -------------------------------------------------------------
  // pointer/word fields of the current DAU instruction
  wire [3:0] xp = op_q[20:17]; wire [2:0] xi = op_q[16:14];
  wire [3:0] yp = op_q[13:10]; wire [2:0] yi = op_q[9:7];
  wire [3:0] zp = op_q[6:3];   wire [2:0] zi = op_q[2:0];
  wire [1:0] dacc = op_q[22:21];
  wire [15:0] imm16 = op_q[15:0];
  wire [31:0] imm16_sx24 = {8'd0, {8{op_q[15]}}, op_q[15:0]};      // EXTEND16_TO_24
  wire [23:0] imm24 = {op_q[28:21], op_q[15:0]};
  wire [4:0] dr_lo = op_q[20:16];
  wire [4:0] dr_hi = op_q[25:21];

  // One general write port for r: every register write in the sequencer goes
  // through rf_*, applied at the end of the clock (at most one general
  // register is written per state; r15 has its own increment and branch
  // writes).  Direct r[idx] <= writes from a dozen places gave every
  // register a wide multi-source mux: a third of the core's logic.
  logic        rf_we, rf_chk;
  logic [4:0]  rf_idx;
  logic [31:0] rf_val;
  task automatic set_r(input logic [4:0] idx, input logic [31:0] val);
    rf_we = 1'b1; rf_chk = 1'b1; rf_idx = idx; rf_val = val;
  endtask
  task automatic set_r_raw(input logic [4:0] idx, input logic [31:0] val);
    rf_we = 1'b1; rf_chk = 1'b0; rf_idx = idx; rf_val = val;
  endtask

  task automatic ab_push(input logic [1:0] aidx);
    ab_val[ab_idx_q]   <= a[aidx];
    ab_reg[ab_idx_q]   <= aidx;
    ab_n[ab_idx_q]     <= dbl_is_neg(nz_q);
    ab_z[ab_idx_q]     <= dbl_is_zero(nz_q);
    ab_vu[ab_idx_q]    <= vu_q;
    ab_age[ab_idx_q]   <= 3'd0;
    ab_valid[ab_idx_q] <= 1'b1;
    ab_idx_q <= ab_idx_q + 2'd1;
  endtask

  task automatic device_reset();
    r[15] <= 32'd0;
    pcw_q <= pcw_q & 16'h03ff;
    pcr_q <= 16'h0001;
    esr_q <= 16'h0000;
    emr_q <= 16'hffff;
    pif_o <= 1'b0; pdf_o <= 1'b0;
    r[0] <= 32'd0; r[16] <= 32'd0; r[22] <= 32'hffffffff; r[23] <= 32'd1;
    for (int k = 0; k < 4; k++) begin ab_valid[k] <= 1'b0; mb_valid[k] <= 1'b0; end
  endtask

  task automatic update_pins(input logic [15:0] pcr_new);
    if (pcr_new[2]) begin
      if ({pcr_new[5], pcr_new[6]} != lastpins_q) begin
        lastpins_q <= {pcr_new[5], pcr_new[6]};
        pdf_o <= pcr_new[5]; pif_o <= pcr_new[6];
      end
    end
  endtask

  // CAU 16-bit flag macros
  task automatic set_nzcv16(input logic [31:0] av, input logic [31:0] bv, input logic [31:0] res);
    nzc_q <= res << 8;
    vfl_q <= (av ^ bv ^ res ^ {res[31], res[31:1]}) << 8;   // C: (r >> 1) on a signed int
  endtask
  task automatic set_nz00_16(input logic [31:0] res);
    nzc_q <= (res << 8) & 32'h00ffffff; vfl_q <= 32'd0;
  endtask
  task automatic set_nzcv24(input logic [31:0] av, input logic [31:0] bv, input logic [31:0] res);
    nzc_q <= res; vfl_q <= av ^ bv ^ res ^ {res[31], res[31:1]};
  endtask
  task automatic set_nz00_24(input logic [31:0] res);
    nzc_q <= res & 32'h00ffffff; vfl_q <= 32'd0;
  endtask

  // deferred write of the DAU Z operand
  task automatic defer_write(input logic [23:0] addr, input logic [31:0] data, input logic is_long);
    mb_addr[mb_idx_q] <= addr; mb_data[mb_idx_q] <= data;
    mb_long[mb_idx_q] <= is_long; mb_valid[mb_idx_q] <= 1'b1;
  endtask

  logic [15:0] pcr_tmp;
  logic [3:0]  dfl;
  logic        br_taken;
  logic [31:0] s1v, s2v, drv, alu_res, pcnext;
  logic [1:0]  satvu;
  logic [63:0] satres, zval;
  logic [31:0] res32;
  logic [63:0] rnd_q;

  always_ff @(posedge clk_i) begin
    boundary_o <= 1'b0;
    mem_req_o  <= 1'b0;
    fma_start  <= 1'b0;
    host_ack_o <= 1'b0;
    reset_n_q  <= reset_n_i;
    rf_we = 1'b0; rf_chk = 1'b0; rf_idx = 5'd0; rf_val = 32'd0;
    if (rst_i) begin
      for (int k = 0; k < 32; k++) r[k] <= 32'd0;
      for (int k = 0; k < 4; k++) begin a[k] <= 64'd0; ab_valid[k] <= 1'b0; mb_valid[k] <= 1'b0; end
      nzc_q <= 0; vfl_q <= 0; nz_q <= 0; vu_q <= 0;
      par_q <= 0; pdr_q <= 0; pdr2_q <= 0; pir_q <= 0; pcr_q <= 0; emr_q <= 0; esr_q <= 0; pcw_q <= 0; pare_q <= 0;
      ibuf_q <= 0; obuf_q <= 0; piop_q <= 0; lastp_q <= 0; lastpins_q <= 0; icount_q <= 0;
      ab_idx_q <= 0; mb_idx_q <= 0; br_pend_q <= 0; br_slots_q <= 0;
      host_done_q <= 0; st_q <= S_IDLE; pif_o <= 0; pdf_o <= 0;
      device_reset();
    end else begin
      if (dev_reset_edge) device_reset();
      if (!host_req_i) host_done_q <= 1'b0;
      case (st_q)
        // ---------------------------------------------------------------- idle
        S_IDLE: begin
          if (host_req_i && !host_done_q) begin
            // ---- host PIO access (MAME pio_w / pio_r) ----
            pioreg_t pr; logic [15:0] mask, data, result; logic shift8;
            regmap({pcr_q[9], pcr_q[1]}, host_reg_i, pr, mask);
            host_dma_load_q <= 1'b0; host_dma_store_q <= 1'b0; host_dma_inc_q <= 1'b0; host_dma_pins_q <= 1'b0;
            host_is_read_q <= !host_we_i;
            if (host_we_i) begin
              data = host_wdata_i;
              if (mask == 16'h00ff) data = data << 8;
              data = data & ~mask;
              case (pr)
                P_PAR:  begin par_q <= (par_q & mask) | data; if (!(|(mask & 16'hff00))) host_dma_load_q <= 1'b1; end
                P_PARE: pare_q <= 8'((16'(pare_q) & mask) | data);
                P_PDR:  begin pdr_q <= (pdr_q & mask) | data;
                              if (!(|(mask & 16'hff00))) begin host_dma_store_q <= 1'b1; host_dma_inc_q <= 1'b1; host_dma_pins_q <= 1'b1; end end
                P_PDR2: pdr2_q <= (pdr2_q & mask) | data;
                P_EMR:  emr_q <= (emr_q & mask) | data;
                P_ESR:  esr_q <= (esr_q & mask) | data;
                P_PCR:  begin
                  logic [15:0] m2, newv;
                  m2 = mask | 16'h0060;
                  newv = (pcr_q & m2) | (data & ~m2);
                  pcr_q <= newv;
                  if (!pcr_q[0] && newv[0]) device_reset();    // update_pcr: reset on 0->1
                end
                P_PIR:  begin pir_q <= (pir_q & mask) | data;
                              if (!(|(mask & 16'hff00))) begin pcr_q <= pcr_q | 16'h0040; update_pins(pcr_q | 16'h0040); end end
                default: ;
              endcase
              host_result_q <= 16'h0000;
            end else begin
              shift8 = (mask == 16'h00ff);
              if (shift8) mask = 16'hff00;
              result = 16'hffff;
              case (pr)
                P_PAR:  result = par_q | 16'h0001;
                P_PARE: result = 16'(pare_q);
                P_PDR:  begin result = pdr_q;
                              if (!shift8) host_dma_inc_q <= 1'b1;
                              if (!(|(mask & 16'hff00))) begin host_dma_load_q <= 1'b1; host_dma_pins_q <= 1'b1; end end
                P_PDR2: result = pdr2_q;
                P_EMR:  result = emr_q;
                P_ESR:  result = esr_q;
                P_PCR:  result = pcr_q;
                P_PIR:  begin if (!(|(mask & 16'hff00))) begin pcr_q <= pcr_q & ~16'h0040; update_pins(pcr_q & ~16'h0040); end
                              result = pir_q; end
                default: ;
              endcase
              host_result_q <= (shift8 ? (result >> 8) : result) & ~mask;
            end
            st_q <= S_HOST;
          end else if (can_run) begin
            // start an instruction: process the deferred write slot first
            icount_q <= icount_q + 48'd1;
            for (int k = 0; k < 4; k++) if (ab_age[k] != 3'd4) ab_age[k] <= ab_age[k] + 3'd1;
            mb_idx_q <= mb_idx_q + 2'd1;
            st_q <= S_DEFER;
          end
        end
        // host access side effects needing memory (dma_store, then dma_load)
        S_HOST: begin
          if (host_dma_store_q) begin
            host_dma_store_q <= 1'b0;
            if (pcr_q[3]) begin
              mem_req_o <= 1'b1; mem_we_o <= 1'b1;
              if (!pcr_q[8]) begin mem_addr_o <= {pare_q, par_q} & 24'hfffffe; mem_size_o <= 3'd2; mem_wdata_o <= {16'd0, pdr_q}; end
              else begin mem_addr_o <= {pare_q, par_q} & 24'hfffffc; mem_size_o <= 3'd4; mem_wdata_o <= {pdr_q, pdr2_q}; end
              pcr_q <= pcr_q & ~16'h0020;
              st_q <= S_HOST_MEM;
            end
          end else if (host_dma_inc_q) begin
            host_dma_inc_q <= 1'b0;
            if (pcr_q[4]) begin
              logic [16:0] sum;
              sum = {1'b0, par_q} + (pcr_q[8] ? 17'd4 : 17'd2);
              par_q <= sum[15:0];
              if (sum[16]) pare_q <= pare_q + 8'd1;
            end
          end else if (host_dma_load_q) begin
            host_dma_load_q <= 1'b0;
            if (pcr_q[3]) begin
              mem_req_o <= 1'b1; mem_we_o <= 1'b0;
              if (!pcr_q[8]) begin mem_addr_o <= {pare_q, par_q} & 24'hfffffe; mem_size_o <= 3'd2; end
              else begin mem_addr_o <= {pare_q, par_q} & 24'hfffffc; mem_size_o <= 3'd4; end
              st_q <= S_HOST_MEM;
            end
          end else if (host_dma_pins_q) begin
            host_dma_pins_q <= 1'b0;
            update_pins(pcr_q);
          end else begin
            host_rdata_o <= host_result_q;
            host_ack_o   <= 1'b1;
            host_done_q  <= 1'b1;
            st_q <= S_IDLE;
          end
        end
        S_HOST_MEM: if (mem_ack_i) begin
          if (!mem_we_o) begin
            if (mem_size_o == 3'd2) pdr_q <= mem_rdata_i[15:0];
            else begin pdr_q <= mem_rdata_i[31:16]; pdr2_q <= mem_rdata_i[15:0]; end
            pcr_q <= pcr_q | 16'h0020;
          end
          st_q <= S_HOST;
        end
        // ------------------------------------------------- deferred write, fetch
        S_DEFER: begin
          if (mb_valid[mb_idx_q]) begin
            mem_req_o <= 1'b1; mem_we_o <= 1'b1;
            mem_addr_o <= mb_addr[mb_idx_q]; mem_wdata_o <= mb_data[mb_idx_q];
            mem_size_o <= mb_long[mb_idx_q] ? 3'd4 : 3'd2;
            mb_valid[mb_idx_q] <= 1'b0;
            st_q <= S_DEFER_W;
          end else st_q <= S_FETCH;
        end
        S_DEFER_W: if (mem_ack_i) st_q <= S_FETCH;
        S_FETCH: begin
          mem_req_o <= 1'b1; mem_we_o <= 1'b0; mem_addr_o <= r[15][23:0]; mem_size_o <= 3'd4;
          pc_fetch_q <= r[15][23:0];
          st_q <= S_FETCH_W;
        end
        S_FETCH_W: if (mem_ack_i) begin
          op_q <= mem_rdata_i;
          boundary_o <= 1'b1; boundary_pc_o <= pc_fetch_q; boundary_op_o <= mem_rdata_i;
          d_cond_skip_q <= 1'b0;
          st_q <= S_EXEC;
        end
        // ------------------------------------------------------------- execute
        S_EXEC: begin
          st_q <= S_DONE;
          r[15] <= r[15] + 32'd4;                   // MAME: PC += 4 before the handler runs
          dfl = deferred_flags();
          case (dec.cls)
            OP_ILLEGAL: ;
            OP_NOP, OP_GOTO, OP_DEC_GOTO, OP_CALL, OP_GOTO24, OP_CALL24: begin
              br_taken = 1'b0;
              case (dec.cls)
                OP_NOP:   br_taken = (op_q != 32'd0);
                OP_GOTO:  br_taken = dec.pio_flag ? (dec.cond == 5'h04 ? !pcr_q[5] : dec.cond == 5'h05 ? pcr_q[5] :
                                                     dec.cond == 5'h06 ? !pcr_q[6] : pcr_q[6])
                                                  : condition(dec.cond, 1'b1, dfl);
                OP_DEC_GOTO: begin
                  logic [31:0] oldv;
                  oldv = rA;
                  // EXTEND16_TO_24(m_r[hr] - 1): sign-extend the 16-bit result
                  begin
                    logic [15:0] dec16; dec16 = oldv[15:0] - 16'd1;
                    set_r_raw(dr_hi, {8'd0, {8{dec16[15]}}, dec16});
                  end
                  br_taken = !oldv[15];                         // (int16)old >= 0
                end
                OP_CALL:   begin set_r(dr_hi, {8'd0, pc_fetch_q} + 32'd8); br_taken = 1'b1; end
                OP_GOTO24: br_taken = 1'b1;
                OP_CALL24: begin set_r(dr_lo, {8'd0, pc_fetch_q} + 32'd8); br_taken = 1'b1; end
                default: ;
              endcase
              if (br_taken) begin
                if (!br_pend_q) begin
                  // applied after this instruction's and the delay slot's retire
                  br_pend_q <= 1'b1; br_slots_q <= 2'd2;
                  br_reg_q <= dr_lo;
                  br_abs_q <= (dec.cls == OP_CALL24);
                  br_imm_q <= (dec.cls == OP_GOTO24 || dec.cls == OP_CALL24) ? imm24 : {{8{op_q[15]}}, op_q[15:0]};
                end else br_slots_q <= 2'd2;                    // branch in a delay slot: outer target wins
              end
            end
            OP_ADD_SI: begin
              logic [31:0] hv;
              if (!dec.e24) begin
                hv = {16'd0, rA[15:0]};
                alu_res = hv + {16'd0, imm16};
                set_r(dr_hi, {8'd0, {8{alu_res[15]}}, alu_res[15:0]});
                set_nzcv16(hv, op_q, alu_res);
              end else begin
                hv = rA;
                alu_res = hv + imm16_sx24;
                set_r(dr_hi, alu_res & 32'h00ffffff);
                set_nzcv24(hv, op_q << 8, alu_res);
              end
            end
            OP_ALU_SS, OP_ALU_DI: begin
              // only the register forms are conditional; the immediate forms carry imm16 there
              if (dec.cls == OP_ALU_DI || !op_q[10] || condition({1'b0, op_q[15:12]}, 1'b0, dfl)) begin
                logic is_di; logic [31:0] wr; logic do_wr, nz00;
                is_di = (dec.cls == OP_ALU_DI);
                if (!dec.e24) begin
                  drv = {16'd0, rA[15:0]};
                  s1v = is_di ? {16'd0, imm16} : {16'd0, rB[15:0]};
                  s2v = is_di ? drv : (op_q[11] ? {16'd0, rC[15:0]} : drv);
                end else begin
                  drv = rA;
                  s1v = is_di ? imm16_sx24 : rB;
                  s2v = is_di ? drv : (op_q[11] ? rC : drv);
                end
                do_wr = 1'b1; nz00 = 1'b0; alu_res = 32'd0;
                case (dec.sub)
                  4'h0: alu_res = s2v + s1v;                      // add
                  4'h1: alu_res = s1v << 1;                       // mul2
                  4'h2: alu_res = s1v - s2v;                      // subr
                  4'h4: alu_res = s2v - s1v;                      // sub
                  4'h5: alu_res = 32'd0 - s1v;                    // neg
                  4'h6: begin alu_res = s2v & ~s1v; nz00 = 1'b1; end
                  4'h7: begin alu_res = drv - s1v; do_wr = 1'b0; end  // cmp
                  4'h8: begin alu_res = s2v ^ s1v; nz00 = 1'b1; end
                  4'ha: begin alu_res = s2v | s1v; nz00 = 1'b1; end
                  4'he: begin alu_res = s2v & s1v; nz00 = 1'b1; end
                  4'hf: begin alu_res = drv & s1v; nz00 = 1'b1; do_wr = 1'b0; end
                  4'h9: begin                                     // rcr
                    alu_res = dec.e24 ? (((nzc_q >> 1) & 32'h800000) | (s1v >> 1))
                                      : (((nzc_q >> 9) & 32'h8000) | (s1v >> 1));
                  end
                  4'hb: alu_res = ((nzc_q >> 24) & 32'h1) | (s1v << 1);   // rcl
                  4'hc: alu_res = s1v >> 1;                                // shr
                  4'hd: alu_res = dec.e24 ? ((s1v & 32'h800000) | (s1v >> 1)) : ((s1v & 32'h8000) | (s1v >> 1));
                  default: do_wr = 1'b0;
                endcase
                if (do_wr) begin
                  // result register width: 16-bit forms sign-extend to 24, 24-bit truncate
                  // (MAME leaves the logical 'e' results untruncated; they are 24-bit anyway)
                  wr = dec.e24 ? (alu_res & 32'h00ffffff) : {8'd0, {8{alu_res[15]}}, alu_res[15:0]};
                  if (dec.e24 && nz00) wr = alu_res;
                  if (dec.e24 && dec.sub == 4'hc) wr = alu_res;      // shre: m_r[dr] = res
                  set_r(dr_lo, wr);
                end
                case (dec.sub)
                  4'h0, 4'h2, 4'h4: if (!dec.e24) set_nzcv16(s1v, s2v, alu_res); else set_nzcv24(s1v, s2v, alu_res);
                  4'h1, 4'h5:       if (!dec.e24) set_nzcv16(s1v, 32'd0, alu_res); else set_nzcv24(s1v, 32'd0, alu_res);
                  4'h7:             if (!dec.e24) set_nzcv16(drv, s1v, alu_res); else set_nzcv24(drv, s1v, alu_res);
                  4'h6, 4'h8, 4'ha, 4'he, 4'hf: if (!dec.e24) set_nz00_16(alu_res); else set_nz00_24(alu_res);
                  4'h9, 4'hc, 4'hd: begin   // shifts right: carry = bit shifted out
                    nzc_q <= dec.e24 ? (alu_res | ((s1v & 32'h1) << 24)) : (((alu_res & 32'hffff) << 8) | ((s1v & 32'h1) << 24));
                    vfl_q <= 32'd0;
                  end
                  4'hb: begin
                    nzc_q <= dec.e24 ? (alu_res | ((s1v & 32'h800000) << 1)) : (((alu_res & 32'hffff) << 8) | ((s1v & 32'h8000) << 9));
                    vfl_q <= 32'd0;
                  end
                  default: ;
                endcase
                // the immediate forms use op/op<<8 as the second flag operand
                if (is_di) case (dec.sub)
                  4'h0, 4'h2, 4'h4, 4'h7: if (!dec.e24) set_nzcv16(drv, op_q, alu_res); else set_nzcv24(drv, op_q << 8, alu_res);
                  default: ;
                endcase
              end
            end
            OP_LDST: begin
              // sub: 0 load_hi 1 load_li 2 load_i 3 load_ei 4 store_hi 5 store_li 6 store_i 7 store_ei
              //      8 load_hr 9 load_lr a load_r b load_er c store_hr d store_lr e store_r f store_er
              logic is_reg, is_store; logic [2:0] sz; logic [31:0] addr;
              is_reg = dec.sub[3]; is_store = dec.sub[2];
              sz = (dec.sub[1:0] == 2'd3) ? 3'd4 : (dec.sub[1:0] == 2'd2) ? 3'd2 : 3'd1;
              cau_size_q <= sz;
              cau_p_q <= op_q[9:5]; cau_i_q <= op_q[4:0];
              if (is_reg && op_q[9:5] == 5'd0) begin
                // special register through the pointer field
                if (is_store) begin
                  logic [31:0] sv;
                  sv = (dec.sub[1:0] == 2'd0) ? (rA >> 8) : (dec.sub[1:0] == 2'd1) ? (rA & 32'hff)
                     : (dec.sub[1:0] == 2'd2) ? {16'd0, rA[15:0]} : rA;
                  case (op_q[4:0])
                    5'd4: ibuf_q <= sv;  5'd5: obuf_q <= sv;
                    5'd6: begin pdr_q <= sv[15:0]; pcr_q <= pcr_q | 16'h0020; update_pins(pcr_q | 16'h0020); end
                    5'd14: piop_q <= sv; 5'd20: pdr2_q <= sv[15:0];
                    5'd22: begin pir_q <= sv[15:0]; pcr_q <= pcr_q | 16'h0040; update_pins(pcr_q | 16'h0040); end
                    5'd30: pcw_q <= sv[15:0];
                    default: ;
                  endcase
                end else begin
                  logic [31:0] rv;
                  rv = 32'd0;
                  case (op_q[4:0])
                    5'd4: rv = ibuf_q; 5'd5: rv = obuf_q;
                    5'd6: begin rv = {16'd0, pdr_q}; pcr_q <= pcr_q & ~16'h0020; update_pins(pcr_q & ~16'h0020); end
                    5'd14: rv = piop_q; 5'd20: rv = {16'd0, pdr2_q};
                    5'd22: begin rv = {16'd0, pir_q}; pcr_q <= pcr_q & ~16'h0040; update_pins(pcr_q & ~16'h0040); end
                    5'd30: rv = {16'd0, pcw_q};
                    default: ;
                  endcase
                  cau_val_q <= rv;
                  st_q <= S_CAU_W;
                end
              end else begin
                addr = is_reg ? rB : imm16_sx24;
                cau_addr_q <= addr;
                mem_req_o <= 1'b1; mem_addr_o <= addr[23:0]; mem_size_o <= sz;
                mem_we_o <= is_store;
                case (dec.sub[1:0])
                  2'd0: mem_wdata_o <= rA >> 8;                 // store_hi: byte 15:8
                  2'd1: mem_wdata_o <= rA;                      // store_li
                  2'd2: mem_wdata_o <= {16'd0, rA[15:0]};
                  default: mem_wdata_o <= {{8{rA[23]}}, rA[23:0]};  // sext24
                endcase
                if (is_reg) set_r_raw(op_q[9:5], (rB + cau_inc(rC, op_q[4:0], sz)) & 32'h00ffffff);
                st_q <= S_CAU_MEM;
              end
            end
            OP_LOAD24: set_r(dr_lo, {8'd0, imm24});
            OP_D1, OP_D2, OP_D3, OP_D4, OP_D5: begin
              d_mult_x = 1'b1;
              d_mult_y = (dec.cls == OP_D2 || dec.cls == OP_D3);
              if (dec.cls == OP_D5) begin
                // source through the Y field; ifXX read only when the condition holds
                case (dec.sub)
                  4'd5: d_cond_skip_q <= !dbl_is_neg(nz_q);
                  4'd6: d_cond_skip_q <= !dbl_is_zero(nz_q);
                  4'd7: d_cond_skip_q <= dbl_is_neg(nz_q) || dbl_is_zero(nz_q);
                  default: d_cond_skip_q <= 1'b0;
                endcase
                st_q <= S_DY;
              end else st_q <= S_DX;
            end
            default: ;
          endcase
        end
        // ------------------------------------------------ CAU memory completion
        S_CAU_MEM: if (mem_ack_i) begin
          if (mem_we_o) st_q <= S_DONE;
          else begin cau_val_q <= mem_rdata_i; st_q <= S_CAU_W; end
        end
        S_CAU_W: begin
          // loads: hi/li/i/ei by sub[1:0]; register forms differ for the high byte
          logic [31:0] v, res;
          v = cau_val_q;
          case (dec.sub[1:0])
            2'd0: begin                                     // load_hi / load_hr
              res = dec.sub[3] ? ((v & 32'hff) << 8) : (v & 32'hff);
              set_r(dr_lo, {8'd0, {8{res[15]}}, res[15:0]});
              nzc_q <= res << 8; vfl_q <= 32'd0;
            end
            2'd1: begin res = v & 32'hff; set_r(dr_lo, res); nzc_q <= res << 8; vfl_q <= 32'd0; end
            2'd2: begin res = v & 32'hffff; set_r(dr_lo, {8'd0, {8{res[15]}}, res[15:0]}); nzc_q <= res << 8; vfl_q <= 32'd0; end
            default: begin res = v & 32'h00ffffff; set_r(dr_lo, res); nzc_q <= res; vfl_q <= 32'd0; end
          endcase
          st_q <= S_DONE;
        end
        // ------------------------------------------------------------- DAU X
        S_DX: begin
          lastp_q <= xp;
          if (xp != 4'd0) begin
            mem_req_o <= 1'b1; mem_we_o <= 1'b0; mem_addr_o <= rA[23:0]; mem_size_o <= 3'd4;
            set_r_raw(xp, (rA + dau_inc(rB, xi, 3'd4)) & 32'h00ffffff);
            st_q <= S_DX_W;
          end else begin
            dx_q <= (xi < 3'd4) ? (d_mult_x ? am_out : a[xi[1:0]]) : 64'd0;
            st_q <= S_DY;
          end
        end
        S_DX_W: if (mem_ack_i) begin dx_q <= d2d_out; st_q <= S_DY; end
        // ------------------------------------------------------------- DAU Y
        S_DY: begin
          logic [3:0] p; logic is_1st;
          is_1st = (dec.cls == OP_D5);               // dau_read_pi_*_1st: no p=15 inheritance
          p = dy_p;
          if (dec.cls == OP_D5 && d_cond_skip_q) begin
            dres_q <= a[dacc];                         // ifXX false: result is the accumulator
            st_q <= S_DCOMP;
          end else begin
            lastp_q <= p;
            if (p != 4'd0) begin
              logic [2:0] sz;
              sz = (dec.cls == OP_D5 && dec.sub == 4'd2) ? 3'd2 : 3'd4;   // float reads a word
              mem_req_o <= 1'b1; mem_we_o <= 1'b0; mem_addr_o <= rA[23:0]; mem_size_o <= sz;
              set_r_raw(p, (rA + dau_inc(rB, yi, sz)) & 32'h00ffffff);
              st_q <= S_DY_W;
            end else begin
              // accumulator operand: doubles direct or deferred; raw forms convert
              if (yi < 3'd4) begin
                dy_q <= d_mult_y ? am_out : a[yi[1:0]];
                dword_q <= dtd_out;
              end else begin dy_q <= 64'd0; dword_q <= 32'd0; end
              st_q <= S_DCOMP;
            end
          end
        end
        S_DY_W: if (mem_ack_i) begin
          dy_q <= d2d_out;
          dword_q <= mem_rdata_i;
          st_q <= S_DCOMP;
        end
        // ---------------------------------------------------------- DAU compute
        S_DCOMP: begin
          st_q <= S_DFMA_W;
          dz_is_res_q <= 1'b1;
          case (dec.cls)
            OP_D1: begin
              if (dec.am == 3'd4) begin                  // 0px / 0mx: plain copy or negate
                dres_q <= {dy_q[63] ^ op_q[24], dy_q[62:0]};
                st_q <= S_DFIN;
              end else begin
                fma_a <= (dec.am == 3'd5) ? DBL_ONE : am_out;
                fma_x <= dx_q; fma_y <= dy_q;
                fma_negp <= dec.sgn[0]; fma_negy <= dec.sgn[1];
                fma_start <= 1'b1;
              end
            end
            OP_D2, OP_D3: begin
              fma_a <= dy_q; fma_x <= dx_q;
              fma_y <= (dec.am == 3'd4) ? 64'd0 : (dec.am == 3'd5) ? DBL_ONE : a[dec.am[1:0]];
              fma_negp <= dec.sgn[0]; fma_negy <= dec.sgn[1];
              fma_start <= 1'b1;
              dz_is_res_q <= (dec.cls == OP_D3);
            end
            OP_D4: begin
              fma_a <= DBL_ONE; fma_x <= dx_q; fma_y <= dy_q;
              fma_negp <= dec.sgn[0]; fma_negy <= dec.sgn[1];
              fma_start <= 1'b1;
              dz_is_res_q <= 1'b0;
            end
            OP_D5: begin
              case (dec.sub)
                4'd2: begin dres_q <= i2d_out; st_q <= S_DFIN; end   // float
                4'd3, 4'd11: begin                         // int / int24: round half away via +-0.5 then floor/ceil
                  fma_a <= DBL_ONE; fma_x <= dy_q; fma_y <= DBL_HALF;
                  fma_negp <= 1'b0; fma_negy <= r[26][4];
                  fma_start <= 1'b1;
                end
                4'd4: begin dres_q <= dbl_round_to_float(dy_q); st_q <= S_DFIN; end
                4'd5, 4'd6, 4'd7: begin if (!d_cond_skip_q) dres_q <= dy_q; st_q <= S_DFIN; end
                4'd10: begin dres_q <= i2d_out; st_q <= S_DFIN; end  // float24
                4'd14: begin dword_q <= dword_q ^ 32'h7fffffff; dres_q <= d2d_out; st_q <= S_DFIN; end
                default: st_q <= S_DFIN;
              endcase
            end
            default: st_q <= S_DFIN;
          endcase
        end
        S_DFMA_W: if (fma_done) begin
          if (dec.cls == OP_D5) begin fres_q <= fma_res; st_q <= S_DROUND_W; end   // int / int24
          else begin dres_q <= fma_res; st_q <= S_DFIN; end
        end
        S_DROUND_W: begin rounded_q <= rounded_c; st_q <= S_DINT; end   // floor(val + 0.5) / ceil(val - 0.5)
        S_DINT:     begin res32_q <= res32_c; st_q <= S_DZ; end         // saturated, clamped integer
        S_DZ:       begin dword_q <= res32_q; dres_q <= d2d_out; st_q <= S_DFIN; end
        // ----------------------------------------------- DAU Z write and flags
        S_DFIN: begin
          // Z operand write (dau_write_pi_double / _4bytes / _2bytes)
          logic [3:0] p; logic raw; logic [31:0] rawv; logic is_word;
          raw = (dec.cls == OP_D5 && (dec.sub == 4'd3 || dec.sub == 4'd11 || dec.sub == 4'd14));
          is_word = (dec.cls == OP_D5 && dec.sub == 4'd3);
          zval = zval_c;
          rawv = dword_q;
          p = dz_p;
          if (op_q[6:0] != 7'd7) begin
            if (p != 4'd0) begin
              if (raw) begin
                lastp_q <= p;
                defer_write(rA[23:0], is_word ? {16'd0, rawv[15:0]} : rawv, !is_word);
              end else defer_write(rA[23:0], dtd_out, 1'b1);
              set_r_raw(p, (rA + dau_inc(rB, zi, is_word ? 3'd2 : 3'd4)) & 32'h00ffffff);
            end else if (zi < 3'd4) begin
              // accumulator as Z: a noflags set, recorded in the history
              ab_push(zi[1:0]);
              a[zi[1:0]] <= raw ? d2d_out : zval;
            end
          end
          st_q <= S_DSET;
        end
        S_DSET: begin
          // destination accumulator: flags for most forms, none for int/int24/ifXX
          logic noflags;
          noflags = (dec.cls == OP_D5 && (dec.sub == 4'd3 || dec.sub == 4'd11 || dec.sub == 4'd5 || dec.sub == 4'd6 || dec.sub == 4'd7));
          ab_push(dacc);
          if (noflags) a[dacc] <= dres_q;
          else begin
            satres = dau_sat(dres_q, satvu);
            vu_q <= satvu; nz_q <= satres; a[dacc] <= satres;
          end
          st_q <= S_DONE;
        end
        // ------------------------------------------------------------ retire
        S_DONE: begin
          if (br_pend_q) begin
            if (br_slots_q == 2'd1) begin
              br_pend_q <= 1'b0;
              pcnext = br_abs_q ? {8'd0, br_imm_q} : (rA + {8'd0, br_imm_q});
              r[15] <= br_abs_q ? {8'd0, br_imm_q} : (pcnext & 32'h00ffffff);
            end else br_slots_q <= br_slots_q - 2'd1;
          end
          st_q <= S_IDLE;
        end
        default: st_q <= S_IDLE;
      endcase
      if (rf_we && (!rf_chk || reg_writeable(rf_idx))) r[rf_idx] <= rf_val;
    end
  end
endmodule

`default_nettype wire
