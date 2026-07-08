# ============================================================================
# attn_soc.xdc — KV260 Attention Accelerator Constraints
# ============================================================================
# Target: Kria KV260 (XCK26-SFVC784-2LV-I, K26 SOM)
# Clock: PS-generated pl_clk0 (100 MHz typical, configurable up to 250 MHz)
#
# KV260 Notes:
#   - NO dedicated PL fabric clock on carrier card
#   - Must use PS-to-PL clocks from Zynq UltraScale+ MPSoC
#   - PL I/O: PMOD, RPi header, IAS (MIPI), Ethernet, fan, etc.
#   - Our design uses PS-PL AXI interfaces only → minimal external I/O
# ============================================================================

# ==================================================================
# Clock Constraints
# ==================================================================
# Primary clock: PS-to-PL pl_clk0 (100 MHz default)
create_clock -period 10.000 -name pl_clk0 [get_ports pl_clk0]

# Target: 200 MHz with MAC_PIPE_STAGES=2
# If timing fails at 200 MHz, reduce to 150 MHz or increase pipeline depth
# create_clock -period 5.000 -name pl_clk0 [get_ports pl_clk0]  # 200 MHz target

# ==================================================================
# Reset
# ==================================================================
set_property PACKAGE_PIN H13 [get_ports pl_resetn0]
set_property IOSTANDARD LVCMOS18 [get_ports pl_resetn0]

# ==================================================================
# Timing Exceptions
# ==================================================================
# False paths: AXI4-Lite CSR registers (async to host CPU clock)
set_clock_groups -asynchronous \
    -group [get_clocks pl_clk0] \
    -group [get_clocks -include_generated_clocks]

# Multi-cycle path: MAC pipeline (2-stage)
# Stage1→Stage2: 2 cycles allowed with MAC_PIPE_STAGES=2
set_multicycle_path -setup 2 -from [get_cells u_mac/GEN_PIPE/*] \
    -to [get_cells u_mac/STAGE2_REDUCE/*]
set_multicycle_path -hold  1 -from [get_cells u_mac/GEN_PIPE/*] \
    -to [get_cells u_mac/STAGE2_REDUCE/*]

# ==================================================================
# Input/Output Delay (AXI4-Stream interfaces)
# ==================================================================
# S_AXIS (DDR→PL): data arrives from PS DDR via DMA
set_input_delay -clock pl_clk0 -max 2.0 [get_ports {s_axis_tdata[*] s_axis_tvalid s_axis_tlast}]
set_input_delay -clock pl_clk0 -min 0.5 [get_ports {s_axis_tdata[*] s_axis_tvalid s_axis_tlast}]

# M_AXIS (PL→DDR): data sent to PS DDR via DMA
set_output_delay -clock pl_clk0 -max 2.0 [get_ports {m_axis_tdata[*] m_axis_tvalid m_axis_tlast}]
set_output_delay -clock pl_clk0 -min 0.5 [get_ports {m_axis_tdata[*] m_axis_tvalid m_axis_tlast}]

# ==================================================================
# Physical Constraints
# ==================================================================
# AXI4-Lite interface — PS M_AXI_GP0 (fixed routing, no pin constraints needed)
# AXI4-Stream interfaces — PS S_AXI_HP0_FPD / M_AXI_HPM0_FPD (fixed routing)

# ==================================================================
# Synthesis Strategy
# ==================================================================
# DSP48E2: prefer inference over instantiation
set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]

# BRAM/URAM inference
set_property STEPS.SYNTH_DESIGN.ARGS.FSM_EXTRACTION one_hot [get_runs synth_1]

# ==================================================================
# Placement
# ==================================================================
# Keep MAC PE array together for timing
# set_property BLOCK_RAM_PROPERTY {URAM} [get_cells u_kcache/*]
# set_property BLOCK_RAM_PROPERTY {URAM} [get_cells u_vcache/*]

# ==================================================================
# Report
# ==================================================================
# Run after implementation:
# report_timing_summary -file timing_summary.rpt
# report_utilization -file utilization.rpt
# report_power -file power.rpt
