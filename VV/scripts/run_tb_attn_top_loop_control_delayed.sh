#!/bin/bash
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
set -e
export SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE:-27000@archlinux}"
export LM_LICENSE_FILE="${LM_LICENSE_FILE:-$SNPSLMD_LICENSE_FILE}"
TB_NAME="tb_attn_top_loop_control_delayed"
SIM_DIR="VV/sim/${TB_NAME}"
mkdir -p "${SIM_DIR}"

WRAPPER_DIR="$(pwd)/${SIM_DIR}/.gcc_wrapper"
mkdir -p "${WRAPPER_DIR}"
REAL_GCC="$(command -v gcc)"
cat > "${WRAPPER_DIR}/gcc" << GCCEOF
#!/bin/bash
exec ${REAL_GCC} -Wno-error=implicit-function-declaration "\$@"
GCCEOF
chmod +x "${WRAPPER_DIR}/gcc"
export PATH="${WRAPPER_DIR}:${PATH}"

cd "${SIM_DIR}"
ln -sf ../../data data 2>/dev/null || true
vcs -full64 -sverilog -timescale=1ns/1ps +lint=all +v2k \
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

cat > run.tcl << 'TCL'
run
quit
TCL
./simv -no_save -ucli -i run.tcl -l sim.log
echo "${TB_NAME}: DONE"
