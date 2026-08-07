#!/bin/bash
# Focused P4 sequential/streaming-PV bit-exact and cycle comparison.
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
set -e
export SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE:-27000@archlinux}"
export LM_LICENSE_FILE="${LM_LICENSE_FILE:-$SNPSLMD_LICENSE_FILE}"

BASE_DIR="$(pwd)/VV/sim/tb_attn_top_streaming_pv_ab"
mkdir -p "${BASE_DIR}/baseline" "${BASE_DIR}/streaming"

run_variant() {
  local tb_name="$1"
  local variant="$2"
  local candidate_define="$3"
  local sim_dir="$4"
  mkdir -p "${sim_dir}"
  cd "${sim_dir}"
  ln -sf ../../../data data
  ln -sf ../../../data/exp_lut.hex exp_lut.hex
  ln -sf ../../../data/recip_lut.hex recip_lut.hex
  vcs -full64 -sverilog -timescale=1ns/1ps +lint=all +v2k \
      +define+SYNTHESIS ${candidate_define} \
      -l compile.log \
      +incdir+../../../../hw/rtl/pkg \
      ../../../../hw/rtl/pkg/attn_pkg.sv \
      ../../../../hw/rtl/core/attn_tile.sv \
      ../../../../hw/rtl/core/softmax_engine.sv \
      ../../../../hw/rtl/core/softmax_engine_basic.sv \
      ../../../../hw/rtl/core/psum_accum.sv \
      ../../../../hw/rtl/core/psum_accum_basic.sv \
      ../../../../hw/rtl/core/attn_core.sv \
      ../../../../hw/rtl/mem/kv_cache_ram.sv \
      ../../../../hw/rtl/mem/tile_buffer.sv \
      ../../../../hw/rtl/mem/output_buffer.sv \
      ../../../../hw/rtl/axi/attn_axi_lite_slave.sv \
      ../../../../hw/rtl/axi/attn_axi_stream_sink.sv \
      ../../../../hw/rtl/axi/attn_axi_stream_source.sv \
      ../../../../hw/rtl/attn_top.sv \
      ../../../../VV/tb/${tb_name}.sv \
      -o simv
  ./simv -no_save +DUMP_BITS="${sim_dir}/outputs.bits" -l sim.log
  grep -q "ALL.*PASSED" sim.log
}

run_variant tb_attn_top baseline +define+LARA_STREAMING_PV_ROLLBACK "${BASE_DIR}/baseline"
run_variant tb_attn_top streaming +define+LARA_STREAMING_PV_ENABLE "${BASE_DIR}/streaming"
grep -q "MAINLOOP_PROFILE" "${BASE_DIR}/baseline/sim.log"
grep -q "MAINLOOP_PROFILE" "${BASE_DIR}/streaming/sim.log"
cmp "${BASE_DIR}/baseline/outputs.bits" "${BASE_DIR}/streaming/outputs.bits"

baseline_cycles="$(awk '/MAINLOOP_PROFILE/ {for (i=1; i<=NF; i++) if ($i ~ /^cycles=/) {split($i,a,"="); print a[2]; exit}}' "${BASE_DIR}/baseline/sim.log")"
streaming_cycles="$(awk '/MAINLOOP_PROFILE/ {for (i=1; i<=NF; i++) if ($i ~ /^cycles=/) {split($i,a,"="); print a[2]; exit}}' "${BASE_DIR}/streaming/sim.log")"
if (( streaming_cycles * 100 > baseline_cycles * 90 )); then
  echo "FAIL streaming-PV improvement below 10%: baseline=${baseline_cycles} streaming=${streaming_cycles}"
  exit 1
fi
awk -v base="${baseline_cycles}" -v opt="${streaming_cycles}" \
    'BEGIN {printf "STREAMING PV CYCLE IMPROVEMENT %.2f%% (%d -> %d)\n", 100.0*(base-opt)/base, base, opt}'

"${BASE_DIR}/baseline/simv" -no_save +FULL_KV_PROFILE \
    +DUMP_BITS="${BASE_DIR}/baseline/outputs_full_kv.bits" \
    -l "${BASE_DIR}/baseline/sim_full_kv.log"
"${BASE_DIR}/streaming/simv" -no_save +FULL_KV_PROFILE \
    +DUMP_BITS="${BASE_DIR}/streaming/outputs_full_kv.bits" \
    -l "${BASE_DIR}/streaming/sim_full_kv.log"
grep -q "ALL ATTN_TOP CHECKS PASSED" "${BASE_DIR}/baseline/sim_full_kv.log"
grep -q "ALL ATTN_TOP CHECKS PASSED" "${BASE_DIR}/streaming/sim_full_kv.log"
cmp "${BASE_DIR}/baseline/outputs_full_kv.bits" "${BASE_DIR}/streaming/outputs_full_kv.bits"
baseline_full_cycles="$(awk '/MAINLOOP_PROFILE/ {for (i=1; i<=NF; i++) if ($i ~ /^cycles=/) {split($i,a,"="); print a[2]; exit}}' "${BASE_DIR}/baseline/sim_full_kv.log")"
streaming_full_cycles="$(awk '/MAINLOOP_PROFILE/ {for (i=1; i<=NF; i++) if ($i ~ /^cycles=/) {split($i,a,"="); print a[2]; exit}}' "${BASE_DIR}/streaming/sim_full_kv.log")"
if (( streaming_full_cycles * 100 > baseline_full_cycles * 90 )); then
  echo "FAIL full-KV streaming-PV improvement below 10%: baseline=${baseline_full_cycles} streaming=${streaming_full_cycles}"
  exit 1
fi
awk -v base="${baseline_full_cycles}" -v opt="${streaming_full_cycles}" \
    'BEGIN {printf "FULL-KV STREAMING PV CYCLE IMPROVEMENT %.2f%% (%d -> %d)\n", 100.0*(base-opt)/base, base, opt}'

run_variant tb_attn_top_partial baseline +define+LARA_STREAMING_PV_ROLLBACK "${BASE_DIR}/partial_baseline"
run_variant tb_attn_top_partial streaming +define+LARA_STREAMING_PV_ENABLE "${BASE_DIR}/partial_streaming"
cmp "${BASE_DIR}/partial_baseline/outputs.bits" "${BASE_DIR}/partial_streaming/outputs.bits"
echo "ALL PARTIAL STREAMING PV A/B BIT-EXACT CHECKS PASSED"
echo "ALL STREAMING PV A/B BIT-EXACT CHECKS PASSED"
