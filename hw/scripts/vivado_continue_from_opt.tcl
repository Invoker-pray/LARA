# Continue implementation from the archived optimized checkpoint.
# This is deliberately independent of impl_1 and never calls reset_run.

set_param general.maxThreads 1
set_param general.maxBackupLogs 20

set ROOT [file normalize [file join [file dirname [info script]] ../..]]
set INPUT_DCP [file join $ROOT checkpoint/v2.5-p4-architecture-dse/pause-round3-impl-interrupted-20260727/checkpoint/attn_soc_wrapper_opt.dcp]
set OUT_DIR [file join $ROOT vivado_proj/round3-opt-default-route]
set REPORT_DIR [file join $OUT_DIR reports]
set PLACED_DCP [file join $OUT_DIR attn_soc_wrapper_placed.dcp]
set PHYSOPT_DCP [file join $OUT_DIR attn_soc_wrapper_physopt.dcp]
set ROUTED_DCP [file join $OUT_DIR attn_soc_wrapper_routed.dcp]

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

if {![file exists $INPUT_DCP]} {
    error "Archived optimized checkpoint not found: $INPUT_DCP"
}
file mkdir $OUT_DIR
file mkdir $REPORT_DIR

puts "INFO: opening archived optimized checkpoint: $INPUT_DCP"
open_checkpoint $INPUT_DCP
set design [current_design]
if {$design eq ""} {
    error "open_checkpoint did not create a current design"
}
puts "INFO: design=[get_property NAME $design] part=[get_property PART $design]"

puts "INFO: starting default place_design"
place_design
write_checkpoint -force $PLACED_DCP
report_utilization -hierarchical -file [file join $REPORT_DIR post_place_utilization.rpt]
report_timing_summary -max_paths 20 -report_unconstrained -file [file join $REPORT_DIR post_place_timing_summary.rpt]
report_design_analysis -congestion -file [file join $REPORT_DIR post_place_congestion.rpt]

puts "INFO: starting default phys_opt_design"
phys_opt_design
write_checkpoint -force $PHYSOPT_DCP
report_utilization -hierarchical -file [file join $REPORT_DIR post_physopt_utilization.rpt]
report_timing_summary -max_paths 20 -report_unconstrained -file [file join $REPORT_DIR post_physopt_timing_summary.rpt]
report_design_analysis -congestion -file [file join $REPORT_DIR post_physopt_congestion.rpt]

puts "INFO: starting default route_design"
route_design
write_checkpoint -force $ROUTED_DCP
report_timing_summary -max_paths 50 -report_unconstrained -file [file join $REPORT_DIR post_route_timing_summary.rpt]
report_route_status -file [file join $REPORT_DIR post_route_status.rpt]
report_utilization -hierarchical -file [file join $REPORT_DIR post_route_utilization.rpt]
report_drc -file [file join $REPORT_DIR post_route_drc.rpt]

set timing_paths_max [get_timing_paths -delay_type max -max_paths 1]
set timing_paths_min [get_timing_paths -delay_type min -max_paths 1]
set wns [expr {[llength $timing_paths_max] ? [get_property SLACK [lindex $timing_paths_max 0]] : "NA"}]
set whs [expr {[llength $timing_paths_min] ? [get_property SLACK [lindex $timing_paths_min 0]] : "NA"}]
set drc_errors [llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]
set routed_design [current_design]
if {$routed_design eq ""} {
    error "route signoff has no current design"
}
set unrouted [get_unrouted_net_count $routed_design [file join $REPORT_DIR post_route_status.rpt]]
puts "INFO: default route signoff WNS=$wns ns WHS=$whs ns DRC_errors=$drc_errors unrouted_nets=$unrouted"
puts "INFO: checkpoints: placed=$PLACED_DCP physopt=$PHYSOPT_DCP routed=$ROUTED_DCP"
if {$drc_errors != 0 || $unrouted != 0 || $wns eq "NA" || $whs eq "NA" || $wns < 0.0 || $whs < 0.0} {
    puts "ERROR: default-route signoff gate failed; evidence retained and no deployment artifacts generated."
    exit 2
}
puts "INFO: default-route signoff gate passed."
exit 0
