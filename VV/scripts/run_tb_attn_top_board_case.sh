#!/bin/bash
set -euo pipefail
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY

CASE_PATH="${CASE_PATH:-board_cases_v2.6/case_L128_q3_kv3_causal.npz}"
CASE_DIR="${CASE_DIR:-/tmp/lara_case_l128}"
TEST_SEQ="${BOARD_CASE_TEST_SEQ:-128}"
CASE_CAUSAL="${BOARD_CASE_CAUSAL:-1}"
CASE_Q_POS_BASE="${BOARD_CASE_Q_POS_BASE-}"
CASE_KV_POS_BASE="${BOARD_CASE_KV_POS_BASE-}"
mkdir -p "${CASE_DIR}"

if [[ -z "${CASE_Q_POS_BASE}" || -z "${CASE_KV_POS_BASE}" ]]; then
  case_position_line="$(python3 - "${CASE_PATH}" <<'PY'
import sys
import numpy as np

try:
    with np.load(sys.argv[1]) as data:
        q_pos = int(np.asarray(data["q_pos_base"]).item())
        kv_pos = int(np.asarray(data["kv_pos_base"]).item())
except (KeyError, OSError, ValueError):
    raise SystemExit(1)
print(q_pos, kv_pos)
PY
  )" || case_position_line=""
  if [[ -n "${case_position_line}" ]]; then
    read -r metadata_q_pos metadata_kv_pos <<< "${case_position_line}"
    if [[ -z "${CASE_Q_POS_BASE}" ]]; then
      CASE_Q_POS_BASE="${metadata_q_pos}"
    fi
    if [[ -z "${CASE_KV_POS_BASE}" ]]; then
      CASE_KV_POS_BASE="${metadata_kv_pos}"
    fi
  fi
fi

: "${CASE_Q_POS_BASE:=3}"
: "${CASE_KV_POS_BASE:=3}"

python3 - "${CASE_PATH}" "${CASE_DIR}" <<'PY'
import pathlib
import sys
import numpy as np

case_path = pathlib.Path(sys.argv[1])
out_dir = pathlib.Path(sys.argv[2])
with np.load(case_path) as data:
    tensors = {
        "q": np.asarray(data["q_heads"], dtype=np.uint16).reshape(-1),
        "k": np.asarray(data["k_heads"], dtype=np.uint16).reshape(-1),
        "v": np.asarray(data["v_heads"], dtype=np.uint16).reshape(-1),
        "expected": np.asarray(data["expected_o"], dtype=np.uint16).reshape(-1),
    }
for name, values in tensors.items():
    (out_dir / f"{name}.hex").write_text(
        "".join(f"{int(value):04x}\n" for value in values),
        encoding="ascii",
    )
PY

SIM_DIR="VV/sim/tb_attn_top_board_case_xpm"
XPM_SV="${XPM_SV:-/home/jiao/xilinx/2025.2/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv}"
EXTRA_DEFINES="${LARA_BOARD_CASE_DEFINES:-}"
ACTUAL_ARG=()
if [[ -n "${ACTUAL_PATH:-}" ]]; then
  ACTUAL_ARG=("+ACTUAL_PATH=$(cd "$(dirname "${ACTUAL_PATH}")" && pwd)/$(basename "${ACTUAL_PATH}")")
fi
mkdir -p "${SIM_DIR}"
cd "${SIM_DIR}"
ln -sf ../../data/exp_lut.hex exp_lut.hex
ln -sf ../../data/recip_lut.hex recip_lut.hex
if [[ ! -x simv ]]; then
  rm -f simv.daidir/.vcs.timestamp
fi
rm -f sim.log

vcs -full64 -sverilog -timescale=1ns/1ps +lint=all +v2k \
  +define+SYNTHESIS +define+USE_XPM_MEMORY +define+KV_CACHE_USE_XPM ${EXTRA_DEFINES} \
  -l compile.log \
  +incdir+../../../hw/rtl/pkg \
  "${XPM_SV}" \
  ../../../hw/rtl/pkg/attn_pkg.sv \
  ../../../hw/rtl/core/attn_tile.sv \
  ../../../hw/rtl/core/softmax_engine.sv \
  ../../../hw/rtl/core/softmax_engine_basic.sv \
  ../../../hw/rtl/core/psum_accum.sv \
  ../../../hw/rtl/core/psum_accum_basic.sv \
  ../../../hw/rtl/core/attn_core.sv \
  ../../../hw/rtl/mem/kv_cache_ram.sv \
  ../../../hw/rtl/mem/tile_buffer.sv \
  ../../../hw/rtl/mem/output_buffer.sv \
  ../../../hw/rtl/axi/attn_axi_lite_slave.sv \
  ../../../hw/rtl/axi/attn_axi_stream_sink.sv \
  ../../../hw/rtl/axi/attn_axi_stream_source.sv \
  ../../../hw/rtl/attn_top.sv \
  ../../../VV/tb/tb_attn_top_board_case.sv \
  +define+BOARD_CASE_TEST_SEQ=${TEST_SEQ} \
  -o simv

./simv -no_save +CASE_DIR="$(cd "${CASE_DIR}" && pwd)" \
  +CAUSAL="${CASE_CAUSAL}" \
  +Q_POS_BASE="${CASE_Q_POS_BASE}" \
  +KV_POS_BASE="${CASE_KV_POS_BASE}" \
  "${ACTUAL_ARG[@]}" -l sim.log
grep -q "BOARD CASE PASS" sim.log
echo "ALL BOARD CASE XPM CHECKS PASSED"
