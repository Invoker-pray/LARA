#!/bin/bash
# run_tb_attn_core_causal_skip.sh — Causal traversal/cycle VCS regression
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
set -e
export SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE:-27000@archlinux}"
export LM_LICENSE_FILE="${LM_LICENSE_FILE:-$SNPSLMD_LICENSE_FILE}"
TB_NAME="tb_attn_core_causal_skip"
SIM_DIR="VV/sim/${TB_NAME}"
mkdir -p "${SIM_DIR}"

cd "${SIM_DIR}"
vcs -full64 -sverilog -timescale=1ns/1ps +lint=all +v2k \
    -l compile.log \
    +incdir+../../../hw/rtl/pkg \
    ../../../hw/rtl/pkg/attn_pkg.sv \
    ../../../hw/rtl/core/attn_core.sv \
    ../../../VV/tb/${TB_NAME}.sv \
    -o simv

cat > run.tcl << 'TCL'
run
quit
TCL
./simv -no_save -ucli -i run.tcl -l sim.log
grep -q "ALL ATTN_CORE CAUSAL SKIP CHECKS PASSED" sim.log
echo "${TB_NAME}: DONE"
