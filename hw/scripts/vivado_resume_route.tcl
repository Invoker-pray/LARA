set PROJ_NAME "lara_attention"
set OUT_DIR   "vivado_proj"
set RUN_DIR   "${OUT_DIR}/${PROJ_NAME}.runs/impl_1"
set REPORT_DIR "${OUT_DIR}/reports"
set DEPLOY_DIR "${OUT_DIR}/deploy"
set ROUTE_DIRECTIVE "Explore"

set_param general.maxThreads 1

set project_file "${OUT_DIR}/${PROJ_NAME}.xpr"
set resume_dcp "${RUN_DIR}/attn_soc_wrapper_physopt.dcp"
if {![file exists $project_file]} {
    error "Vivado project not found: $project_file"
}
if {![file exists $resume_dcp]} {
    error "Post-phys-opt checkpoint not found: $resume_dcp"
}

open_project $project_file
open_checkpoint $resume_dcp
file mkdir $REPORT_DIR

puts "INFO: Resuming route_design from $resume_dcp"
puts "INFO: route_design directive=${ROUTE_DIRECTIVE}"
route_design -directive $ROUTE_DIRECTIVE

set routed_dcp "${RUN_DIR}/attn_soc_wrapper_routed.dcp"
write_checkpoint -force $routed_dcp
report_timing_summary -max_paths 20 -report_unconstrained \
    -file "${REPORT_DIR}/post_route_timing_summary.rpt"
report_route_status -file "${REPORT_DIR}/post_route_status.rpt"
report_utilization -hierarchical -file "${REPORT_DIR}/post_route_utilization.rpt"
report_drc -file "${REPORT_DIR}/post_route_drc.rpt"

set routed_wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set routed_whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
set drc_errors [llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]
puts "INFO: Routed signoff: WNS=${routed_wns} ns, WHS=${routed_whs} ns, DRC errors=${drc_errors}"
if {($routed_wns < 0.0) || ($routed_whs < 0.0) || ($drc_errors != 0)} {
    puts "ERROR: Routed signoff failed; bitstream generation is blocked."
    exit 2
}

source hw/scripts/pre_bitstream.tcl
file mkdir $DEPLOY_DIR
set bit_file "${DEPLOY_DIR}/lara_attention.bit"
write_bitstream -force $bit_file

set hwh_source "${OUT_DIR}/${PROJ_NAME}.gen/sources_1/bd/attn_soc/hw_handoff/attn_soc.hwh"
if {![file exists $hwh_source]} {
    error "HWH source not found: $hwh_source"
}
file copy -force $hwh_source "${DEPLOY_DIR}/lara_attention.hwh"
write_hw_platform -fixed -include_bit -force \
    -file "${DEPLOY_DIR}/lara_attention.xsa"

puts "============================================================"
puts " ROUTE RESUME COMPLETE - WNS=${routed_wns} ns, WHS=${routed_whs} ns"
puts " Deploy files: $DEPLOY_DIR"
puts "============================================================"
