derive_pll_clocks
derive_clock_uncertainty

# The MiSTer framework constraint predates this core's PLL hierarchy and its
# wildcard does not match u_milestone/u_pll. The native core clocks cross into
# the stock OSD/video framework, LED plumbing, and HPS reset controls through
# deliberate asynchronous interfaces. Keep those framework clocks out of the
# core timing reports. The core clocks are split from one another below.
set_clock_groups -asynchronous \
  -group [get_clocks {*u_milestone*u_pll*u_pll*general[*]*divclk}] \
  -group [get_clocks {FPGA_CLK1_50}] \
  -group [get_clocks {FPGA_CLK2_50}] \
  -group [get_clocks {FPGA_CLK3_50}] \
  -group [get_clocks {*h2f_user0_clk}] \
  -group [get_clocks {*pll_audio*divclk}] \
  -group [get_clocks {*pll_hdmi*divclk}]

# The original Compact board uses independent 48 MHz GSP and 50 MHz MSP
# oscillators.  Preserve that domain boundary even though the FPGA derives
# both clocks from one PLL.  The 100 MHz memory and 6 MHz video domains are
# independent too; their crossings use explicit mailboxes/synchronizers.
set_clock_groups -asynchronous \
  -group [get_clocks {*u_milestone*u_pll*u_pll*general[0]*divclk}] \
  -group [get_clocks {*u_milestone*u_pll*u_pll*general[1]*divclk}] \
  -group [get_clocks {*u_milestone*u_pll*u_pll*general[2]*divclk}] \
  -group [get_clocks {*u_milestone*u_pll*u_pll*general[3]*divclk}]

# Carry the reusable TMS34010 core's documented timing contract into both
# GSP/MSP instances. Opcode decode and the listed state-driven register-file
# paths are architecturally separated by explicit quiet/acknowledge states;
# these are the same narrow exceptions used by the component's standalone
# Cyclone V sign-off, not blanket paths through the core.
set tms_opcode_sources [get_registers {*|u_core|instr_word_q*}]
set tms_decode_dests [get_registers {*|u_core|decoded*}]
set tms_regfile_dests [get_registers {*|u_regfile|*}]
set_multicycle_path -setup -end 2 \
  -from $tms_opcode_sources -to $tms_decode_dests
set_multicycle_path -hold -end 1 \
  -from $tms_opcode_sources -to $tms_decode_dests
set_multicycle_path -setup -end 2 \
  -from $tms_decode_dests -to $tms_regfile_dests
set_multicycle_path -hold -end 1 \
  -from $tms_decode_dests -to $tms_regfile_dests

# A decoded transaction cannot reach the memory-fabric ingress in the same
# cycle.  Non-immediate instructions cross CORE_DISPATCH and CORE_EXECUTE
# before CORE_MEMORY asserts mem_req; immediate fetches cross CORE_DISPATCH
# before their first request.  The ingress registers capture the complete
# held command, and the arbiter owner can select it only on a later edge.
# Constrain only those request-capture registers; memory responses and core
# consumers retain normal single-cycle analysis.  The raw two-word on-chip
# I/O view is captured with the same held request at mem_req, before the
# fabric can acknowledge it, and is aligned only from registered operands.
set tms_memory_request_dests [get_registers \
  {*|u_memory_fabric|cpu_request_* \
   *|u_memory_fabric|u_arbiter|state_q* \
   *|u_core|io_request_wdata_q* \
   *|u_core|io_rdata_words_q* \
   *|u_core|io_is_io_q* \
   *|u_core|io_access_addr_q* \
   *|u_core|io_request_size_q* \
   *|u_core|io_next_addr_q*}]
set_multicycle_path -setup -end 2 \
  -from $tms_decode_dests -to $tms_memory_request_dests
set_multicycle_path -hold -end 1 \
  -from $tms_decode_dests -to $tms_memory_request_dests

# FILL's private row base cannot sample decoded instruction fields until the
# edge after both CORE_DISPATCH and CORE_EXECUTE. `decoded` is written only
# when leaving CORE_DECODE_WAIT and remains held for the entire instruction,
# so this is an explicit two-cycle datapath in both reused instances.
# The field sequencer latches a request's address, size and data in the
# cycle after the core's request register goes active, itself a cycle after
# decoded was captured (CORE_DECODE_WAIT), so decoded -> sequencer is two
# cycles by the same argument as the request registers above.
set tms_field_seq_dests [get_registers {*|u_memory_fabric|u_field_sequencer|*}]
set_multicycle_path -setup -end 2 \
  -from $tms_decode_dests -to $tms_field_seq_dests
set_multicycle_path -hold -end 1 \
  -from $tms_decode_dests -to $tms_field_seq_dests
# Registers loaded only in CORE_EXECUTE (or by the divider, started from
# CORE_EXECUTE): decoded is captured at the end of CORE_DECODE_WAIT and
# CORE_DISPATCH always sits between, so these capture two or more cycles
# after it changes.
set tms_execute_dests [get_registers \
  {*|u_core|execute_wb_data_q* \
   *|u_core|m2m_dst_new_q* \
   *|u_core|mv_addr_q* \
   *|u_core|mv_store_data_q* \
   *|u_core|m2m_src_addr_q* \
   *|u_core|m2m_dst_addr_q* \
   *|u_core|mm_rp_q* \
   *|u_core|mm_mask_q* \
   *|u_core|mm_mask_idx_q* \
   *|u_core|u_divider|*}]
set_multicycle_path -setup -end 2 \
  -from $tms_decode_dests -to $tms_execute_dests
set_multicycle_path -hold -end 1 \
  -from $tms_decode_dests -to $tms_execute_dests
# harddrivin_gsp_memory accepts a request, or serves it from a cache, only
# once it has been presented for a full cycle (req_stable_q), so every path
# from the GSP system's registers (the memory fabric's request registers,
# the field sequencer, the host interface) into the registers written on
# accept or hit is two cycles.  Excluded: the cache tag reads, which look up
# every cycle; the local (palette / control / scroll) path, which has no
# such rule; the diagnostics; and req_stable_q itself.
set gsp_mem_all  [get_registers {*|u_gsp_memory|*}]
set gsp_mem_1cyc [get_registers \
  {*|u_gsp_memory|*tag_rd_idx_q* *|u_gsp_memory|*tag_rd_q* *|u_gsp_memory|*tag_ram* \
   *|u_gsp_memory|req_stable_q* \
   *|u_gsp_memory|local_* *|u_gsp_memory|peripheral_* *|u_gsp_memory|palette_* \
   *|u_gsp_memory|control_* *|u_gsp_memory|scroll_latch_q* *|u_gsp_memory|fine_scroll_o* \
   *|u_gsp_memory|shiftreg_enable_o* *|u_gsp_memory|last_palette_* *|u_gsp_memory|color_pair_q* \
   *|u_gsp_memory|srt_wait_* *|u_gsp_memory|*_count_o* *|u_gsp_memory|*_seen_o* \
   *|u_gsp_memory|*_trace_o* *|u_gsp_memory|instruction_fetch_seen_o*}]
set gsp_mem_accept_dests [remove_from_collection $gsp_mem_all $gsp_mem_1cyc]
set gsp_req_sources [get_registers {*|u_gsp|* *|u_cockpit_expander|*}]
set_multicycle_path -setup -end 2 -from $gsp_req_sources -to $gsp_mem_accept_dests
set_multicycle_path -hold -end 1 -from $gsp_req_sources -to $gsp_mem_accept_dests
# The core takes a request's read data and completion only on the fabric's
# acknowledge, which tb_core measured never earlier than two cycles after
# the request registers load (5.6M acknowledges over 5.5 s of boot, minimum
# age 2), so the request registers' data (not the active flag, which is on
# the acknowledge path itself) -> core is two cycles.
set tms_request_data_regs [get_registers \
  {*|u_memory_fabric|cpu_request_addr_q* *|u_memory_fabric|cpu_request_size_q* \
   *|u_memory_fabric|cpu_request_wdata_q* *|u_memory_fabric|cpu_request_we_q* \
   *|u_memory_fabric|cpu_request_io_we_raw_q* *|u_memory_fabric|cpu_request_iaq_q* \
   *|u_memory_fabric|cpu_request_srt_raw_q* *|u_memory_fabric|cpu_request_io_rdata_q*}]
set_multicycle_path -setup -end 2 \
  -from $tms_request_data_regs -to [get_registers {*|u_gsp|u_tms34010|u_core|*}]
set_multicycle_path -hold -end 1 \
  -from $tms_request_data_regs -to [get_registers {*|u_gsp|u_tms34010|u_core|*}]
set tms_fill_row_base_dests [get_registers {*|u_core|fill_row_base_q*}]
set_multicycle_path -setup -end 2 \
  -from $tms_decode_dests -to $tms_fill_row_base_dests
set_multicycle_path -hold -end 1 \
  -from $tms_decode_dests -to $tms_fill_row_base_dests

# A decoded branch/call/return cannot load the program counter until
# CORE_WRITEBACK, after complete CORE_DISPATCH and CORE_EXECUTE cycles.
# FETCH/FETCH_IMM increment the PC from fetch state and memory acknowledge,
# not from decoded instruction data.  Two cycles is therefore conservative.
set tms_pc_dests [get_registers {*|u_pc|pc_q*}]
set_multicycle_path -setup -end 2 \
  -from $tms_decode_dests -to $tms_pc_dests
set_multicycle_path -hold -end 1 \
  -from $tms_decode_dests -to $tms_pc_dests

set tms_graphics_read_only_states [get_registers \
  {*|u_core|state_q.CORE_FILL_SETUP* \
   *|u_core|state_q.CORE_PBLT_SETUP* \
   *|u_core|state_q.CORE_DRAV* \
   *|u_core|state_q.CORE_LINE_SETUP* \
   *|u_core|state_q.CORE_PIXT_SETUP_WIN*}]
set_false_path -from $tms_graphics_read_only_states -to $tms_regfile_dests

set tms_memory_states [get_registers {*|u_core|state_q.CORE_MEMORY*}]
set_multicycle_path -setup -end 2 \
  -from $tms_memory_states -to $tms_regfile_dests
set_multicycle_path -hold -end 1 \
  -from $tms_memory_states -to $tms_regfile_dests

set tms_mm_mask_sources [get_registers {*|u_core|mm_mask_q*}]
set_multicycle_path -setup -end 2 \
  -from $tms_mm_mask_sources -to $tms_regfile_dests
set_multicycle_path -hold -end 1 \
  -from $tms_mm_mask_sources -to $tms_regfile_dests

# MMTM/MMFM use the same mask to decide whether an acknowledged word returns
# to CORE_MEMORY or advances to CORE_WRITEBACK.  Neither state changes the PC;
# the earliest PC advance is a later CORE_FETCH acknowledgement.  Preserve
# that explicit quiet cycle when Quartus folds the state/data muxes together.
set_multicycle_path -setup -end 2 \
  -from $tms_mm_mask_sources -to $tms_pc_dests
set_multicycle_path -hold -end 1 \
  -from $tms_mm_mask_sources -to $tms_pc_dests

# b123 slow/hot STA: osd_de[2] -> osd_mux failed by 0.030 ns;
# 5.686 ns of its 6.034 ns data path was routing. Tighten this existing
# single-cycle path (HDMI period 6.732 ns) so placement shortens the wire.
# This changes neither pipeline latency nor clock/hold exceptions.
# Quartus automatically includes ~DUPLICATE registers for each exact RTL
# endpoint. Constrain every such copy and fail if either endpoint is absent.
set hd_osd_de2 [get_registers {hdmi_osd|osd_de[2]}]
set hd_osd_mux [get_registers {hdmi_osd|osd_mux}]
if {[get_collection_size $hd_osd_de2] < 1 || [get_collection_size $hd_osd_mux] < 1} {
  error "OSD route constraint must match both RTL endpoints, including fitter duplicates"
}
set_max_delay -from $hd_osd_de2 -to $hd_osd_mux 5.000

# The 68010 (TG68K) advances on a one-in-MAIN_CPU_DIV clock enable (18 at
# 48 MHz, harddrivin_milestone main_cpu_ce): every register inside it,
# including its inferred register-file RAM, captures only on that pulse, so
# register-to-register paths within it have at least 18 clocks.  Two is
# enough for the ALU and register-file paths (-2.9 ns at one).  Paths into
# and out of the CPU keep the single-cycle requirement.
set tg68k_regs [get_registers {*|u_main_68010|*}]
set_multicycle_path -setup -end 2 -from $tg68k_regs -to $tg68k_regs
set_multicycle_path -hold -end 1 -from $tg68k_regs -to $tg68k_regs
