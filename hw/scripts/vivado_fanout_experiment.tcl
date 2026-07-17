# Reversible physical-only experiment. It never replaces the signed-off
# checkpoint or deploy files. A clean RTL build must reproduce any improvement.
set ROUTED_DCP "vivado_proj/lara_attention.runs/impl_1/attn_soc_wrapper_routed.dcp"
set OUT_DIR "vivado_proj/optimization_experiment/fanout"
set_param general.maxThreads 1
if {![file exists $ROUTED_DCP]} {
    error "Missing routed checkpoint: $ROUTED_DCP"
}
file mkdir $OUT_DIR
open_checkpoint $ROUTED_DCP
report_timing -max_paths 10 -sort_by slack -file "${OUT_DIR}/before_timing.rpt"

# Limit only the replicated split-phase registers. This is intentionally a
# physical experiment; a successful result must later be reproduced from a
# clean RTL build before it can become a committed constraint.
set split_regs [get_cells -hier -quiet -filter {NAME =~ *u_mac*split_phase_r_reg*}]
if {[llength $split_regs] > 0} {
    set_property MAX_FANOUT 256 $split_regs
    puts "INFO: constrained [llength $split_regs] split-phase registers"
} else {
    puts "WARNING: no split-phase registers matched"
}
phys_opt_design -directive AggressiveFanoutOpt
route_design -directive Explore
write_checkpoint -force "${OUT_DIR}/fanout_experiment_routed.dcp"
report_timing_summary -max_paths 20 -report_unconstrained \
    -file "${OUT_DIR}/timing_summary.rpt"
report_high_fanout_nets -max_nets 100 -file "${OUT_DIR}/high_fanout.rpt"
report_route_status -file "${OUT_DIR}/route_status.rpt"
report_utilization -hierarchical -file "${OUT_DIR}/utilization.rpt"
report_drc -file "${OUT_DIR}/drc.rpt"
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts "INFO: fanout experiment WNS=${wns} ns, WHS=${whs} ns"
