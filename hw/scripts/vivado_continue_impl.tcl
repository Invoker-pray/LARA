# Continue implementation from a completed synthesis run in the current project.
# This intentionally does not regenerate the project or synthesize RTL again.

set PROJ_NAME  "lara_attention"
set OUT_DIR    "vivado_proj"
set REPORT_DIR "${OUT_DIR}/reports"
set N_JOBS     1

set_param general.maxThreads 1

set project_file "${OUT_DIR}/${PROJ_NAME}.xpr"
if {![file exists $project_file]} {
    error "Vivado project not found: $project_file"
}

open_project $project_file

set synth_run [get_runs synth_1]
set synth_progress [get_property PROGRESS $synth_run]
set synth_status [get_property STATUS $synth_run]
if {$synth_progress ne "100%"} {
    error "synth_1 is incomplete: status='$synth_status', progress='$synth_progress'"
}

set rtl_defines [get_property verilog_define [get_filesets sources_1]]
if {[lsearch -exact $rtl_defines LARA_STREAMING_PV_ENABLE] < 0} {
    error "Current project is not the streaming-PV candidate: defines=$rtl_defines"
}

puts "INFO: Reusing completed synthesis: status='$synth_status'"
puts "INFO: Matching RTL defines: $rtl_defines"
puts "INFO: Starting default implementation through route_design"

reset_run impl_1
launch_runs impl_1 -to_step route_design -jobs $N_JOBS
wait_on_run impl_1

set impl_run [get_runs impl_1]
set impl_progress [get_property PROGRESS $impl_run]
set impl_status [get_property STATUS $impl_run]
puts "INFO: impl_1 status='$impl_status', progress='$impl_progress'"
if {$impl_progress ne "100%"} {
    error "impl_1 did not complete: status='$impl_status', progress='$impl_progress'"
}

open_run impl_1
file mkdir $REPORT_DIR

# Internal PS/PL interfaces are not package pins.  Keep the project waiver
# consistent with the clean-build signoff flow.
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]

report_timing_summary -max_paths 20 -report_unconstrained \
    -file "${REPORT_DIR}/post_route_timing_summary.rpt"
report_route_status -file "${REPORT_DIR}/post_route_status.rpt"
report_utilization -hierarchical \
    -file "${REPORT_DIR}/post_route_utilization.rpt"
report_drc -file "${REPORT_DIR}/post_route_drc.rpt"

set routed_dcp "${OUT_DIR}/${PROJ_NAME}.runs/impl_1/attn_soc_wrapper_routed.dcp"
write_checkpoint -force $routed_dcp

set routed_wns [get_property SLACK \
    [get_timing_paths -delay_type max -max_paths 1]]
set routed_whs [get_property SLACK \
    [get_timing_paths -delay_type min -max_paths 1]]
set drc_errors [llength \
    [get_drc_violations -quiet -filter {SEVERITY == Error}]]

puts "INFO: Routed candidate gate: WNS=${routed_wns} ns, WHS=${routed_whs} ns, DRC errors=${drc_errors}"
puts "INFO: Routed checkpoint: $routed_dcp"
if {($routed_wns < 0.0) || ($routed_whs < 0.0) || ($drc_errors != 0)} {
    puts "ERROR: Routed candidate gate failed; deployment generation remains blocked."
    exit 2
}

puts "INFO: Routed candidate gate passed. Deployment generation is intentionally deferred."
exit 0
