# ============================================================================
# attn_soc.xdc — KV260 Attention Accelerator Constraints
# ============================================================================
# Target: Kria KV260 (XCK26-SFVC784-2LV-I, K26 SOM)
#
# KV260 Clock Architecture (from UG1089 / DS986):
#   - NO dedicated PL fabric clock on carrier card
#   - Primary clock: PS-generated pl_clk0 (100 MHz default)
#   - PS-PL AXI interfaces: HPM0_FPD, HPM1_FPD, HP0_FPD, HP1_FPD (fixed routing)
#
# Reference:
#   - DS987: K26 SOM Data Sheet
#   - UG1091: Kria SOM Carrier Card Design Guide
#   - UG1089: KV260 Starter Kit User Guide
#   - XTP686: KV260 Carrier Card XDC (via XilinxBoardStore)
# ============================================================================

# ==================================================================
# Clock Constraints
# ==================================================================
# Primary clock: PS-to-PL pl_clk0 (100 MHz default, configurable to 250 MHz)
create_clock -period 10.000 -name pl_clk0 [get_ports pl_clk0]

# ==================================================================
# Reset
# ==================================================================
# PS-PL reset: pl_resetn0 from Zynq UltraScale+ PS
# Active-low, asynchronous assertion, synchronous deassertion via proc_sys_reset
set_property PACKAGE_PIN H13 [get_ports pl_resetn0]
set_property IOSTANDARD LVCMOS18 [get_ports pl_resetn0]

# ==================================================================
# Clock Groups — PS-PL async
# ==================================================================
set_clock_groups -asynchronous \
    -group [get_clocks pl_clk0] \
    -group [get_clocks -include_generated_clocks]

# ==================================================================
# Input/Output Delay — AXI4-Stream (PS DMA ↔ PL Accelerator)
# ==================================================================
# S_AXIS: DDR→PL data, clocked by pl_clk0
set_input_delay -clock pl_clk0 -max 2.0 [get_ports {s_axis_tdata[*] s_axis_tvalid s_axis_tlast}]
set_input_delay -clock pl_clk0 -min 0.5 [get_ports {s_axis_tdata[*] s_axis_tvalid s_axis_tlast}]
set_output_delay -clock pl_clk0 -max 2.0 [get_ports s_axis_tready]

# M_AXIS: PL→DDR data, clocked by pl_clk0
set_output_delay -clock pl_clk0 -max 2.0 [get_ports {m_axis_tdata[*] m_axis_tvalid m_axis_tlast}]
set_output_delay -clock pl_clk0 -min 0.5 [get_ports {m_axis_tdata[*] m_axis_tvalid m_axis_tlast}]
set_input_delay -clock pl_clk0 -max 2.0 [get_ports m_axis_tready]

# AXI4-Lite: PS↔PL CSR, async to pl_clk0 — handled by clock groups above
# No explicit I/O delay needed (AXI interconnect manages CDC)

# ==================================================================
# Timing Exceptions
# ==================================================================
# Multi-cycle path: MAC 2-stage pipeline
# Stage 1 (multiply) → Stage 2 (reduction): 2 cycles
set_multicycle_path -setup 2 \
    -from [get_cells -hier -filter {NAME =~ "*GEN_PIPE*"}] \
    -to   [get_cells -hier -filter {NAME =~ "*STAGE2*"}]
set_multicycle_path -hold  1 \
    -from [get_cells -hier -filter {NAME =~ "*GEN_PIPE*"}] \
    -to   [get_cells -hier -filter {NAME =~ "*STAGE2*"}]

# False path: AXI4-Lite CSR registers (async to PS clock domain)
set_false_path -from [get_ports s_axi_*] -to [get_cells -hier -filter {NAME =~ "*u_csr*"}]

# ==================================================================
# Synthesis Strategy
# ==================================================================
# DSP48E2: prefer inference
set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]

# BRAM/URAM inference — see UG1091 § Memory Resources
# kv_cache_ram targets URAM (288Kb blocks, K26 has 64)
# tile_buffer targets BRAM (36Kb blocks, K26 has 144)
# Output: Vivado automatically infers BRAM from (* ram_style = "block" *) in RTL

# ==================================================================
# Report
# ==================================================================
# After implementation, run:
#   report_timing_summary -file timing_summary.rpt
#   report_utilization -file utilization.rpt
#   report_power -file power.rpt
