# ============================================================================
# vivado_build.tcl — Vivado Project Builder for LARA Attention Accelerator
# ============================================================================
# Creates a Vivado project for KV260, instantiates all RTL modules,
# configures the Zynq MPSoC block design, and generates bitstream.
#
# Usage: vivado -mode batch -source hw/scripts/vivado_build.tcl
# ============================================================================

# --- Project Setup ---
set project_name "lara_attention"
set project_dir "./vivado_project"
set part "xck26-sfvc784-2lv-i"  ;# Kria K26 SOM

create_project $project_name $project_dir -part $part -force
set_property board_part xilinx.com:kv260:part0:1.2 [current_project]

# --- Add RTL Source Files ---
set rtl_dir "./hw/rtl"
add_files -fileset sources_1 -scan_for_includes $rtl_dir/pkg
add_files -fileset sources_1 [glob $rtl_dir/pkg/*.sv]
add_files -fileset sources_1 [glob $rtl_dir/core/*.sv]
add_files -fileset sources_1 [glob $rtl_dir/mem/*.sv]
add_files -fileset sources_1 [glob $rtl_dir/axi/*.sv]
add_files -fileset sources_1 [glob $rtl_dir/attn_top.v]

# Set SystemVerilog as default for .sv files
set_property file_type SystemVerilog [get_files -filter {FILE_TYPE == Verilog && NAME =~ "*.sv"}]

# Set Verilog type for .v files
set_property file_type Verilog [get_files *.v]

# --- Add Constraints ---
add_files -fileset constrs_1 ./hw/constraints/attn_soc.xdc

# --- Create Block Design (Zynq MPSoC) ---
create_bd_design "attn_soc"
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 zynq_ultra_ps_e_0

# Configure PS-PL clocks
set_property -dict [list \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__USE__S_AXI_HP0_FPD {1} \
    CONFIG.PSU__USE__S_AXI_HP1_FPD {1} \
] [get_bd_cells zynq_ultra_ps_e_0]

# --- Add AXI DMA ---
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0
set_property -dict [list \
    CONFIG.c_sg_length_width {26} \
    CONFIG.c_include_sg {0} \
    CONFIG.c_m_axi_mm2s_data_width {32} \
    CONFIG.c_m_axis_mm2s_tdata_width {32} \
] [get_bd_cells axi_dma_0]

# --- Add Attention Accelerator (our RTL) ---
create_bd_cell -type module -reference attn_top attn_accel_0

# --- AXI Interconnect ---
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_0
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_1

# --- AXI SmartConnect ---
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smartconnect_0

# --- Clock + Reset ---
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0

# --- Connect PS → DMA (AXI Lite) ---
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config {Master "/zynq_ultra_ps_e_0/M_AXI_HPM0_FPD" Clk "Auto"} [get_bd_intf_pins axi_dma_0/S_AXI_LITE]

# --- Connect PS → Accelerator (AXI Lite CSR) ---
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config {Master "/zynq_ultra_ps_e_0/M_AXI_HPM1_FPD" Clk "Auto"} [get_bd_intf_pins attn_accel_0/s_axi]

# --- Connect DMA MM2S → Accelerator Stream Sink ---
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] [get_bd_intf_pins attn_accel_0/s_axis]

# --- Connect Accelerator Stream Source → DMA S2MM ---
connect_bd_intf_net [get_bd_intf_pins attn_accel_0/m_axis] [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]

# --- Validate + Generate ---
validate_bd_design
save_bd_design
generate_target all [get_files *.bd]

# --- Synthesis + Implementation ---
launch_runs synth_1 -jobs 4
wait_on_run synth_1
launch_runs impl_1 -jobs 4
wait_on_run impl_1

# --- Generate Bitstream ---
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

# --- Export ---
write_hw_platform -fixed -include_bit -file lara_attention.xsa
puts "============================================"
puts " LARA Attention Accelerator: Build Complete"
puts " Bitstream: vivado_project/lara_attention.runs/impl_1/attn_soc_wrapper.bit"
puts " Hardware:  lara_attention.xsa"
puts "============================================"
