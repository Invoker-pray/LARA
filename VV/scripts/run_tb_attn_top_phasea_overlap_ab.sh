#!/bin/bash
# Focused P2 Phase-A serial/overlap bit-exact and cycle comparison.
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
set -e
export SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE:-27000@archlinux}"
export LM_LICENSE_FILE="${LM_LICENSE_FILE:-$SNPSLMD_LICENSE_FILE}"

TB_NAME="tb_attn_top_phasea_overlap"
BASE_DIR="$(pwd)/VV/sim/${TB_NAME}_ab"
mkdir -p "${BASE_DIR}/rollback" "${BASE_DIR}/overlap"

run_variant() {
  local variant="$1"
  local rollback_define="$2"
  local sim_dir="${BASE_DIR}/${variant}"
  cd "${sim_dir}"
  ln -sf ../../../data data
  ln -sf ../../../data/exp_lut.hex exp_lut.hex
  ln -sf ../../../data/recip_lut.hex recip_lut.hex
  vcs -full64 -sverilog -timescale=1ns/1ps +lint=all +v2k \
      +define+SYNTHESIS ${rollback_define} \
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
      ../../../../VV/tb/${TB_NAME}.sv \
      -o simv
  ./simv -no_save +DUMP_BITS="${sim_dir}/outputs.bits" -l sim.log
}

run_variant rollback +define+LARA_PHASEA_SOFTMAX_OVERLAP_ROLLBACK
run_variant overlap ""
cmp "${BASE_DIR}/rollback/outputs.bits" "${BASE_DIR}/overlap/outputs.bits"
grep -q "ALL PHASEA OVERLAP CHECKS PASSED" "${BASE_DIR}/rollback/sim.log"
grep -q "ALL PHASEA OVERLAP CHECKS PASSED" "${BASE_DIR}/overlap/sim.log"
rollback_cycles="$(awk '/PHASEA_PROFILE round=0/ {for (i=1; i<=NF; i++) if ($i ~ /^cycles=/) {split($i,a,"="); print a[2]; exit}}' "${BASE_DIR}/rollback/sim.log")"
overlap_cycles="$(awk '/PHASEA_PROFILE round=0/ {for (i=1; i<=NF; i++) if ($i ~ /^cycles=/) {split($i,a,"="); print a[2]; exit}}' "${BASE_DIR}/overlap/sim.log")"
if (( overlap_cycles * 100 > rollback_cycles * 85 )); then
  echo "FAIL Phase-A improvement below 15%: rollback=${rollback_cycles} overlap=${overlap_cycles}"
  exit 1
fi
awk -v base="${rollback_cycles}" -v opt="${overlap_cycles}" \
    'BEGIN {printf "PHASEA CYCLE IMPROVEMENT %.2f%% (%d -> %d)\n", 100.0*(base-opt)/base, base, opt}'
echo "ALL PHASEA OVERLAP A/B BIT-EXACT CHECKS PASSED"
