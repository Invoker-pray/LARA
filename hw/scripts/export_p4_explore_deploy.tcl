# Export deployment files from the accepted P4 Explore-routed checkpoint.
# This does not rerun synthesis, placement, or routing.

set_param general.maxThreads 1
set ROOT [file normalize [file join [file dirname [info script]] ../..]]
set PROJECT [file join $ROOT vivado_proj lara_attention.xpr]
set ROUTED_DCP [file join $ROOT checkpoint/v2.5-p4-architecture-dse/candidate1-streaming-pv/explore-route/attn_soc_wrapper_routed.dcp]
set HWH [file join $ROOT vivado_proj/lara_attention.gen/sources_1/bd/attn_soc/hw_handoff/attn_soc.hwh]
set OUT_DIR [file join $ROOT vivado_proj/p4-explore-deploy]
set REPORT_DIR [file join $OUT_DIR reports]
set BIT [file join $OUT_DIR lara_attention.bit]
set XSA [file join $OUT_DIR lara_attention.xsa]

foreach required [list $PROJECT $ROUTED_DCP $HWH] {
  if {![file exists $required]} {
    error "required P4 Explore artifact not found: $required"
  }
}
file mkdir $OUT_DIR
file mkdir $REPORT_DIR

open_project $PROJECT
open_checkpoint $ROUTED_DCP
set_property SEVERITY Warning [get_drc_checks UCIO-1]
report_timing_summary -max_paths 20 -report_unconstrained \
  -file [file join $REPORT_DIR post_route_timing_summary.rpt]
report_route_status -file [file join $REPORT_DIR post_route_status.rpt]
report_utilization -hierarchical -file [file join $REPORT_DIR post_route_utilization.rpt]
report_drc -file [file join $REPORT_DIR post_route_drc.rpt]

set max_path [lindex [get_timing_paths -delay_type max -max_paths 1] 0]
set min_path [lindex [get_timing_paths -delay_type min -max_paths 1] 0]
set wns [get_property SLACK $max_path]
set whs [get_property SLACK $min_path]
set drc_errors [llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]
if {$wns < 0.0 || $whs < 0.0 || $drc_errors != 0} {
  error "P4 Explore signoff failed: WNS=$wns WHS=$whs DRC_errors=$drc_errors"
}

write_bitstream -force $BIT
file copy -force $HWH [file join $OUT_DIR lara_attention.hwh]
write_hw_platform -fixed -include_bit -force -file $XSA
puts "P4 Explore deployment export complete: $OUT_DIR"
exit 0
