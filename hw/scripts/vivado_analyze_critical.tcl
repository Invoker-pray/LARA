set OUT_DIR "vivado_proj/optimization_analysis"
set ROUTED_DCP "vivado_proj/lara_attention.runs/impl_1/attn_soc_wrapper_routed.dcp"
set_param general.maxThreads 1

if {![file exists $ROUTED_DCP]} {
    error "Missing routed checkpoint: $ROUTED_DCP"
}
file mkdir $OUT_DIR
open_checkpoint $ROUTED_DCP

report_timing -max_paths 100 -sort_by slack \
    -file "${OUT_DIR}/critical_timing_paths.rpt"
report_high_fanout_nets -max_nets 100 \
    -file "${OUT_DIR}/high_fanout.rpt"
report_design_analysis -congestion \
    -file "${OUT_DIR}/congestion.rpt"
report_utilization -hierarchical \
    -file "${OUT_DIR}/utilization_hierarchical.rpt"
puts "Wrote critical-path reports under $OUT_DIR"
