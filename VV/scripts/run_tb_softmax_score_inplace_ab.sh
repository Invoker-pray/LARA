#!/bin/bash
# Focused P3 separate/in-place scaled-score scratch bit-exact comparison.
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
set -e
export SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE:-27000@archlinux}"
export LM_LICENSE_FILE="${LM_LICENSE_FILE:-$SNPSLMD_LICENSE_FILE}"

TB_NAME="tb_softmax"
BASE_DIR="$(pwd)/VV/sim/${TB_NAME}_score_inplace_ab"
mkdir -p "${BASE_DIR}/separate" "${BASE_DIR}/inplace"

run_variant() {
  local variant="$1"
  local rollback_define="$2"
  local sim_dir="${BASE_DIR}/${variant}"
  cd "${sim_dir}"
  ln -sf ../../../data data
  ln -sf ../../../data/exp_lut.hex exp_lut.hex
  vcs -full64 -sverilog -timescale=1ns/1ps +lint=all +v2k \
      +define+SYNTHESIS ${rollback_define} \
      -l compile.log \
      +incdir+../../../../hw/rtl/pkg \
      ../../../../hw/rtl/pkg/attn_pkg.sv \
      ../../../../hw/rtl/core/softmax_engine.sv \
      ../../../../VV/tb/${TB_NAME}.sv \
      -o simv
  ./simv -no_save +DUMP_BITS="${sim_dir}/outputs.bits" -l sim.log
}

run_variant separate "+define+LARA_SOFTMAX_P_INPLACE_ENABLE +define+LARA_SOFTMAX_P_OUTPUT_DIRECT_ENABLE"
run_variant inplace "+define+LARA_SOFTMAX_P_INPLACE_ENABLE +define+LARA_SOFTMAX_P_OUTPUT_DIRECT_ENABLE +define+LARA_SOFTMAX_SCORE_INPLACE_ENABLE"
cmp "${BASE_DIR}/separate/outputs.bits" "${BASE_DIR}/inplace/outputs.bits"
grep -q "total=626" "${BASE_DIR}/separate/sim.log"
grep -q "total=626" "${BASE_DIR}/inplace/sim.log"
echo "ALL SOFTMAX SCORE IN-PLACE A/B BIT-EXACT CHECKS PASSED"
