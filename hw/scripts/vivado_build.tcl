set PROJ_NAME  "lara_attention"
set PART       "xck26-sfvc784-2LV-c"
set BOARD_SOM  "xilinx.com:kv260_som:part0:1.2"
# K26 PL0 uses integer clock division. The 76.923 MHz request resolved to
# 76.922310 MHz but missed post-route setup timing at WNS=-0.191 ns.
# set FCLK_MHZ   76.923
# Timing fallback: Vivado resolves this request to 71.427856 MHz
# (approximately 14.000 ns).
set FCLK_MHZ   72.000
set N_JOBS     1
set MAX_THREADS 1
set HW_DIR     "hw"
set OUT_DIR    "vivado_proj"
if {[info exists ::env(LARA_OUT_DIR)] &&
    ([string trim $::env(LARA_OUT_DIR)] ne "")} {
    set OUT_DIR [file normalize $::env(LARA_OUT_DIR)]
}
set ROUTE_DIRECTIVE "Explore"
if {[info exists ::env(LARA_ROUTE_DIRECTIVE)] &&
    ([string trim $::env(LARA_ROUTE_DIRECTIVE)] ne "")} {
    set ROUTE_DIRECTIVE [string trim $::env(LARA_ROUTE_DIRECTIVE)]
}

# Vivado front-end memory can spike badly on this design. Keep the build in a
# strictly low-parallel mode so synth/impl are more likely to finish on a
# 16 GB host without the parent process being killed mid-run.
set_param general.maxThreads ${MAX_THREADS}

if {[file exists $OUT_DIR]} {
    set existing_entries [glob -nocomplain -directory $OUT_DIR *]
    foreach existing_entry $existing_entries {
        if {[lsearch -exact {
            build_metadata.txt
            vivado_build.log
            vivado_build.jou
        } [file tail $existing_entry]] < 0} {
            error "Build output directory is not empty: $OUT_DIR"
        }
    }
}
file mkdir $OUT_DIR
create_project ${PROJ_NAME} ${OUT_DIR} -part ${PART} -force
set_property board_part ${BOARD_SOM} [current_project]
set_property target_language Verilog [current_project]

# Add the RTL required by the current attn_top integration.
set rtl [list \
    ${HW_DIR}/rtl/pkg/attn_pkg.sv \
    ${HW_DIR}/rtl/core/attn_tile.sv \
    ${HW_DIR}/rtl/core/softmax_engine.sv \
    ${HW_DIR}/rtl/core/psum_accum.sv \
    ${HW_DIR}/rtl/core/attn_core.sv \
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
add_files -norecurse [list \
    ${HW_DIR}/data/exp_lut.hex \
    ${HW_DIR}/data/recip_lut.hex \
    ${HW_DIR}/data/rope_theta.hex \
    ${HW_DIR}/data/rope_sincos_sin.hex \
    ${HW_DIR}/data/rope_sincos_cos.hex \
]
add_files -fileset constrs_1 -norecurse ${HW_DIR}/constraints/attn_soc.xdc
add_files -fileset utils_1 -norecurse ${HW_DIR}/scripts/pre_bitstream.tcl
set_property file_type SystemVerilog [get_files *.sv]
set_property file_type {Memory Initialization Files} [get_files *.hex]
set rtl_defines [list USE_XPM_MEMORY=1 KV_CACHE_USE_XPM=1]
if {[info exists ::env(LARA_VIVADO_DEFINES)] &&
    ([string trim $::env(LARA_VIVADO_DEFINES)] ne "")} {
    foreach extra_define [split $::env(LARA_VIVADO_DEFINES)] {
        lappend rtl_defines $extra_define
    }
}
set_property verilog_define ${rtl_defines} [current_fileset]
puts "INFO: RTL defines: ${rtl_defines}"
puts "INFO: OUT_DIR=${OUT_DIR}"
puts "INFO: ROUTE_DIRECTIVE=${ROUTE_DIRECTIVE}"
update_compile_order -fileset sources_1
puts "INFO: Added [llength ${rtl}] RTL files."

proc get_unrouted_net_count {design_obj route_status_rpt} {
    set unrouted_raw [string trim [get_property NUM_UNROUTED_NETS $design_obj]]
    if {[string is integer -strict $unrouted_raw]} {
        return [expr {int($unrouted_raw)}]
    }

    puts "WARNING: NUM_UNROUTED_NETS unavailable or non-integer (<$unrouted_raw>); parsing $route_status_rpt"
    if {![file exists $route_status_rpt]} {
        error "route status report not found for unrouted-net fallback: $route_status_rpt"
    }

    set fh [open $route_status_rpt r]
    set route_status_text [read $fh]
    close $fh

    set routable_nets ""
    set fully_routed_nets ""
    foreach line [split $route_status_text "\n"] {
        if {[regexp {# of routable nets.*: *([0-9]+) *:} $line -> value]} {
            set routable_nets $value
        }
        if {[regexp {# of fully routed nets.*: *([0-9]+) *:} $line -> value]} {
            set fully_routed_nets $value
        }
    }

    if {$routable_nets eq "" || $fully_routed_nets eq ""} {
        error "failed to parse routable/fully-routed net counts from $route_status_rpt"
    }

    set unrouted_nets [expr {int($routable_nets) - int($fully_routed_nets)}]
    if {$unrouted_nets < 0} {
        error "parsed negative unrouted net count from $route_status_rpt: $unrouted_nets"
    }
    return $unrouted_nets
}

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
    CONFIG.c_sg_length_width {26} \
    CONFIG.c_m_axis_mm2s_tdata_width {32} CONFIG.c_s_axis_s2mm_tdata_width {32} \
    CONFIG.c_mm2s_burst_size {16}] [get_bd_cells axi_dma]

create_bd_cell -type module -reference attn_top_wrapper accel
connect_bd_net [get_bd_pins ps8/pl_clk0] [get_bd_pins accel/clk]
connect_bd_net [get_bd_pins rst_gen/peripheral_aresetn] [get_bd_pins accel/rst_n]
set fclk_hz [get_property CONFIG.FREQ_HZ [get_bd_pins ps8/pl_clk0]]
set_property CONFIG.FREQ_HZ ${fclk_hz} [get_bd_pins accel/clk]

# Helper: reconnect reset nets explicitly. Module-reference tops and auto AXI
# interconnect generation can leave ARESETN pins floating even when the BD
# validates, which then shows up as hung MMIO/DMA on hardware.
proc reconnect_reset_pins {src_pin dst_pins} {
    foreach dst_pin $dst_pins {
        if {$dst_pin eq ""} {
            continue
        }
        set old_net [get_bd_nets -quiet -of_objects $dst_pin]
        if {$old_net ne ""} {
            delete_bd_objs $old_net
        }
        connect_bd_net $src_pin $dst_pin
    }
}

proc existing_bd_pins {pin_names} {
    set pins [list]
    foreach pin_name $pin_names {
        set pin [get_bd_pins -quiet $pin_name]
        if {$pin ne ""} {
            lappend pins $pin
        } else {
            puts "INFO: optional reset pin not present in this BD: $pin_name"
        }
    }
    return $pins
}

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

# Explicitly drive the AXI control/data path resets from rst_gen. This is the
# same class of fix that was required in ~/git/xx to avoid a valid-looking BD
# whose AXI peripherals still hang once software touches them.
reconnect_reset_pins [get_bd_pins rst_gen/peripheral_aresetn] [list \
    [get_bd_pins accel/rst_n] \
    [get_bd_pins ps8_axi_periph/ARESETN] \
    [get_bd_pins ps8_axi_periph/M00_ARESETN] \
    [get_bd_pins ps8_axi_periph/S00_ARESETN] \
    [get_bd_pins ps8_axi_periph_1/ARESETN] \
    [get_bd_pins ps8_axi_periph_1/M00_ARESETN] \
    [get_bd_pins ps8_axi_periph_1/S00_ARESETN] \
    [get_bd_pins axi_dma/axi_resetn] \
    [get_bd_pins axi_mem_intercon/ARESETN] \
    [get_bd_pins axi_mem_intercon/M00_ARESETN] \
    [get_bd_pins axi_mem_intercon/S00_ARESETN] \
    [get_bd_pins axi_smc/aresetn] \
]

reconnect_reset_pins [get_bd_pins rst_gen/peripheral_aresetn] [existing_bd_pins [list \
    axi_dma/s_axi_lite_aresetn \
    axi_smc/M00_ARESETN \
    axi_smc/S00_ARESETN \
]]

assign_bd_address -offset 0xA0000000 -range 16K \
    [get_bd_addr_segs {accel/s_axi/reg0}]
assign_bd_address -offset 0xB0000000 -range 64K \
    [get_bd_addr_segs {axi_dma/S_AXI_LITE/Reg}]
assign_bd_address -offset 0x00000000 -range 2G \
    [get_bd_addr_segs {ps8/SAXIGP2/HP0_DDR_LOW}]
assign_bd_address -offset 0x00000000 -range 2G \
    [get_bd_addr_segs {ps8/SAXIGP3/HP1_DDR_LOW}]
set_property CONFIG.FREQ_HZ ${fclk_hz} [get_bd_intf_pins accel/s_axi]
set_property CONFIG.FREQ_HZ ${fclk_hz} [get_bd_intf_pins accel/s_axis]
set_property CONFIG.FREQ_HZ ${fclk_hz} [get_bd_intf_pins accel/m_axis]
validate_bd_design
save_bd_design

# Post-validation sanity checks. Fail fast if Vivado leaves reset pins floating
# or if the DMA address map disappears from the generated hardware handoff.
set dma_segs [get_bd_addr_segs -of_objects [get_bd_cells axi_dma]]
if {[llength $dma_segs] < 1} {
    puts "ERROR: axi_dma has no address segment assigned."
    exit 1
}

set required_reset_pins [list \
    [get_bd_pins accel/rst_n] \
    [get_bd_pins ps8_axi_periph/ARESETN] \
    [get_bd_pins ps8_axi_periph/M00_ARESETN] \
    [get_bd_pins ps8_axi_periph/S00_ARESETN] \
    [get_bd_pins ps8_axi_periph_1/ARESETN] \
    [get_bd_pins ps8_axi_periph_1/M00_ARESETN] \
    [get_bd_pins ps8_axi_periph_1/S00_ARESETN] \
    [get_bd_pins axi_dma/axi_resetn] \
    [get_bd_pins axi_mem_intercon/ARESETN] \
    [get_bd_pins axi_mem_intercon/M00_ARESETN] \
    [get_bd_pins axi_mem_intercon/S00_ARESETN] \
    [get_bd_pins axi_smc/aresetn] \
]
set required_reset_pins [concat $required_reset_pins [existing_bd_pins [list \
    axi_dma/s_axi_lite_aresetn \
    axi_smc/M00_ARESETN \
    axi_smc/S00_ARESETN \
]]]
foreach pin $required_reset_pins {
    if {$pin eq ""} {
        continue
    }
    set net [get_bd_nets -quiet -of_objects $pin]
    if {$net eq ""} {
        puts "ERROR: required reset pin is unconnected: $pin"
        exit 1
    }
}

set bd_file [get_files -all */attn_soc.bd]
generate_target all $bd_file
set wrapper_files [make_wrapper -files $bd_file -top]
add_files -norecurse $wrapper_files
set_property top attn_soc_wrapper [current_fileset]
update_compile_order -fileset sources_1

# UCIO-1 waiver (internal PS-PL AXI ports, not physical I/O)
set_property STEPS.WRITE_BITSTREAM.TCL.PRE [file normalize ${HW_DIR}/scripts/pre_bitstream.tcl] [get_runs impl_1]

puts "INFO: Starting synthesis+implementation..."
reset_run synth_1
reset_run impl_1
launch_runs synth_1 -jobs ${N_JOBS}; wait_on_run synth_1
set synth_run [get_runs synth_1]
if {[get_property PROGRESS $synth_run] ne "100%"} {
    error "synth_1 did not complete: status=[get_property STATUS $synth_run] progress=[get_property PROGRESS $synth_run]"
}
puts "INFO: Synthesis done."
open_run synth_1
file mkdir ${OUT_DIR}/reports
file mkdir ${OUT_DIR}/checkpoints
report_utilization -file ${OUT_DIR}/reports/post_synth_utilization.rpt
report_utilization -hierarchical -file ${OUT_DIR}/reports/post_synth_utilization_hier.rpt
report_timing_summary -file ${OUT_DIR}/reports/post_synth_timing_summary.rpt
write_checkpoint -force ${OUT_DIR}/checkpoints/post_synth.dcp
if {[info exists ::env(LARA_STOP_AFTER_SYNTH)] &&
    ($::env(LARA_STOP_AFTER_SYNTH) eq "1")} {
    puts "INFO: LARA_STOP_AFTER_SYNTH=1; synthesis reports are complete."
    exit 0
}
file delete -force ${OUT_DIR}/${PROJ_NAME}.runs/impl_1
file mkdir ${OUT_DIR}/${PROJ_NAME}.runs/impl_1
set impl_run [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE ${ROUTE_DIRECTIVE} $impl_run
puts "INFO: impl_1 route directive=${ROUTE_DIRECTIVE}"
launch_runs impl_1 -to_step route_design -jobs ${N_JOBS}; wait_on_run impl_1
if {[get_property PROGRESS $impl_run] ne "100%"} {
    error "impl_1 did not complete: status=[get_property STATUS $impl_run] progress=[get_property PROGRESS $impl_run]"
}
# Do not publish a bitstream from an implementation that missed setup or hold.
open_run impl_1
file mkdir ${OUT_DIR}/reports
file mkdir ${OUT_DIR}/checkpoints
foreach checkpoint_name {
    attn_soc_wrapper_placed.dcp
    attn_soc_wrapper_physopt.dcp
    attn_soc_wrapper_routed.dcp
} {
    set run_checkpoint [file join ${OUT_DIR} ${PROJ_NAME}.runs impl_1 $checkpoint_name]
    if {[file exists $run_checkpoint]} {
        file copy -force $run_checkpoint [file join ${OUT_DIR} checkpoints $checkpoint_name]
    } else {
        puts "WARNING: implementation checkpoint not found: $run_checkpoint"
    }
}
# Internal PS/PL interfaces are not package pins. Keep the established UCIO-1
# waiver in effect so the saved DRC report reflects the bitstream gate.
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
report_timing_summary -max_paths 20 -report_unconstrained \
    -file ${OUT_DIR}/reports/post_route_timing_summary.rpt
report_route_status -file ${OUT_DIR}/reports/post_route_status.rpt
report_utilization -hierarchical -file ${OUT_DIR}/reports/post_route_utilization.rpt
report_drc -file ${OUT_DIR}/reports/post_route_drc.rpt
set max_paths [get_timing_paths -delay_type max -max_paths 1]
set min_paths [get_timing_paths -delay_type min -max_paths 1]
set routed_wns [expr {[llength $max_paths] ? [get_property SLACK [lindex $max_paths 0]] : -1.0}]
set routed_whs [expr {[llength $min_paths] ? [get_property SLACK [lindex $min_paths 0]] : -1.0}]
set drc_errors [llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]
set design_obj [current_design]
if {$design_obj eq ""} {
    error "signoff check has no current design"
}
set unrouted_nets [get_unrouted_net_count $design_obj ${OUT_DIR}/reports/post_route_status.rpt]
puts "INFO: Routed signoff gate: WNS=${routed_wns} ns, WHS=${routed_whs} ns, DRC errors=${drc_errors}, unrouted nets=${unrouted_nets}"
if {($routed_wns < 0.0) || ($routed_whs < 0.0) ||
    ($drc_errors != 0) || ($unrouted_nets != 0)} {
    puts "ERROR: Routed signoff failed; bitstream generation is blocked."
    exit 2
}
# Bitstream: route_design passes, then skip UCIO-1 DRC for internal PS-PL paths
launch_runs impl_1 -to_step write_bitstream -jobs ${N_JOBS}
wait_on_run impl_1

file mkdir ${OUT_DIR}/deploy
file copy -force ${OUT_DIR}/${PROJ_NAME}.runs/impl_1/attn_soc_wrapper.bit ${OUT_DIR}/deploy/lara_attention.bit
file copy -force \
    ${OUT_DIR}/${PROJ_NAME}.gen/sources_1/bd/attn_soc/hw_handoff/attn_soc.hwh \
    ${OUT_DIR}/deploy/lara_attention.hwh
write_hw_platform -fixed -include_bit -force -file ${OUT_DIR}/deploy/lara_attention.xsa
foreach artifact {lara_attention.bit lara_attention.hwh lara_attention.xsa} {
    set artifact_path [file join ${OUT_DIR} deploy $artifact]
    if {![file exists $artifact_path] || [file size $artifact_path] == 0} {
        error "Deployment artifact missing or empty: $artifact_path"
    }
}
puts "============================================================"
puts " BUILD COMPLETE — ${OUT_DIR}/deploy/lara_attention.bit"
puts "============================================================"
