#!/bin/bash
set -euo pipefail

extra_args="+FULL_REAL"
if [[ -n "${SIM_ARGS:-}" ]]; then
  extra_args+=" ${SIM_ARGS}"
fi

SIM_ARGS="${extra_args}" bash VV/scripts/run_tb_attn_top_real_request.sh
