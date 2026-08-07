#!/usr/bin/env bash
# Verify performance-counter retention at both core and AXI-Lite CSR levels.
set -euo pipefail
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"

export SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE:-27000@127.0.0.1}"
export LM_LICENSE_FILE="${LM_LICENSE_FILE:-${SNPSLMD_LICENSE_FILE}}"

echo "=== PERF COUNTER CORE RETENTION ==="
bash VV/scripts/run_tb_attn_core_causal_skip.sh

echo "=== PERF COUNTER AXI-LITE CSR RETENTION ==="
CASE_PATH=board_cases_rtl_contract_v2.6_q31_kv7/case_L1_q31_kv7_causal.npz \
CASE_DIR=/tmp/lara_perf_counter_q31kv7_l1 \
BOARD_CASE_TEST_SEQ=1 \
BOARD_CASE_CAUSAL=1 \
BOARD_CASE_Q_POS_BASE=31 \
BOARD_CASE_KV_POS_BASE=7 \
bash VV/scripts/run_tb_attn_top_board_case.sh

SIM_LOG=VV/sim/tb_attn_top_board_case_xpm/sim.log
grep -q "PERF_CSR_AFTER_DONE" "${SIM_LOG}"
grep -q "BOARD CASE PASS" "${SIM_LOG}"
echo "ALL PERFORMANCE COUNTER RETENTION CHECKS PASSED"
