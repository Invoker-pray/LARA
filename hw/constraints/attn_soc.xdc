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
# Active constraints for the current BD flow
# ==================================================================
# This design is built around the generated KV260 block design:
#   - pl_clk0 / pl_resetn0 are internal PS pins
#   - AXI4-Lite and AXI4-Stream links are internal BD interfaces
#   - addressing and CDC are handled by the PS + AXI IP constraints
#
# Keep this XDC intentionally minimal and only constrain real top-level objects.
# Exploratory or conditional constraints belong in Tcl hooks, not in XDC.

# The deployable BD top receives pl_clk0 internally from the PS and inherits
# the generated PS/IP clock constraints. No external clock port exists here.

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
