#!/bin/bash
# run_tb_attn_top_board_matrix.sh
#
# Run the complete board-case regression used for the KV260 attention path.
# By default, every case_*.npz file in the selected case directory is run.
#
# Usage:
#   bash VV/scripts/run_tb_attn_top_board_matrix.sh
#   bash VV/scripts/run_tb_attn_top_board_matrix.sh <case-root>
#   bash VV/scripts/run_tb_attn_top_board_matrix.sh <case-root> "1 16 32 64 128"
#
# Useful overrides:
#   CASE_ROOT=board_cases_rtl_contract_v2.6_fixed
#   CASE_DIR_ROOT=/tmp/lara_board_matrix_vcs
#   LOG_DIR=/tmp/lara_board_matrix_logs
#   BOARD_CASE_LENGTHS="1 16 32 64 128"  # optional filter; empty means all
#   VCS_HEARTBEAT_SEC=10                  # elapsed-time heartbeat interval
#   SNPSLMD_LICENSE_FILE=27000@127.0.0.1
#   CLEAN_SIM_CACHE=0

set -u
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY

CASE_ROOT="${CASE_ROOT:-board_cases_rtl_contract_v2.6_fixed}"
CASE_DIR_ROOT="${CASE_DIR_ROOT:-/tmp/lara_board_matrix_vcs}"
LOG_DIR="${LOG_DIR:-/tmp/lara_board_matrix_logs}"
BOARD_CASE_LENGTHS="${BOARD_CASE_LENGTHS:-}"
CLEAN_SIM_CACHE="${CLEAN_SIM_CACHE:-1}"
LOCK_DIR="${LOCK_DIR:-/tmp/lara_board_matrix.lock}"
VCS_HEARTBEAT_SEC="${VCS_HEARTBEAT_SEC:-10}"

# A case directory may be supplied positionally so a regression command does
# not depend on the repository's default test set. The second positional
# argument optionally filters the discovered cases by sequence length.
if [[ $# -ge 1 ]]; then
    CASE_ROOT="$1"
fi
if [[ $# -ge 2 ]]; then
    BOARD_CASE_LENGTHS="$2"
fi
if [[ $# -gt 2 ]]; then
    echo "Usage: $0 [case-root] [\"lengths\"]" >&2
    exit 2
fi
if [[ ! -d "${CASE_ROOT}" ]]; then
    echo "FAIL: case root does not exist or is not a directory: ${CASE_ROOT}" >&2
    exit 2
fi

release_regression_lock() {
    if [[ -f "${LOCK_DIR}/pid" ]] &&
       [[ "$(<"${LOCK_DIR}/pid")" == "$$" ]]; then
        rm -rf -- "${LOCK_DIR}"
    fi
}

acquire_regression_lock() {
    if mkdir -- "${LOCK_DIR}" 2>/dev/null; then
        printf '%s\n' "$$" > "${LOCK_DIR}/pid"
        trap release_regression_lock EXIT
        return 0
    fi

    local owner_pid=""
    if [[ -f "${LOCK_DIR}/pid" ]]; then
        owner_pid="$(<"${LOCK_DIR}/pid")"
    fi
    if [[ -n "${owner_pid}" ]] && kill -0 "${owner_pid}" 2>/dev/null; then
        echo "FAIL: another board-case regression is already running (pid=${owner_pid})" >&2
        echo "       Stop it before starting another regression." >&2
        exit 2
    fi

    # A previous shell may have been killed without running its EXIT trap.
    # Reclaim only a demonstrably stale lock.
    echo "WARNING: reclaiming stale board-case regression lock: ${LOCK_DIR}" >&2
    rm -rf -- "${LOCK_DIR}"
    if ! mkdir -- "${LOCK_DIR}" 2>/dev/null; then
        echo "FAIL: could not acquire board-case regression lock: ${LOCK_DIR}" >&2
        exit 2
    fi
    printf '%s\n' "$$" > "${LOCK_DIR}/pid"
    trap release_regression_lock EXIT
}

acquire_regression_lock

# The local lmg service is the default so this script can be started directly.
export SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE:-27000@127.0.0.1}"
export LM_LICENSE_FILE="${LM_LICENSE_FILE:-27000@127.0.0.1}"

SIM_DIR="VV/sim/tb_attn_top_board_case_xpm"

clean_simulation_artifacts() {
    if [[ "${CLEAN_SIM_CACHE}" != "1" ]]; then
        echo "Simulation cache cleanup disabled (CLEAN_SIM_CACHE=${CLEAN_SIM_CACHE})"
        return
    fi

    # These directories are generated exclusively by this board-case script.
    # Remove them before the first compile so an interrupted/old VCS build
    # cannot provide stale simv objects, test vectors, or PASS markers.
    echo "Cleaning old board-case simulation data and VCS cache"
    rm -rf -- "${SIM_DIR}" "${CASE_DIR_ROOT}" "${LOG_DIR}"
}

clean_simulation_artifacts
mkdir -p "${CASE_DIR_ROOT}" "${LOG_DIR}"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

show_log_tail() {
    local log_path="$1"
    if [[ -f "${log_path}" ]]; then
        tail -n 20 "${log_path}" || true
    else
        echo "No per-case log was produced: ${log_path}"
        echo "The simulation workspace may have been removed by another regression."
    fi
}

format_elapsed() {
    local seconds="$1"
    printf '%02d:%02d:%02d' \
        "$((seconds / 3600))" \
        "$(((seconds / 60) % 60))" \
        "$((seconds % 60))"
}

case_length_is_selected() {
    local seq_len="$1"
    local selected_len=""

    # An empty filter, or the explicit value "all", means every discovered
    # case. Word splitting is intentional here: the documented interface is
    # a space-separated list such as "1 16 32 64 128".
    if [[ -z "${BOARD_CASE_LENGTHS}" || "${BOARD_CASE_LENGTHS}" == "all" ]]; then
        return 0
    fi
    for selected_len in ${BOARD_CASE_LENGTHS}; do
        if [[ "${selected_len}" == "${seq_len}" ]]; then
            return 0
        fi
    done
    return 1
}

run_case() {
    local case_path="$1"
    local case_name
    local tag
    local case_dir
    local log_path
    local pass_line=""
    local metadata_line=""
    local seq_len=""
    local causal=""
    local mode=""
    local q_pos_base=""
    local kv_pos_base=""

    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    case_name="$(basename "${case_path}" .npz)"
    tag="${case_name}"
    case_dir="${CASE_DIR_ROOT}/${tag}"
    log_path="${LOG_DIR}/${tag}.log"

    if ! metadata_line="$(python3 - "${case_path}" <<'PY'
import sys
import numpy as np

with np.load(sys.argv[1]) as data:
    seq_len = int(np.asarray(data["seq_len"]).item())
    causal = int(np.asarray(data["causal"]).item())
    q_pos = int(np.asarray(data["q_pos_base"]).item())
    kv_pos = int(np.asarray(data["kv_pos_base"]).item())
print(seq_len, causal, q_pos, kv_pos)
PY
)"; then
        echo "FAIL ${tag}: could not read seq_len/causal/position metadata"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return
    fi
    read -r seq_len causal q_pos_base kv_pos_base <<< "${metadata_line}"
    if [[ "${causal}" == "1" ]]; then
        mode="causal"
    elif [[ "${causal}" == "0" ]]; then
        mode="noncausal"
    else
        echo "FAIL ${tag}: metadata causal must be 0 or 1, got ${causal}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return
    fi
    if ! case_length_is_selected "${seq_len}"; then
        TOTAL_COUNT=$((TOTAL_COUNT - 1))
        return
    fi

    echo "=== VCS ${tag} (L${seq_len} ${mode}, q_pos=${q_pos_base}, kv_pos=${kv_pos_base}) ==="
    local case_started
    local case_pid
    local case_status
    local case_elapsed
    case_started="$(date +%s)"
    CASE_PATH="${case_path}" \
    CASE_DIR="${case_dir}" \
    BOARD_CASE_TEST_SEQ="${seq_len}" \
    BOARD_CASE_CAUSAL="${causal}" \
    BOARD_CASE_Q_POS_BASE="${q_pos_base}" \
    BOARD_CASE_KV_POS_BASE="${kv_pos_base}" \
    bash VV/scripts/run_tb_attn_top_board_case.sh >"${log_path}" 2>&1 &
    case_pid=$!

    while kill -0 "${case_pid}" 2>/dev/null; do
        sleep "${VCS_HEARTBEAT_SEC}"
        if kill -0 "${case_pid}" 2>/dev/null; then
            case_elapsed=$(( $(date +%s) - case_started ))
            printf '  running %-42s elapsed %s\r' \
                "${tag}" "$(format_elapsed "${case_elapsed}")"
        fi
    done
    wait "${case_pid}" && case_status=0 || case_status=$?
    case_elapsed=$(( $(date +%s) - case_started ))
    printf '%-78s\n' "  finished ${tag} in $(format_elapsed "${case_elapsed}")"

    if [[ "${case_status}" -eq 0 ]]; then
        pass_line="$(grep -m1 "BOARD CASE PASS" "${log_path}" || true)"
        if [[ -n "${pass_line}" ]]; then
            echo "PASS ${tag}: ${pass_line}"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            echo "FAIL ${tag}: simulator exited successfully without PASS marker"
            show_log_tail "${log_path}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    else
        echo "FAIL ${tag}: see ${log_path}"
        show_log_tail "${log_path}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

mapfile -d '' CASE_PATHS < <(
    find "${CASE_ROOT}" -maxdepth 1 -type f -name 'case_*.npz' -print0 | sort -z -V
)
if [[ "${#CASE_PATHS[@]}" -eq 0 ]]; then
    echo "FAIL: no case_*.npz files found in ${CASE_ROOT}" >&2
    exit 2
fi

echo "Board-case VCS regression"
echo "  case root : ${CASE_ROOT}"
if [[ -n "${BOARD_CASE_LENGTHS}" && "${BOARD_CASE_LENGTHS}" != "all" ]]; then
    echo "  lengths   : ${BOARD_CASE_LENGTHS} (filter)"
else
    echo "  lengths   : all discovered cases"
fi
echo "  cases     : ${#CASE_PATHS[@]} discovered"
echo "  log dir   : ${LOG_DIR}"
echo "  license   : ${SNPSLMD_LICENSE_FILE}"

for case_path in "${CASE_PATHS[@]}"; do
    run_case "${case_path}"
done

echo "========================================"
echo "Board-case summary: ${PASS_COUNT}/${TOTAL_COUNT} PASS"
echo "Logs: ${LOG_DIR}"

if [[ "${TOTAL_COUNT}" -eq 0 ]]; then
    echo "Board-case regression FAILED: no cases matched the requested length filter"
    exit 1
fi

if [[ "${FAIL_COUNT}" -ne 0 ]]; then
    echo "Board-case regression FAILED: ${FAIL_COUNT} case(s)"
    exit 1
fi

echo "ALL DISCOVERED BOARD CASES PASSED"
