`default_nettype none

// DSK board DSP32C memory as MAME maps it (dsk_dsp32_map): 8 KiB at 0,
// 2^RAM1_LOG2 bytes at 0x600000 (256 KiB on the board; the game only reads
// the first 128 KiB), 2 KiB at 0xfff800.  32-bit little-endian words with
// byte lanes; sub-word accesses select lanes by the low address bits, long
// accesses ignore them, as MAME's native-width reads do.  Unmapped reads
// return 0xffffffff (unmap_value_high), unmapped writes vanish.  One access
// per request, data and ack the next clock.
module dsp32c_ram #(
  parameter int RAM1_LOG2 = 18
) (
  input  logic        clk_i,
  input  logic        req_i,
  input  logic        we_i,
  input  logic [23:0] addr_i,
  input  logic [2:0]  size_i,       // 1, 2 or 4 bytes
  input  logic [31:0] wdata_i,
  output logic [31:0] rdata_o,      // right-aligned for sizes 1 and 2
  output logic        ack_o
);
  logic [31:0] ram0 [0:2047];                      // 0x000000-0x001fff
  logic [31:0] ram1 [0:(1 << (RAM1_LOG2 - 2)) - 1];  // 0x600000-
  logic [31:0] ram2 [0:511];                       // 0xfff800-0xffffff

  logic sel0, sel1, sel2;
  assign sel0 = addr_i[23:13] == 11'd0;
  assign sel1 = addr_i[23:RAM1_LOG2] == (24'h600000 >> RAM1_LOG2);
  assign sel2 = addr_i[23:11] == 13'h1fff;

  logic [3:0] be;
  logic [31:0] wd;
  always_comb begin
    be = 4'b0000; wd = wdata_i;
    case (size_i)
      3'd1: begin be = 4'b0001 << addr_i[1:0]; wd = {4{wdata_i[7:0]}}; end
      3'd2: begin be = addr_i[1] ? 4'b1100 : 4'b0011; wd = {2{wdata_i[15:0]}}; end
      default: be = 4'b1111;
    endcase
  end

  logic [31:0] word0, word1, word2, word;
  logic [1:0]  lane_q;
  logic [2:0]  size_q;
  logic        hit_q;
  always_ff @(posedge clk_i) begin
    ack_o  <= req_i;
    lane_q <= addr_i[1:0];
    size_q <= size_i;
    hit_q  <= sel0 || sel1 || sel2;
    if (req_i && we_i) begin
      for (int b = 0; b < 4; b++) if (be[b]) begin
        if (sel0) ram0[addr_i[12:2]][b*8 +: 8] <= wd[b*8 +: 8];
        if (sel1) ram1[addr_i[RAM1_LOG2-1:2]][b*8 +: 8] <= wd[b*8 +: 8];
        if (sel2) ram2[addr_i[10:2]][b*8 +: 8] <= wd[b*8 +: 8];
      end
    end
    word0 <= ram0[addr_i[12:2]];
    word1 <= ram1[addr_i[RAM1_LOG2-1:2]];
    word2 <= ram2[addr_i[10:2]];
  end
  logic sel0_q, sel1_q;
  always_ff @(posedge clk_i) begin sel0_q <= sel0; sel1_q <= sel1; end
  always_comb begin
    word = !hit_q ? 32'hffffffff : sel0_q ? word0 : sel1_q ? word1 : word2;
    case (size_q)
      3'd1: rdata_o = {24'd0, word[lane_q*8 +: 8]};
      3'd2: rdata_o = {16'd0, lane_q[1] ? word[31:16] : word[15:0]};
      default: rdata_o = word;
    endcase
  end
endmodule

`default_nettype wire
