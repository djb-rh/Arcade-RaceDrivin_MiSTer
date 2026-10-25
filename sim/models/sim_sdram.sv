// Behavioural SDR SDRAM model for the whole-core simulation.
//
// Models what compact_sdram_burst.sv relies on: 4 banks x 8192 rows x 512
// columns x 16 bits (a 32 MB device), ACTIVE / READ / WRITE / PRECHARGE /
// AUTO REFRESH / LOAD MODE, CAS latency 2, burst length 4 sequential with
// wrap inside the aligned 4-word block, and DQM byte masks on writes.
// Commands are sampled on the rising edge of SDRAM_CLK, which the controller
// drives inverted relative to its own clock, so the half-cycle offset the
// controller's comments describe is reproduced.
`timescale 1ps/1ps
module sim_sdram (
  input  logic        clk,      // SDRAM_CLK from the controller
  input  logic        cke,
  input  logic        cs_n,
  input  logic        ras_n,
  input  logic        cas_n,
  input  logic        we_n,
  input  logic [1:0]  ba,
  input  logic [12:0] a,
  input  logic        dqml,
  input  logic        dqmh,
  inout  wire  [15:0] dq
);
  localparam int ROWS = 8192, COLS = 512;
  logic [15:0] mem [0:(1 << 24) - 1];   // {bank, row, col}

  logic [12:0] row_of_bank [0:3];
  logic        bank_active [0:3];

  // read pipeline: entry k drives DQ k rising edges from now
  logic [15:0] rd_data [0:7];
  logic        rd_valid [0:7];
  // write burst continuation
  int          wr_beats_left;
  logic [1:0]  wr_bank;
  logic [12:0] wr_row;
  logic [8:0]  wr_col;
  int          wr_beat;

  logic [15:0] dq_out;
  logic        dq_oe;
  assign dq = dq_oe ? dq_out : 16'hzzzz;

  int mode_cas = 2, mode_bl = 4;
  int reads = 0, writes = 0;

  function automatic int addr_of(input logic [1:0] b, input logic [12:0] r, input logic [8:0] c);
    return {b, r, c};
  endfunction

  initial begin
    for (int i = 0; i < 4; i++) begin bank_active[i] = 0; row_of_bank[i] = 0; end
    for (int i = 0; i < 8; i++) begin rd_valid[i] = 0; rd_data[i] = 0; end
    wr_beats_left = 0;
    dq_oe = 0;
  end

  wire [2:0] cmd = {ras_n, cas_n, we_n};

  always @(posedge clk) begin
    // advance the read pipeline
    dq_oe  <= rd_valid[0];
    dq_out <= rd_data[0];
    for (int i = 0; i < 7; i++) begin rd_valid[i] <= rd_valid[i + 1]; rd_data[i] <= rd_data[i + 1]; end
    rd_valid[7] <= 0;

    // continuing write beats sample DQ and DQM on this edge
    if (wr_beats_left > 0) begin
      logic [8:0] col;
      col = {wr_col[8:2], 2'(wr_col[1:0] + 2'(wr_beat))};
      if (!dqml) mem[addr_of(wr_bank, wr_row, col)][7:0]  <= dq[7:0];
      if (!dqmh) mem[addr_of(wr_bank, wr_row, col)][15:8] <= dq[15:8];
      wr_beat <= wr_beat + 1;
      wr_beats_left <= wr_beats_left - 1;
    end

    if (cke && !cs_n) begin
      case (cmd)
        3'b011: begin // ACTIVE
          bank_active[ba] <= 1;
          row_of_bank[ba] <= a;
        end
        3'b101: begin // READ
          if (!bank_active[ba]) $display("%t sim_sdram: READ on inactive bank %d", $time, ba);
          for (int k = 0; k < 4; k++) begin
            logic [8:0] col;
            col = {a[8:2], 2'(a[1:0] + 2'(k))};
            // CAS latency 2: beat 0 valid after two more rising edges, i.e. it
            // must be in pipeline slot (2 - 1) because the slot-0 value is
            // what the *next* edge presents on the pins.
            rd_data[mode_cas - 1 + k]  <= mem[addr_of(ba, row_of_bank[ba], col)];
            rd_valid[mode_cas - 1 + k] <= 1;
          end
          reads++;
        end
        3'b100: begin // WRITE: beat 0 is on the pins now
          logic [8:0] col;
          col = a[8:0];
          if (!dqml) mem[addr_of(ba, row_of_bank[ba], col)][7:0]  <= dq[7:0];
          if (!dqmh) mem[addr_of(ba, row_of_bank[ba], col)][15:8] <= dq[15:8];
          wr_bank <= ba; wr_row <= row_of_bank[ba]; wr_col <= a[8:0];
          wr_beat <= 1; wr_beats_left <= 3;
          writes++;
        end
        3'b010: begin // PRECHARGE
          if (a[10]) for (int i = 0; i < 4; i++) bank_active[i] <= 0;
          else bank_active[ba] <= 0;
        end
        3'b001: ; // AUTO REFRESH
        3'b000: begin // LOAD MODE
          mode_cas = a[6:4];
          mode_bl  = (a[2:0] == 3'b010) ? 4 : (a[2:0] == 3'b011) ? 8 : (a[2:0] == 3'b001) ? 2 : 1;
          if (mode_bl != 4 || mode_cas != 2)
            $display("%t sim_sdram: mode register CAS=%0d BL=%0d (model assumes CAS 2, BL 4)", $time, mode_cas, mode_bl);
        end
        default: ; // NOP / burst terminate
      endcase
    end
  end
endmodule
