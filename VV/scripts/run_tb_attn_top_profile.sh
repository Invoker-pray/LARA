#!/bin/bash
# Synthesis-path whole-main-loop cycle profile for P4 DSE.
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
set -e
export SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE:-27000@archlinux}"
export LM_LICENSE_FILE="${LM_LICENSE_FILE:-$SNPSLMD_LICENSE_FILE}"

TB_NAME="tb_attn_top"
SIM_DIR="VV/sim/${TB_NAME}_profile"
mkdir -p "${SIM_DIR}"
cd "${SIM_DIR}"
ln -sf ../../data data
ln -sf ../../data/exp_lut.hex exp_lut.hex
ln -sf ../../data/recip_lut.hex recip_lut.hex

vcs -full64 -sverilog -timescale=1ns/1ps +lint=all +v2k \
    +define+SYNTHESIS \
    -l compile.log \
    +incdir+../../../hw/rtl/pkg \
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

./simv -no_save +DUMP_BITS="$(pwd)/outputs.bits" -l sim.log
grep -q "MAINLOOP_PROFILE" sim.log
grep -q "ALL ATTN_TOP CHECKS PASSED" sim.log
echo "ALL ATTN_TOP SYNTHESIS-PATH PROFILE CHECKS PASSED"
