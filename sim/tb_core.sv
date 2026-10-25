// Whole-core simulation testbench: the board-level top (harddrivin_milestone)
// with behavioural DDR and SDRAM, ROM images from tools/romimage.py, and a
// 68010 bus trace for comparison with MAME.
//
// Plusargs:
//   +ddr=<file>      DDR image (MRA index 0 bytes)            default ddr.bin
//   +snd=<file>      sound 68000 EPROM image (index 1)        default index1.bin
//   +trace=<file>    68010 bus trace output                    default none
//   +ms=<n>          emulated milliseconds to run              default 100
//   +service=1       hold the self-test switch on
//   +vcd=<file>      waveform dump (slow; needs --trace at build)
//
// ZRAM power-up images come in through the ZRAM_HI_FILE / ZRAM_LO_FILE macros
// at build time (the core takes them as parameters).
`timescale 1ps/1ps
module tb_core;
`ifndef ZRAM_HI_FILE
  `define ZRAM_HI_FILE "zram_hi.hex"
`endif
`ifndef ZRAM_LO_FILE
  `define ZRAM_LO_FILE "zram_lo.hex"
`endif
  localparam bit COCKPIT = 1;

  logic clk50 = 0;
  always #10000 clk50 = ~clk50;   // 50 MHz
  logic rst = 1;

  // ---- core ports --------------------------------------------------------
  logic        ce_pix, hblank, vblank, hsync, vsync;
  logic [23:0] rgb;
  logic [31:0] debug;
  logic        clk_core;
  logic        snd_wr = 0;
  logic [14:0] snd_addr = 0;
  logic [15:0] snd_data = 0;
  logic        nvram_ack, nvram_dirty;
  logic [7:0]  nvram_rdata;
  logic        pot_prompt, brake_cal, shifter_cal, seat_cal, cal_active;
  logic signed [15:0] audio;

  logic service = 0;
  logic coin1 = 0, coin2 = 0;
  logic [7:0] sw1 = 8'hFF;
  logic diag_jumper = 1'b1;
  logic [15:0] compact_port1 = 16'hFFFF;
  logic [7:0]  accelerator = 8'h00, clutch = 8'h00, seat = 8'h80;
  logic [7:0]  shifter_x = 8'h80, shifter_y = 8'h80, brake = 8'hF0;
  logic [11:0] steering = 12'h800, brake12 = 12'hFFF;

  // DDR
  logic        ddr_busy, ddr_rd, ddr_we, ddr_ready;
  logic [7:0]  ddr_burst, ddr_be;
  logic [28:0] ddr_addr;
  logic [63:0] ddr_dout, ddr_din;
  // SDRAM
  wire  [15:0] sdram_dq;
  logic [12:0] sdram_a;
  logic [1:0]  sdram_ba;
  logic sdram_clk, sdram_cke, sdram_dqml, sdram_dqmh, sdram_ncs, sdram_ncas, sdram_nras, sdram_nwe;

  harddrivin_milestone #(
    .COCKPIT(COCKPIT),
    .MSP(1'b0),          // Race Drivin' has no MSP
    .DIAG_FULL(1'b0),
    .ZERO_RAM_INIT_HI_FILE(`ZRAM_HI_FILE),
    .ZERO_RAM_INIT_LO_FILE(`ZRAM_LO_FILE)
  ) u_core (
    .clk_50_i(clk50), .rst_i(rst), .clk_core_o(clk_core), .ce_pix_o(ce_pix),
    .hblank_o(hblank), .vblank_o(vblank), .hsync_o(hsync), .vsync_o(vsync),
    .rgb_o(rgb), .debug_o(debug),
    .diagnostic_enable_i(1'b0), .controls_overlay_i(1'b0),
    .analog_axes_i(32'h80808080), .axis_moved_i(4'd0),
    .snd_rom_wr_clk_i(clk50), .snd_rom_wr_en_i(snd_wr),
    .snd_rom_wr_addr_i(snd_addr), .snd_rom_wr_data_i(snd_data),
    .nvram_req_i(1'b0), .nvram_we_i(1'b0), .nvram_addr_i(12'd0), .nvram_wdata_i(8'd0),
    .nvram_ack_o(nvram_ack), .nvram_rdata_o(nvram_rdata), .nvram_dirty_o(nvram_dirty),
    .pot_prompt_active_o(pot_prompt), .brake_calibration_active_o(brake_cal),
    .shifter_calibration_active_o(shifter_cal), .seat_calibration_active_o(seat_cal),
    .calibration_active_o(cal_active),
    .coin1_i(coin1), .coin2_i(coin2), .service_i(service), .diag_jumper_i(diag_jumper),
    .sw1_i(sw1), .compact_port1_i(compact_port1),
    .accelerator_i(accelerator), .clutch_i(clutch), .seat_i(seat),
    .shifter_x_i(shifter_x), .shifter_y_i(shifter_y), .brake_i(brake),
    .steering_i(steering), .brake12_i(brake12), .audio_o(audio),
    .DDRAM_BUSY(ddr_busy), .DDRAM_BURSTCNT(ddr_burst), .DDRAM_ADDR(ddr_addr),
    .DDRAM_DOUT(ddr_dout), .DDRAM_DOUT_READY(ddr_ready), .DDRAM_RD(ddr_rd),
    .DDRAM_DIN(ddr_din), .DDRAM_BE(ddr_be), .DDRAM_WE(ddr_we),
    .SDRAM_DQ(sdram_dq), .SDRAM_A(sdram_a), .SDRAM_BA(sdram_ba), .SDRAM_CLK(sdram_clk),
    .SDRAM_CKE(sdram_cke), .SDRAM_DQML(sdram_dqml), .SDRAM_DQMH(sdram_dqmh),
    .SDRAM_nCS(sdram_ncs), .SDRAM_nCAS(sdram_ncas), .SDRAM_nRAS(sdram_nras), .SDRAM_nWE(sdram_nwe)
  );

  sim_ddr #(.LATENCY(6), .RANDOM_BUSY(1)) u_ddr (
    .clk(clk_core), .rst(rst),
    .DDRAM_BUSY(ddr_busy), .DDRAM_BURSTCNT(ddr_burst), .DDRAM_ADDR(ddr_addr),
    .DDRAM_DOUT(ddr_dout), .DDRAM_DOUT_READY(ddr_ready), .DDRAM_RD(ddr_rd),
    .DDRAM_DIN(ddr_din), .DDRAM_BE(ddr_be), .DDRAM_WE(ddr_we)
  );

  sim_sdram u_sdram (
    .clk(sdram_clk), .cke(sdram_cke), .cs_n(sdram_ncs), .ras_n(sdram_nras), .cas_n(sdram_ncas),
    .we_n(sdram_nwe), .ba(sdram_ba), .a(sdram_a), .dqml(sdram_dqml), .dqmh(sdram_dqmh), .dq(sdram_dq)
  );

  // ---- sound EPROM download, then release reset --------------------------
  logic [7:0] snd_bytes [0:65535];
  initial begin
    string snd_file = "index1.bin";
    int fd, n;
    void'($value$plusargs("snd=%s", snd_file));
    if ($test$plusargs("service")) service = 1;
    fd = $fopen(snd_file, "rb");
    if (fd == 0) begin $display("tb_core: cannot open %s", snd_file); $finish; end
    n = $fread(snd_bytes, fd);
    $fclose(fd);
    $display("tb_core: sound EPROM image %s (%0d bytes)", snd_file, n);
    repeat (20) @(posedge clk50);
    for (int i = 0; i < 32768; i++) begin
      @(posedge clk50);
      snd_addr <= 15'(i);
      snd_data <= {snd_bytes[2 * i], snd_bytes[2 * i + 1]};
      snd_wr   <= 1;
    end
    @(posedge clk50) snd_wr <= 0;
    repeat (100) @(posedge clk50);
    rst <= 0;
    $display("tb_core: reset released at %t", $time);
  end

  // ---- 68010 bus trace ---------------------------------------------------
  // One line per enabled bus step of the main CPU, from the board top's
  // internal signals: kind (F fetch, R read, W write, I idle), 24-bit
  // address, data, byte strobes. Consecutive duplicates are dropped.
  int trace_fd = 0;
  logic [31:0] last_addr = 'x;
  logic [1:0]  last_state = 'x;
  logic        last_nwr = 'x;
  longint      bus_steps = 0, fetches = 0, writes = 0;
  initial begin
    string trace_file;
    if ($value$plusargs("trace=%s", trace_file)) begin
      trace_fd = $fopen(trace_file, "w");
      $fdisplay(trace_fd, "# tb_core 68010 bus trace: time_ps kind addr data uds lds");
    end
  end
  always @(posedge u_core.clk_gsp) begin
    if (!rst && u_core.main_cpu_ce) begin
      bus_steps++;
      if (u_core.main_busstate != 2'b01 &&
          !(u_core.main_addr == last_addr && u_core.main_busstate == last_state && u_core.main_nwr == last_nwr)) begin
        string kind;
        logic [15:0] data;
        case (u_core.main_busstate)
          2'b00: begin kind = "F"; data = u_core.main_data_in; fetches++; end
          2'b10: begin kind = "R"; data = u_core.main_data_in; end
          default: begin kind = "W"; data = u_core.main_data_out; writes++; end
        endcase
        if (trace_fd != 0)
          $fdisplay(trace_fd, "%0t %s %06x %04x %0d %0d", $time, kind, u_core.main_addr[23:0], data,
                    !u_core.main_nuds, !u_core.main_nlds);
      end
      last_addr  <= u_core.main_addr;
      last_state <= u_core.main_busstate;
      last_nwr   <= u_core.main_nwr;
    end
  end

  // ---- progress, run length, waveforms -----------------------------------
  initial begin
    int ms = 100;
    string vcd_file;
    void'($value$plusargs("ms=%d", ms));
    if ($value$plusargs("vcd=%s", vcd_file)) begin
      $dumpfile(vcd_file);
      $dumpvars(0, tb_core);
    end
    for (int i = 1; i <= ms; i++) begin
      #1_000_000_000;  // 1 ms
      $display("t=%0d ms  68k steps %0d fetch %0d wr %0d addr %06x | gsp pc %08x st %0d | adsp pc %04x run %0d | ddr rd %0d | sdram rd %0d wr %0d | snd rst %0d",
               i, bus_steps, fetches, writes, last_addr[23:0],
               u_core.gsp_pc, u_core.gsp_state, u_core.adsp_pc, u_core.adsp_running,
               u_ddr.reads, u_sdram.reads, u_sdram.writes, u_core.u_sound_board.rst_i);
    end
    if (trace_fd != 0) $fclose(trace_fd);
    $display("tb_core: done, %0d ms, %0d bus steps", ms, bus_steps);
    $finish;
  end
endmodule
