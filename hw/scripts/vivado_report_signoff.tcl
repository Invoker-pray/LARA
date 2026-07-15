set PROJ_NAME  "lara_attention"
set OUT_DIR    "vivado_proj"
set REPORT_DIR "${OUT_DIR}/reports"

set_param general.maxThreads 1

set project_file "${OUT_DIR}/${PROJ_NAME}.xpr"
if {![file exists $project_file]} {
    error "Vivado project not found: $project_file"
}

open_project $project_file
open_run impl_1
file mkdir $REPORT_DIR

set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
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
    puts "ERROR: Routed signoff failed."
    exit 2
}

puts "INFO: Signoff reports written to ${REPORT_DIR}"
