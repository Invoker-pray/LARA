#!/bin/bash
# run_tb_attn_top_xpm.sh — full-top VCS simulation with XPM-backed caches
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
set -e
export SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE:-27000@archlinux}"
export LM_LICENSE_FILE="${LM_LICENSE_FILE:-$SNPSLMD_LICENSE_FILE}"

TB_NAME="tb_attn_top"
SIM_DIR="VV/sim/${TB_NAME}_xpm"
XPM_SV="${XPM_SV:-/home/jiao/xilinx/2025.2/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv}"

if [ ! -f "${XPM_SV}" ]; then
    echo "ERROR: XPM source not found: ${XPM_SV}" >&2
    exit 1
fi

mkdir -p "${SIM_DIR}"
cd "${SIM_DIR}"

if [ ! -x simv ] && [ -f simv.daidir/.vcs.timestamp ]; then
    rm -f simv.daidir/.vcs.timestamp
fi

vcs -full64 -sverilog -timescale=1ns/1ps +lint=all +v2k \
    +define+SYNTHESIS +define+KV_CACHE_USE_XPM \
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
    ../../../VV/tb/${TB_NAME}.sv \
    -o simv

./simv -no_save ${DIRECT_ARGS:-} ${SIM_ARGS:-} \
    +DUMP_BITS="$(pwd)/outputs.bits" -l sim.log
if [ -z "${SIM_ARGS:-}" ]; then
    grep -q "ALL ATTN_TOP CHECKS PASSED" sim.log
    echo "ALL ATTN_TOP XPM CHECKS PASSED"
else
    echo "tb_attn_top_xpm diagnostic run completed"
fi
