set PROJ_NAME  "lara_attention"
set PART       "xck26-sfvc784-2LV-c"
set BOARD_SOM  "xilinx.com:kv260_som:part0:1.2"
set FCLK_MHZ   100
set N_JOBS     4
set HW_DIR     "hw"
set OUT_DIR    "vivado_proj"

create_project ${PROJ_NAME} ./${OUT_DIR} -part ${PART} -force
set_property board_part ${BOARD_SOM} [current_project]
set_property target_language Verilog [current_project]

# Add all RTL (14 source files + 1 wrapper for BD)
set rtl [list \
    ${HW_DIR}/rtl/pkg/attn_pkg.sv \
    ${HW_DIR}/rtl/core/bf16_mac.sv \
    ${HW_DIR}/rtl/core/attn_tile.sv \
    ${HW_DIR}/rtl/core/softmax_engine.sv \
    ${HW_DIR}/rtl/core/psum_accum.sv \
    ${HW_DIR}/rtl/core/attn_core.sv \
    ${HW_DIR}/rtl/core/rope_engine.sv \
    ${HW_DIR}/rtl/mem/kv_cache_ram.sv \
    ${HW_DIR}/rtl/mem/tile_buffer.sv \
    ${HW_DIR}/rtl/mem/output_buffer.sv \
    ${HW_DIR}/rtl/axi/attn_axi_lite_slave.sv \
    ${HW_DIR}/rtl/axi/attn_axi_stream_sink.sv \
    ${HW_DIR}/rtl/axi/attn_axi_stream_source.sv \
    ${HW_DIR}/rtl/attn_top.sv \
    ${HW_DIR}/rtl/attn_top_wrapper.v \
]
add_files -norecurse ${rtl}
add_files -fileset constrs_1 -norecurse ${HW_DIR}/constraints/attn_soc.xdc
set_property file_type SystemVerilog [get_files *.sv]
update_compile_order -fileset sources_1
puts "INFO: Added [llength ${rtl}] RTL files."

# BD
create_bd_design "attn_soc"
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 ps8
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset 1} [get_bd_cells ps8]
set_property -dict [list \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $FCLK_MHZ \
    CONFIG.PSU__USE__M_AXI_GP0 {1} CONFIG.PSU__USE__M_AXI_GP1 {1} \
    CONFIG.PSU__USE__S_AXI_GP2 {1} CONFIG.PSU__USE__S_AXI_GP3 {1} \
] [get_bd_cells ps8]

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_gen
connect_bd_net [get_bd_pins ps8/pl_clk0] [get_bd_pins rst_gen/slowest_sync_clk]
connect_bd_net [get_bd_pins ps8/pl_resetn0] [get_bd_pins rst_gen/ext_reset_in]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma
set_property -dict [list CONFIG.c_include_sg {0} CONFIG.c_include_s2mm {1} \
    CONFIG.c_m_axis_mm2s_tdata_width {32} CONFIG.c_s_axis_s2mm_tdata_width {32} \
    CONFIG.c_mm2s_burst_size {16}] [get_bd_cells axi_dma]

create_bd_cell -type module -reference attn_top_wrapper accel

# AXI auto-connect
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master {/ps8/pl_clk0} Clk_slave Auto Clk_xbar Auto \
    Master {/ps8/M_AXI_HPM0_FPD} Slave {/accel/s_axi} \
    ddr_seg Auto intc_ip {New AXI Interconnect} master_apm 0] [get_bd_intf_pins accel/s_axi]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master {/ps8/pl_clk0} Clk_slave Auto Clk_xbar Auto \
    Master {/ps8/M_AXI_HPM1_FPD} Slave {/axi_dma/S_AXI_LITE} \
    ddr_seg Auto intc_ip Auto master_apm 0] [get_bd_intf_pins axi_dma/S_AXI_LITE]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master {/ps8/pl_clk0} Clk_slave Auto Clk_xbar Auto \
    Master {/axi_dma/M_AXI_MM2S} Slave {/ps8/S_AXI_HP0_FPD} \
    ddr_seg Auto intc_ip {New AXI Interconnect} master_apm 0] [get_bd_intf_pins ps8/S_AXI_HP0_FPD]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master {/ps8/pl_clk0} Clk_slave Auto Clk_xbar Auto \
    Master {/axi_dma/M_AXI_S2MM} Slave {/ps8/S_AXI_HP1_FPD} \
    ddr_seg Auto intc_ip Auto master_apm 0] [get_bd_intf_pins ps8/S_AXI_HP1_FPD]

connect_bd_intf_net [get_bd_intf_pins axi_dma/M_AXIS_MM2S] [get_bd_intf_pins accel/s_axis]
connect_bd_intf_net [get_bd_intf_pins accel/m_axis] [get_bd_intf_pins axi_dma/S_AXIS_S2MM]
connect_bd_net [get_bd_pins rst_gen/peripheral_aresetn] [get_bd_pins accel/rst_n]

validate_bd_design
save_bd_design
set bd_file [get_files ${PROJ_NAME}.srcs/sources_1/bd/attn_soc/attn_soc.bd]
generate_target all $bd_file
make_wrapper -files $bd_file -top
update_compile_order -fileset sources_1

# UCIO-1 waiver (internal PS-PL AXI ports, not physical I/O)
set_property STEPS.WRITE_BITSTREAM.TCL.PRE [file normalize ${HW_DIR}/scripts/pre_bitstream.tcl] [get_runs impl_1]

puts "INFO: Starting synthesis+implementation..."
launch_runs synth_1 -jobs ${N_JOBS}; wait_on_run synth_1
puts "INFO: Synthesis done."
launch_runs impl_1 -jobs ${N_JOBS}; wait_on_run impl_1
# Bitstream: route_design passes, skip UCIO-1 DRC for internal PS-PL ports
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
launch_runs impl_1 -to_step write_bitstream -jobs ${N_JOBS}

file mkdir ${OUT_DIR}/deploy
file copy -force ${OUT_DIR}/${PROJ_NAME}.runs/impl_1/attn_soc_wrapper.bit ${OUT_DIR}/deploy/lara_attention.bit
write_hw_platform -fixed -include_bit -file ${OUT_DIR}/deploy/lara_attention.xsa
puts "============================================================"
puts " BUILD COMPLETE — ${OUT_DIR}/deploy/lara_attention.bit"
puts "============================================================"
