`default_nettype none

// ASIC65, the DSK board's maths coprocessor, simulated at command level the
// way MAME's src/mame/atari/asic65.cpp does in ASIC65_STANDARD mode.  Race
// Drivin's ASIC65 is a TMS320C15 whose mask ROM (136077-1027.30j) has never
// been dumped, so MAME's simulation is the oracle for this core and this
// module reproduces it bit for bit: the commands MAME knows (REFLECT,
// CHECKSUM, VERSION, RAMTEST, RESET, TMATRIXMULT, MATRIXMULT, SIN, COS,
// YORIGIN, TRANSFORM) and the ones it does not (they answer 0).
//
// 68010 view (decoded by harddrivin_dsk_board): a write to an even word of
// 0x914000-0x917fff pushes a parameter (32 deep, then dropped), a write to an
// odd word sets the command and clears both indices, a read of that window
// returns the next result (computed from the parameters at read time, with
// MAME's side effects), and a read of 0x918000-0x91bfff returns the status
// 0x4000 (always ready; answered by the board module).  Reset comes from the
// DSK control latch, function 4: asserting it forgets the command, releasing
// it re-issues the command written while held.
//
// A result read takes three clocks: operand select, multiply, finalise.  The
// matrix products are 32 x 16 bit signed, the sum is shifted right by 14 and
// handed back as a high word then a low word per element, as in MAME.
module asic65_sim #(
  // Quarter-wave table from tools/asic65_sintab.py: entry a holds
  // int(16384 * sin(pi * a / 32768)) for 0 <= a < 16384.
  parameter SIN_TABLE_FILE = "rtl/asic65/asic65_sin.hex"
) (
  input  logic        clk_i,
  input  logic        rst_i,

  // Control latch function 4 written: MAME reset_line(!val).
  input  logic        reset_we_i,
  input  logic        reset_state_i,   // 1 = reset asserted

  input  logic        param_we_i,      // pulse: wdata_i is a parameter
  input  logic        cmd_we_i,        // pulse: wdata_i is a command
  input  logic [15:0] wdata_i,
  input  logic        rd_req_i,        // pulse: start a result read
  output logic        rd_ack_o,        // pulse: rdata_o valid
  output logic [15:0] rdata_o
);
  // MAME's command_map[ASIC65_STANDARD]
  typedef enum logic [3:0] {
    OP_UNKNOWN, OP_REFLECT, OP_CHECKSUM, OP_VERSION, OP_RAMTEST, OP_RESET,
    OP_SIN, OP_COS, OP_TMATRIXMULT, OP_MATRIXMULT, OP_YORIGIN, OP_TRANSFORM
  } op_t;

  logic [15:0] param_q [0:31];
  logic [5:0]  param_index_q;     // 0..32
  logic [15:0] result_index_q;
  logic [15:0] command_q;
  logic        command_valid_q;   // MAME m_command != -1
  logic        reset_state_q;
  logic [15:0] yorigin_q;

  op_t op;
  always_comb begin
    op = OP_UNKNOWN;
    if (command_valid_q) begin
      unique case (command_q)
        16'h0001: op = OP_REFLECT;
        16'h0002: op = OP_CHECKSUM;
        16'h0003: op = OP_VERSION;
        16'h0004: op = OP_RAMTEST;
        16'h0007: op = OP_RESET;
        16'h000e: op = OP_TMATRIXMULT;
        16'h0010: op = OP_MATRIXMULT;
        16'h0014: op = OP_SIN;
        16'h0015: op = OP_COS;
        16'h0016: op = OP_YORIGIN;
        16'h0017: op = OP_TRANSFORM;
        default:  op = OP_UNKNOWN;
      endcase
    end
  end

  // ---- sine table ---------------------------------------------------------
  (* ramstyle = "M10K" *) logic [15:0] sin_tab [0:16383];
  initial $readmemh(SIN_TABLE_FILE, sin_tab);
  logic [13:0] sin_idx_q;
  logic        sin_max_q, sin_neg_q;
  logic [15:0] sin_tab_q;
  always_ff @(posedge clk_i) sin_tab_q <= sin_tab[sin_idx_q];

  // ---- read sequencer -----------------------------------------------------
  logic [1:0] stage_q;
  op_t        op_q;
  logic signed [31:0] v0_q, v1_q, v2_q;
  logic signed [15:0] m0_q, m1_q, m2_q;
  logic signed [15:0] ta_q, tb_q;
  logic signed [47:0] prod0_q, prod1_q, prod2_q;
  logic signed [31:0] tprod_q;

  // operand selection (stage 1)
  logic [1:0]  row;
  logic [15:0] sin_arg;
  logic [16:0] sin_abs, sin_fold;
  assign row = result_index_q[2:1];
  assign sin_arg = (op == OP_COS) ? (16'd16384 - param_q[0]) : param_q[0];
  assign sin_abs = sin_arg[15] ? (17'd0 - {sin_arg[15], sin_arg}) : {1'b0, sin_arg};  // |p|, 32768 for -32768
  assign sin_fold = (sin_abs > 17'd16384) ? (17'd32768 - sin_abs) : sin_abs;

  // finalisation (stage 3)
  logic signed [49:0] msum, msum14;
  logic signed [31:0] t2, t3, t4w;
  logic signed [15:0] t4;
  logic [15:0] sinval;
  logic [15:0] result;
  assign msum   = 50'(prod0_q) + 50'(prod1_q) + 50'(prod2_q);
  assign msum14 = msum >>> 14;
  assign t2  = (tprod_q >>> 8) - 32'sd1;
  assign t3  = (tprod_q >>> 15) + 32'sd168;              // + 0xa8
  assign t4  = 16'(tprod_q >>> 10);                        // (s16)(...)
  assign t4w = 32'(signed'(yorigin_q)) - 32'(t4) - (32'(t4) <<< 1);
  assign sinval = sin_max_q ? 16'd16384 : sin_tab_q;

  always_comb begin
    result = 16'h0000;
    unique case (op_q)
      OP_REFLECT:  if (param_index_q != 6'd0) result = param_q[5'(param_index_q - 6'd1)];
      OP_CHECKSUM: result = 16'h0027;
      OP_VERSION:  result = 16'h0013;
      OP_SIN, OP_COS:
        if (param_index_q != 6'd0) result = sin_neg_q ? (16'd0 - sinval) : sinval;
      OP_TMATRIXMULT, OP_MATRIXMULT:
        if (param_index_q >= 6'd15)
          result = result_index_q[0] ? msum14[15:0] : msum14[31:16];
      OP_TRANSFORM:
        unique case (param_index_q)
          6'd2:    result = (t2 > 32'sh00003fff) ? 16'h0000 : t2[15:0];
          6'd3:    result = t3[15:0];
          6'd4:    result = t4w[15:0];
          default: result = 16'h0000;
        endcase
      default: result = 16'h0000;
    endcase
  end

  always_ff @(posedge clk_i) begin
    rd_ack_o <= 1'b0;
    if (rst_i) begin
      for (int i = 0; i < 32; i++) param_q[i] <= 16'h0000;
      param_index_q   <= 6'd0;
      result_index_q  <= 16'd0;
      command_q       <= 16'h0000;
      command_valid_q <= 1'b1;        // MAME starts with m_command = 0
      reset_state_q   <= 1'b0;
      yorigin_q       <= 16'h1800;
      stage_q         <= 2'd0;
      rdata_o         <= 16'h0000;
    end else begin
      // asic65_device::reset_line
      if (reset_we_i) begin
        if (reset_state_i && !reset_state_q) command_valid_q <= 1'b0;
        else if (!reset_state_i && reset_state_q && command_valid_q) begin
          result_index_q <= 16'd0;
          param_index_q  <= 6'd0;
        end
        reset_state_q <= reset_state_i;
      end
      // asic65_device::data_w
      if (param_we_i && param_index_q != 6'd32) begin
        param_q[5'(param_index_q)] <= wdata_i;
        param_index_q <= param_index_q + 6'd1;
      end
      if (cmd_we_i) begin
        command_q       <= wdata_i;
        command_valid_q <= 1'b1;
        result_index_q  <= 16'd0;
        param_index_q   <= 6'd0;
      end
      // asic65_device::read, three clocks
      unique case (stage_q)
        2'd0: if (rd_req_i) begin
          stage_q <= 2'd1;
          op_q    <= op;
          v0_q <= {param_q[9],  param_q[10]};
          v1_q <= {param_q[11], param_q[12]};
          v2_q <= {param_q[13], param_q[14]};
          unique case (row)
            2'd0: begin
              m0_q <= param_q[0];
              m1_q <= (op == OP_TMATRIXMULT) ? param_q[3] : param_q[1];
              m2_q <= (op == OP_TMATRIXMULT) ? param_q[6] : param_q[2];
            end
            2'd1: begin
              m0_q <= (op == OP_TMATRIXMULT) ? param_q[1] : param_q[3];
              m1_q <= param_q[4];
              m2_q <= (op == OP_TMATRIXMULT) ? param_q[7] : param_q[5];
            end
            2'd2: begin
              m0_q <= (op == OP_TMATRIXMULT) ? param_q[2] : param_q[6];
              m1_q <= (op == OP_TMATRIXMULT) ? param_q[5] : param_q[7];
              m2_q <= param_q[8];
            end
            default: begin m0_q <= 16'sd0; m1_q <= 16'sd0; m2_q <= 16'sd0; end
          endcase
          ta_q <= param_q[0];
          unique case (param_index_q)
            6'd2:    tb_q <= param_q[1];
            6'd3:    tb_q <= param_q[2];
            6'd4:    tb_q <= param_q[3];
            default: tb_q <= 16'sd0;
          endcase
          sin_idx_q <= sin_fold[13:0];
          sin_max_q <= (sin_fold == 17'd16384);
          sin_neg_q <= sin_arg[15];
        end
        2'd1: begin
          stage_q <= 2'd2;
          prod0_q <= 48'(v0_q) * 48'(m0_q);
          prod1_q <= 48'(v1_q) * 48'(m1_q);
          prod2_q <= 48'(v2_q) * 48'(m2_q);
          tprod_q <= 32'(ta_q) * 32'(tb_q);
        end
        default: begin
          stage_q  <= 2'd0;
          rd_ack_o <= 1'b1;
          rdata_o  <= result;
          // side effects of the read
          unique case (op_q)
            OP_REFLECT: if (param_index_q != 6'd0) param_index_q <= param_index_q - 6'd1;
            OP_RESET: begin result_index_q <= 16'd0; param_index_q <= 6'd0; end
            OP_TMATRIXMULT, OP_MATRIXMULT:
              if (param_index_q >= 6'd15) result_index_q <= result_index_q + 16'd1;
            OP_YORIGIN: if (param_index_q != 6'd0) yorigin_q <= param_q[5'(param_index_q - 6'd1)];
            default: ;
          endcase
        end
      endcase
    end
  end
endmodule

`default_nettype wire
