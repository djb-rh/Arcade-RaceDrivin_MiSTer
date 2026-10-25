// Behavioural model of the MiSTer DDR3 service port used by the core.
//
// Holds the 2 MiB region at byte address 0x30000000 that MRA index 0 fills
// (loaded from ddr.bin at start) and answers DDRAM_RD bursts of 64-bit words
// with one DDRAM_DOUT_READY per word after a fixed latency. Writes are
// accepted and stored. DDRAM_BUSY can be pulsed pseudo-randomly to exercise
// the clients' hold-until-accepted logic.
`timescale 1ps/1ps
module sim_ddr #(
  parameter int LATENCY = 6,          // clocks from accepted read to first word
  parameter int RANDOM_BUSY = 1
) (
  input  logic        clk,
  input  logic        rst,
  output logic        DDRAM_BUSY,
  input  logic [7:0]  DDRAM_BURSTCNT,
  input  logic [28:0] DDRAM_ADDR,     // 64-bit word address
  output logic [63:0] DDRAM_DOUT,
  output logic        DDRAM_DOUT_READY,
  input  logic        DDRAM_RD,
  input  logic [63:0] DDRAM_DIN,
  input  logic [7:0]  DDRAM_BE,
  input  logic        DDRAM_WE
);
  localparam int WORDS = 1 << 18;                 // 2 MiB
  localparam logic [28:0] BASE = 29'h0600_0000;   // 0x30000000 >> 3
  logic [63:0] mem [0:WORDS - 1];

  int unsigned lfsr = 32'hACE1;
  int pending = 0;           // words still to deliver
  int countdown = 0;
  logic [28:0] cur_addr;
  int unsigned outside_reads = 0;
  longint reads = 0, write_count = 0;

  string image = "ddr.bin";   // +ddr=<file>
  initial begin
    int fd, n;
    void'($value$plusargs("ddr=%s", image));
    for (int i = 0; i < WORDS; i++) mem[i] = 64'hFFFF_FFFF_FFFF_FFFF;
    fd = $fopen(image, "rb");
    if (fd == 0) begin
      $display("sim_ddr: cannot open %s", image);
      $finish;
    end
    n = $fread(mem, fd);
    $fclose(fd);
    // $fread into a 64-bit array stores big-endian per element; the HPS wrote
    // the byte stream little-endian, so swap each word.
    for (int i = 0; i < WORDS; i++)
      mem[i] = {mem[i][7:0], mem[i][15:8], mem[i][23:16], mem[i][31:24],
                mem[i][39:32], mem[i][47:40], mem[i][55:48], mem[i][63:56]};
    $display("sim_ddr: loaded %0d bytes from %s", n, image);
  end

  function automatic logic in_range(input logic [28:0] a);
    return (a >= BASE) && (a < BASE + WORDS);
  endfunction

  always_ff @(posedge clk) begin
    lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
    DDRAM_DOUT_READY <= 0;
    if (rst) begin
      pending <= 0; countdown <= 0; DDRAM_BUSY <= 0;
    end else begin
      // busy while a burst is in flight, plus occasional random stalls
      DDRAM_BUSY <= (pending != 0) || (RANDOM_BUSY && (lfsr[3:0] == 0));
      if (DDRAM_RD && !DDRAM_BUSY && pending == 0) begin
        cur_addr  <= DDRAM_ADDR;
        pending   <= int'(DDRAM_BURSTCNT);
        countdown <= LATENCY;
        DDRAM_BUSY <= 1;
        reads++;
      end else if (DDRAM_WE && !DDRAM_BUSY) begin
        write_count++;
        if (in_range(DDRAM_ADDR))
          for (int b = 0; b < 8; b++)
            if (DDRAM_BE[b]) mem[DDRAM_ADDR - BASE][b * 8 +: 8] <= DDRAM_DIN[b * 8 +: 8];
      end
      if (pending != 0) begin
        if (countdown != 0) countdown <= countdown - 1;
        else begin
          if (in_range(cur_addr)) DDRAM_DOUT <= mem[cur_addr - BASE];
          else begin
            DDRAM_DOUT <= 64'd0;
            if (outside_reads < 10) $display("%t sim_ddr: read outside image at word %h", $time, cur_addr);
            outside_reads++;
          end
          DDRAM_DOUT_READY <= 1;
          cur_addr <= cur_addr + 1;
          pending  <= pending - 1;
        end
      end
    end
  end
endmodule
