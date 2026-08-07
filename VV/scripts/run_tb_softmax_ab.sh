#!/bin/bash
# run_tb_softmax_ab.sh — Bit-exact SOFTMAX_P_PIPE rollback/default comparison
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
set -e
export SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE:-27000@archlinux}"
export LM_LICENSE_FILE="${LM_LICENSE_FILE:-$SNPSLMD_LICENSE_FILE}"

TB_NAME="tb_softmax"
BASE_DIR="$(pwd)/VV/sim/${TB_NAME}_ab"
mkdir -p "${BASE_DIR}/rollback" "${BASE_DIR}/pipeline"

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

run_variant rollback +define+LARA_SOFTMAX_P_PIPE_ROLLBACK
run_variant pipeline ""
cmp "${BASE_DIR}/rollback/outputs.bits" "${BASE_DIR}/pipeline/outputs.bits"
grep -q "total=1106" "${BASE_DIR}/rollback/sim.log"
grep -q "total=626" "${BASE_DIR}/pipeline/sim.log"
echo "ALL SOFTMAX A/B BIT-EXACT CHECKS PASSED"
