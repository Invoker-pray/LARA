# Export deployment artifacts from a completed routed checkpoint in a specific
# build directory. This avoids rerunning synthesis/place/route when signoff has
# already passed and only artifact export is needed.

set_param general.maxThreads 1

set ROOT [file normalize [file join [file dirname [info script]] ../..]]
set BUILD_DIR ""
if {[info exists ::env(LARA_EXPORT_BUILD_DIR)] &&
    ([string trim $::env(LARA_EXPORT_BUILD_DIR)] ne "")} {
    set BUILD_DIR [file normalize [string trim $::env(LARA_EXPORT_BUILD_DIR)]]
}
if {$BUILD_DIR eq ""} {
    error "LARA_EXPORT_BUILD_DIR is required"
}

set PROJECT [file join $BUILD_DIR lara_attention.xpr]
set ROUTED_DCP [file join $BUILD_DIR checkpoints attn_soc_wrapper_routed.dcp]
set HWH [file join $BUILD_DIR lara_attention.gen sources_1 bd attn_soc hw_handoff attn_soc.hwh]
set REPORT_DIR [file join $BUILD_DIR reports]
set DEPLOY_DIR [file join $BUILD_DIR deploy]
set BIT [file join $DEPLOY_DIR lara_attention.bit]
set XSA [file join $DEPLOY_DIR lara_attention.xsa]

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

foreach required [list $PROJECT $ROUTED_DCP $HWH] {
    if {![file exists $required]} {
        error "required artifact not found: $required"
    }
}
file mkdir $REPORT_DIR
file mkdir $DEPLOY_DIR

open_project $PROJECT
open_checkpoint $ROUTED_DCP
set_property SEVERITY Warning [get_drc_checks UCIO-1]

report_timing_summary -max_paths 20 -report_unconstrained \
  -file [file join $REPORT_DIR post_route_timing_summary.rpt]
report_route_status -file [file join $REPORT_DIR post_route_status.rpt]
report_utilization -hierarchical -file [file join $REPORT_DIR post_route_utilization.rpt]
report_drc -file [file join $REPORT_DIR post_route_drc.rpt]

set max_paths [get_timing_paths -delay_type max -max_paths 1]
set min_paths [get_timing_paths -delay_type min -max_paths 1]
set wns [expr {[llength $max_paths] ? [get_property SLACK [lindex $max_paths 0]] : -1.0}]
set whs [expr {[llength $min_paths] ? [get_property SLACK [lindex $min_paths 0]] : -1.0}]
set drc_errors [llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]
set design_obj [current_design]
if {$design_obj eq ""} {
    error "export signoff has no current design"
}
set unrouted_nets [get_unrouted_net_count $design_obj [file join $REPORT_DIR post_route_status.rpt]]

puts "INFO: Routed export signoff: WNS=$wns ns WHS=$whs ns DRC errors=$drc_errors unrouted nets=$unrouted_nets"
if {$wns < 0.0 || $whs < 0.0 || $drc_errors != 0 || $unrouted_nets != 0} {
    error "export signoff failed: WNS=$wns WHS=$whs DRC_errors=$drc_errors unrouted=$unrouted_nets"
}

source [file join $ROOT hw scripts pre_bitstream.tcl]
write_bitstream -force $BIT
file copy -force $HWH [file join $DEPLOY_DIR lara_attention.hwh]
write_hw_platform -fixed -include_bit -force -file $XSA

puts "============================================================"
puts " EXPORT COMPLETE — $DEPLOY_DIR"
puts "============================================================"
exit 0
