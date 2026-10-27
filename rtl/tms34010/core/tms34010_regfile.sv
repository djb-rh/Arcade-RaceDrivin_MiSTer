// -----------------------------------------------------------------------------
// tms34010_regfile.sv
//
// General-purpose register file for the TMS34010 core.
//
// Architectural contract (per bibliography/hdl-reimplementation/03-registers.md):
//   - File A: A0..A14 (15 entries, 32 bits each).
//   - File B: B0..B14 (15 entries, 32 bits each).
//   - SP    : 1 entry, 32 bits, accessible from BOTH files at index 4'hF
//             (i.e., A15 and B15 are aliases for the same SP).
//
// Port shape:
//   - Three combinational read ports, each from its own MLAB copy of the
//     file (see Storage below).
//   - One synchronous write port. Write-after-read on the SAME port within
//     a cycle: a read on `rs1`/`rs2` issued in the same cycle as a write
//     to the matching index returns the OLD value (the new value lands at
//     the next clock edge). This matches the multi-cycle execute model.
//
// Reset:
//   Synchronous active-high `rst`. SP clears to '0; the file entries read
//   as '0 until first written (valid bits), which is what the flop-based
//   file's reset gave.
//
// Notes:
//   - SP aliasing is implemented in one place (the read/write decode
//     functions). Code that touches the regfile never has to know about
//     the alias.
//   - No `/`, no `%`, no `initial` (rst handles all init), no unbounded
//     loops, no latches (all combinational outputs assigned on every
//     path through `always_comb`).
//
// Spec source:
//   third_party/TMS34010_Info/bibliography/hdl-reimplementation/03-registers.md
// -----------------------------------------------------------------------------

`default_nettype none
module tms34010_regfile
  import tms34010_pkg::*;
(
  input  logic                  clk,
  input  logic                  rst,

  // Read port 1.
  input  reg_file_t             rs1_file,
  input  reg_idx_t              rs1_idx,
  output logic [DATA_WIDTH-1:0] rs1_data,

  // Read port 2.
  input  reg_file_t             rs2_file,
  input  reg_idx_t              rs2_idx,
  output logic [DATA_WIDTH-1:0] rs2_data,

  // Read port 3. Added for instructions that need a third simultaneous
  // source — currently CPW (reads the point plus WSTART and WEND). Async
  // read like the others; a third read mux on this flop-based file is
  // cheap (no extra memory blocks).
  input  reg_file_t             rs3_file,
  input  reg_idx_t              rs3_idx,
  output logic [DATA_WIDTH-1:0] rs3_data,

  // Write port.
  input  logic                  wr_en,
  input  reg_file_t             wr_file,
  input  reg_idx_t              wr_idx,
  input  logic [DATA_WIDTH-1:0] wr_data,

  // Observability: SP value, used by testbenches and (eventually) host
  // interface debug paths.
  output logic [DATA_WIDTH-1:0] sp_o
);

  // ---------------------------------------------------------------------------
  // Storage: MLAB LUT RAM, one copy per read port (Quartus infers an MLAB
  // only for a single asynchronous read per array, with the no_rw_check
  // style), so six 16 x 32 arrays plus the SP flop.  As flops with three
  // read muxes this file cost 1,100 ALMs; as MLABs about 80.  Read in the
  // cycle of a write to the same entry returns the old value, as before.
  // MLABs have no reset: a per-entry valid bit (cleared by rst, set by the
  // first write) makes a never-written entry read as zero, as the flops did.
  // ---------------------------------------------------------------------------
  (* ramstyle = "MLAB, no_rw_check" *) logic [DATA_WIDTH-1:0] a1 [0:15];
  (* ramstyle = "MLAB, no_rw_check" *) logic [DATA_WIDTH-1:0] a2 [0:15];
  (* ramstyle = "MLAB, no_rw_check" *) logic [DATA_WIDTH-1:0] a3 [0:15];
  (* ramstyle = "MLAB, no_rw_check" *) logic [DATA_WIDTH-1:0] b1 [0:15];
  (* ramstyle = "MLAB, no_rw_check" *) logic [DATA_WIDTH-1:0] b2 [0:15];
  (* ramstyle = "MLAB, no_rw_check" *) logic [DATA_WIDTH-1:0] b3 [0:15];
  logic [14:0] a_valid_q, b_valid_q;
  logic [DATA_WIDTH-1:0] sp_q;

  wire wr_sp = wr_en && (wr_idx == REG_SP_IDX);
  wire wr_a  = wr_en && (wr_idx != REG_SP_IDX) && (wr_file != REG_FILE_B);
  wire wr_b  = wr_en && (wr_idx != REG_SP_IDX) && (wr_file == REG_FILE_B);

  always_ff @(posedge clk) begin
    if (wr_a) begin a1[wr_idx] <= wr_data; a2[wr_idx] <= wr_data; a3[wr_idx] <= wr_data; end
  end
  always_ff @(posedge clk) begin
    if (wr_b) begin b1[wr_idx] <= wr_data; b2[wr_idx] <= wr_data; b3[wr_idx] <= wr_data; end
  end

  // ---------------------------------------------------------------------------
  // Read multiplex (combinational / async read)
  //
  // Index 4'hF on either file returns SP. Other indices return the matching
  // file entry, zero until first written.
  // ---------------------------------------------------------------------------
  always_comb begin
    if (rs1_idx == REG_SP_IDX)           rs1_data = sp_q;
    else if (rs1_file == REG_FILE_B)     rs1_data = b_valid_q[rs1_idx] ? b1[rs1_idx] : '0;
    else                                 rs1_data = a_valid_q[rs1_idx] ? a1[rs1_idx] : '0;
  end
  always_comb begin
    if (rs2_idx == REG_SP_IDX)           rs2_data = sp_q;
    else if (rs2_file == REG_FILE_B)     rs2_data = b_valid_q[rs2_idx] ? b2[rs2_idx] : '0;
    else                                 rs2_data = a_valid_q[rs2_idx] ? a2[rs2_idx] : '0;
  end
  always_comb begin
    if (rs3_idx == REG_SP_IDX)           rs3_data = sp_q;
    else if (rs3_file == REG_FILE_B)     rs3_data = b_valid_q[rs3_idx] ? b3[rs3_idx] : '0;
    else                                 rs3_data = a_valid_q[rs3_idx] ? a3[rs3_idx] : '0;
  end

  // ---------------------------------------------------------------------------
  // SP and the valid bits
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      sp_q <= '0; a_valid_q <= '0; b_valid_q <= '0;
    end else begin
      if (wr_sp) sp_q <= wr_data;
      if (wr_a)  a_valid_q[wr_idx] <= 1'b1;
      if (wr_b)  b_valid_q[wr_idx] <= 1'b1;
    end
  end

  assign sp_o = sp_q;

endmodule : tms34010_regfile
`default_nettype wire
