// Lock-step test of dsp32c_core against a MAME instruction trace
// (RD_DSP32TRACE from mame/dsp32-measure.patch; built and run by
// `tools/sim.py dsp32-test <trace>`).
//
// The trace carries, per instruction MAME is about to execute, the state
// changes since the previous one and the memory writes performed, plus the
// host's PIO accesses between instructions.  The core is stepped one
// instruction at a time: at each fetch boundary every register, accumulator,
// flag and PIO register is compared with MAME's, the memory writes of the
// step are compared as a list, PIO reads are compared with MAME's results.
//
// Plusargs: +trace=<file> +mem=<file> +max=<n> (stop after n mismatches)
`timescale 1ns/1ps
module tb_dsp32;
  import dsp32c_pkg::*;
  logic clk = 0;
  always #10 clk = ~clk;
  logic rst = 1;
  logic reset_n = 1, halt_n = 1, step_hold = 1;
  logic mem_req, mem_we, mem_ack;
  logic [23:0] mem_addr; logic [2:0] mem_size; logic [31:0] mem_wdata, mem_rdata;
  logic host_req = 0, host_we = 0, host_ack; logic [3:0] host_reg = 0; logic [15:0] host_wdata = 0, host_rdata;
  logic pif, pdf, boundary, running; logic [23:0] bpc; logic [31:0] bop;

  dsp32c_core u_core (
    .clk_i(clk), .rst_i(rst), .reset_n_i(reset_n), .halt_n_i(halt_n), .step_hold_i(step_hold),
    .mem_req_o(mem_req), .mem_we_o(mem_we), .mem_addr_o(mem_addr), .mem_size_o(mem_size),
    .mem_wdata_o(mem_wdata), .mem_rdata_i(mem_rdata), .mem_ack_i(mem_ack),
    .host_req_i(host_req), .host_we_i(host_we), .host_reg_i(host_reg), .host_wdata_i(host_wdata),
    .host_rdata_o(host_rdata), .host_ack_o(host_ack), .pif_o(pif), .pdf_o(pdf),
    .boundary_o(boundary), .boundary_pc_o(bpc), .boundary_op_o(bop), .running_o(running)
  );
  dsp32c_ram #(.RAM1_LOG2(18)) u_ram (
    .clk_i(clk), .req_i(mem_req), .we_i(mem_we), .addr_i(mem_addr), .size_i(mem_size),
    .wdata_i(mem_wdata), .rdata_o(mem_rdata), .ack_o(mem_ack)
  );

  // ---- memory image --------------------------------------------------------
  logic [7:0] img [0:272383];
  task automatic load_mem(input string file);
    int fd, n;
    fd = $fopen(file, "rb");
    if (fd == 0) begin $display("tb_dsp32: cannot open %s", file); $finish; end
    n = $fread(img, fd); $fclose(fd);
    $display("tb_dsp32: memory image %s (%0d bytes)", file, n);
    for (int i = 0; i < 2048; i++) u_ram.ram0[i] = {img[i*4+3], img[i*4+2], img[i*4+1], img[i*4]};
    for (int i = 0; i < 65536; i++) u_ram.ram1[i] = {img[8192+i*4+3], img[8192+i*4+2], img[8192+i*4+1], img[8192+i*4]};
    for (int i = 0; i < 512; i++) u_ram.ram2[i] = {img[270336+i*4+3], img[270336+i*4+2], img[270336+i*4+1], img[270336+i*4]};
  endtask

  // ---- expected state from the trace -----------------------------------------
  logic [31:0] exp_r [0:31];
  logic [63:0] exp_a [0:3];
  logic [31:0] exp_nzc, exp_v; logic [3:0] exp_vu; logic [63:0] exp_nz;
  logic [15:0] exp_pio [0:8];   // par pare pdr pdr2 pir pcr emr esr pcw
  int exp_lastp;
  typedef struct { int size; logic [23:0] addr; logic [31:0] data; } wr_t;
  wr_t exp_writes[$], got_writes[$];
  typedef struct { int kind; int reg_; logic [15:0] data; } ev_t;   // kind 0 PW, 1 PR, 2 X
  ev_t events[$];
  longint rec_n; logic [23:0] rec_pc; logic [31:0] rec_op; bit have_rec = 0;
  longint checked = 0, mismatches = 0, max_mismatch = 20, pio_checked = 0, writes_checked = 0;
  bit last_was_pw = 0;

  // collect the core's memory writes
  always @(posedge clk) if (mem_req && mem_we) begin
    wr_t w; w.size = int'(mem_size); w.addr = mem_addr; w.data = mem_wdata;
    got_writes.push_back(w);
  end

  task automatic mismatch(input string what);
    mismatches++;
    if (mismatches <= max_mismatch)
      $display("MISMATCH at instr %0d pc %06x op %08x: %s", rec_n, rec_pc, rec_op, what);
  endtask

  task automatic compare_state();
    string s;
    if (bpc !== rec_pc || bop !== rec_op) begin
      $sformat(s, "fetch: core pc %06x op %08x, mame pc %06x op %08x", bpc, bop, rec_pc, rec_op); mismatch(s);
    end
    for (int i = 0; i < 32; i++) if (u_core.r[i] !== exp_r[i]) begin
      $sformat(s, "r%0d core %08x mame %08x", i, u_core.r[i], exp_r[i]); mismatch(s); end
    for (int i = 0; i < 4; i++) if (u_core.a[i] !== exp_a[i]) begin
      $sformat(s, "a%0d core %016x mame %016x", i, u_core.a[i], exp_a[i]); mismatch(s); end
    if (u_core.nzc_q !== exp_nzc || u_core.vfl_q !== exp_v) begin
      $sformat(s, "nzc/v core %08x %08x mame %08x %08x", u_core.nzc_q, u_core.vfl_q, exp_nzc, exp_v); mismatch(s); end
    if (u_core.vu_q !== exp_vu[1:0] || u_core.nz_q !== exp_nz) begin
      $sformat(s, "DAU flags core vu %0d nz %016x mame vu %0d nz %016x", u_core.vu_q, u_core.nz_q, exp_vu, exp_nz); mismatch(s); end
    if (u_core.par_q !== exp_pio[0] || u_core.pare_q !== exp_pio[1][7:0] || u_core.pdr_q !== exp_pio[2] ||
        u_core.pdr2_q !== exp_pio[3] || u_core.pir_q !== exp_pio[4] || u_core.pcr_q !== exp_pio[5] ||
        u_core.emr_q !== exp_pio[6] || u_core.esr_q !== exp_pio[7] || u_core.pcw_q !== exp_pio[8]) begin
      $sformat(s, "PIO core par %04x pare %02x pdr %04x pdr2 %04x pir %04x pcr %04x emr %04x esr %04x pcw %04x | mame %04x %02x %04x %04x %04x %04x %04x %04x %04x",
        u_core.par_q, u_core.pare_q, u_core.pdr_q, u_core.pdr2_q, u_core.pir_q, u_core.pcr_q, u_core.emr_q, u_core.esr_q, u_core.pcw_q,
        exp_pio[0], exp_pio[1], exp_pio[2], exp_pio[3], exp_pio[4], exp_pio[5], exp_pio[6], exp_pio[7], exp_pio[8]); mismatch(s); end
    if (int'(u_core.lastp_q) !== exp_lastp) begin
      $sformat(s, "lastp core %0d mame %0d", u_core.lastp_q, exp_lastp); mismatch(s); end
    // memory writes of the step just finished
    if (got_writes.size() != exp_writes.size()) begin
      $sformat(s, "write count core %0d mame %0d", got_writes.size(), exp_writes.size()); mismatch(s);
      for (int i = 0; i < got_writes.size(); i++) if (mismatches <= max_mismatch) $display("   core W%0d %06x %08x", got_writes[i].size, got_writes[i].addr, got_writes[i].data);
      for (int i = 0; i < exp_writes.size(); i++) if (mismatches <= max_mismatch) $display("   mame W%0d %06x %08x", exp_writes[i].size, exp_writes[i].addr, exp_writes[i].data);
    end else for (int i = 0; i < got_writes.size(); i++) begin
      logic [31:0] gd, ed; gd = got_writes[i].data; ed = exp_writes[i].data;
      if (got_writes[i].size == 2) begin gd = gd & 32'hffff; end
      if (got_writes[i].size == 1) begin gd = gd & 32'hff; end
      if (got_writes[i].size != exp_writes[i].size || got_writes[i].addr !== exp_writes[i].addr || gd !== ed) begin
        $sformat(s, "write %0d: core W%0d %06x %08x mame W%0d %06x %08x", i, got_writes[i].size, got_writes[i].addr, gd,
                 exp_writes[i].size, exp_writes[i].addr, ed); mismatch(s); end
    end
    writes_checked += exp_writes.size();
    got_writes.delete(); exp_writes.delete();
    checked++;
  endtask

  task automatic host_access(input bit we, input int reg_, input logic [15:0] wdata, output logic [15:0] rdata);
    @(posedge clk); host_req <= 1; host_we <= we; host_reg <= reg_[3:0]; host_wdata <= wdata;
    @(posedge clk); while (!host_ack) @(posedge clk);
    rdata = host_rdata;
    host_req <= 0;
    @(posedge clk);
  endtask

  // host PIO accesses and resets queued between two instructions
  task automatic drain_events();
    string s;
    logic [15:0] rd;
    while (events.size() > 0) begin
      ev_t e = events.pop_front();
      case (e.kind)
        0: begin host_access(1, e.reg_, e.data, rd); last_was_pw = 1; end
        1: begin host_access(0, e.reg_, 16'h0, rd); pio_checked++; last_was_pw = 0;
             if (rd !== e.data) begin $sformat(s, "PIO read reg %0d core %04x mame %04x", e.reg_, rd, e.data); mismatch(s); end end
        default: begin
          if (!last_was_pw) begin   // reset line (DSPRESTN), not a PCR-induced reset
            @(posedge clk); reset_n <= 0; @(posedge clk); @(posedge clk); reset_n <= 1; @(posedge clk); @(posedge clk);
          end
          last_was_pw = 0;
        end
      endcase
    end
  endtask

  // a trace window that starts mid-stream: take the first record's full state
  task automatic load_state();
    for (int i = 0; i < 32; i++) begin
      u_core.rA_mem[i] = exp_r[i]; u_core.rB_mem[i] = exp_r[i]; u_core.rC_mem[i] = exp_r[i];
    end
    u_core.r_valid_q = 32'hffffffff; u_core.pc_q = exp_r[15];
    for (int i = 0; i < 4; i++) u_core.a[i] = exp_a[i];
    u_core.nzc_q = exp_nzc; u_core.vfl_q = exp_v; u_core.vu_q = exp_vu[1:0]; u_core.nz_q = exp_nz;
    u_core.par_q = exp_pio[0]; u_core.pare_q = exp_pio[1][7:0]; u_core.pdr_q = exp_pio[2]; u_core.pdr2_q = exp_pio[3];
    u_core.pir_q = exp_pio[4]; u_core.pcr_q = exp_pio[5]; u_core.emr_q = exp_pio[6]; u_core.esr_q = exp_pio[7];
    u_core.pcw_q = exp_pio[8]; u_core.lastp_q = exp_lastp[3:0];
    for (int i = 0; i < 4; i++) begin u_core.ab_valid[i] = 0; u_core.mb_valid[i] = 0; end
  endtask

  // run the pending record: step one instruction, compare at its boundary, then replay events
  task automatic run_record();
    if (checked == 0) begin @(negedge clk); load_state(); end
    // release for one instruction
    @(posedge clk); step_hold <= 0;
    @(posedge boundary);              // the fetch completed: state is MAME's "before this instruction"
    step_hold <= 1;
    #1 compare_state();
    // let the instruction finish and park
    @(posedge clk); while (u_core.st_q != u_core.S_IDLE) @(posedge clk);
    drain_events();
    if (checked % 100000 == 0) $display("  %0d instructions, %0d mismatches (pc %06x)", checked, mismatches, rec_pc);
    if (mismatches >= max_mismatch) begin
      $display("tb_dsp32: stopping after %0d mismatches, %0d instructions checked", mismatches, checked); $finish;
    end
  endtask

  initial begin
    string trace, memfile, line, kind;
    int fd, n, i1; longint n1; logic [31:0] v1, v2; logic [63:0] v64; logic [15:0] p [0:8];
    if (!$value$plusargs("trace=%s", trace)) trace = "dsp.trace";
    if (!$value$plusargs("mem=%s", memfile)) memfile = {trace, ".mem"};
    void'($value$plusargs("max=%d", max_mismatch));
    load_mem(memfile);
    repeat (4) @(posedge clk); rst <= 0; repeat (2) @(posedge clk);
    fd = $fopen(trace, "r");
    if (fd == 0) begin $display("tb_dsp32: cannot open %s", trace); $finish; end
    for (int i = 0; i < 32; i++) exp_r[i] = 0;
    for (int i = 0; i < 4; i++) exp_a[i] = 0;
    exp_nzc = 0; exp_v = 0; exp_vu = 0; exp_nz = 0; exp_lastp = 0;
    for (int i = 0; i < 9; i++) exp_pio[i] = 0;
    while (!$feof(fd)) begin
      if ($fgets(line, fd) == 0) break;
      if (line.len() < 2 || line[0] == "#") continue;
      case (line[0])
        "I": begin
          if (have_rec) run_record();
          else drain_events();                 // resets / PIO before the first instruction
          n = $sscanf(line, "I %d %h %h", n1, v1, v2);
          rec_n = n1; rec_pc = v1[23:0]; rec_op = v2; have_rec = 1;
        end
        "R": begin n = $sscanf(line, "R %d %h", i1, v1); exp_r[i1] = v1; end
        "A": begin n = $sscanf(line, "A %d %h", i1, v64); exp_a[i1] = v64; end
        "F": begin n = $sscanf(line, "F %h %h %h %h", exp_nzc, exp_v, exp_vu, exp_nz); end
        "P": begin
          if (line[1] == "W") begin ev_t e; n = $sscanf(line, "PW %d %d %h", n1, i1, v1); e.kind = 0; e.reg_ = i1; e.data = v1[15:0]; events.push_back(e); end
          else if (line[1] == "R") begin ev_t e; n = $sscanf(line, "PR %d %d %h", n1, i1, v1); e.kind = 1; e.reg_ = i1; e.data = v1[15:0]; events.push_back(e); end
          else begin
            n = $sscanf(line, "P %h %h %h %h %h %h %h %h %h", p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8]);
            for (int i = 0; i < 9; i++) exp_pio[i] = p[i];
          end
        end
        "L": begin n = $sscanf(line, "L %d", exp_lastp); end
        "W": begin wr_t w; n = $sscanf(line, "W %d %h %h", i1, v1, v2); w.size = i1; w.addr = v1[23:0]; w.data = v2; exp_writes.push_back(w); end
        "X": begin ev_t e; e.kind = 2; e.reg_ = 0; e.data = 0; events.push_back(e); end
        "M": ;
        default: ;
      endcase
    end
    if (have_rec) run_record();
    $display("tb_dsp32: %0d instructions checked, %0d memory writes, %0d PIO reads, %0d mismatches",
             checked, writes_checked, pio_checked, mismatches);
    $finish;
  end
endmodule
