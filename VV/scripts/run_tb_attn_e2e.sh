#!/bin/bash
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
set -e
TB_NAME="tb_attn_e2e"
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
vcs -full64 -sverilog -timescale=1ns/1ps +lint=all +v2k -l compile.log \
    +incdir+/home/jiao/git/LARA/hw/rtl/pkg \
    /home/jiao/git/LARA/hw/rtl/pkg/attn_pkg.sv \
    /home/jiao/git/LARA/hw/rtl/core/attn_tile.sv \
    /home/jiao/git/LARA/hw/rtl/core/softmax_engine.sv \
    /home/jiao/git/LARA/hw/rtl/core/softmax_engine_basic.sv \
    /home/jiao/git/LARA/hw/rtl/core/psum_accum.sv \
    /home/jiao/git/LARA/hw/rtl/core/psum_accum_basic.sv \
    /home/jiao/git/LARA/hw/rtl/mem/output_buffer.sv \
    /home/jiao/git/LARA/VV/tb/${TB_NAME}.sv \
    -o simv
echo "run 200000ns" > run.tcl; echo "quit" >> run.tcl
./simv -no_save -ucli -i run.tcl -l sim.log
echo "${TB_NAME}: DONE"
