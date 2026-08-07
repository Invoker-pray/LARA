#!/bin/bash
set -euo pipefail
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
export SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE:-27000@127.0.0.1}"
export LM_LICENSE_FILE="${LM_LICENSE_FILE:-$SNPSLMD_LICENSE_FILE}"

SIM_DIR="VV/sim/tb_attn_top_real_request_xpm"
XPM_SV="${XPM_SV:-/home/jiao/xilinx/2025.2/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv}"
mkdir -p "${SIM_DIR}"
cd "${SIM_DIR}"
ln -sf ../../data/exp_lut.hex exp_lut.hex
ln -sf ../../data/recip_lut.hex recip_lut.hex

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
  ../../../VV/tb/tb_attn_top_real_request.sv \
  -o simv

./simv -no_save ${SIM_ARGS:-} -l sim.log
grep -q "REAL REQUEST PATH PASS" sim.log
echo "ALL REAL REQUEST PATH XPM CHECKS PASSED"
