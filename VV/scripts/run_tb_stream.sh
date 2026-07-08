#!/bin/bash
# run_tb_stream.sh — VCS simulation for AXI Stream sink+source test
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
set -e
TB_NAME="tb_stream"
SIM_DIR="VV/sim/${TB_NAME}"
mkdir -p "${SIM_DIR}"
WRAPPER_DIR="$(pwd)/${SIM_DIR}/.gcc_wrapper"
mkdir -p "${WRAPPER_DIR}"
REAL_GCC="$(command -v gcc)"
cat > "${WRAPPER_DIR}/gcc" << EOF
#!/bin/bash
exec ${REAL_GCC} -Wno-error=implicit-function-declaration "\$@"
EOF
chmod +x "${WRAPPER_DIR}/gcc"
export PATH="${WRAPPER_DIR}:${PATH}"
echo "Compiling ${TB_NAME}..."
cd "${SIM_DIR}"
ln -sf ../../data data 2>/dev/null || true
vcs -full64 -sverilog -timescale=1ns/1ps +lint=all +v2k -l compile.log \
    +incdir+/home/jiao/git/LARA/hw/rtl/pkg \
    /home/jiao/git/LARA/hw/rtl/pkg/attn_pkg.sv \
    /home/jiao/git/LARA/hw/rtl/axi/attn_axi_stream_sink.sv \
    /home/jiao/git/LARA/hw/rtl/axi/attn_axi_stream_source.sv \
    /home/jiao/git/LARA/VV/tb/${TB_NAME}.sv \
    -o simv
echo "Running..."
cat > run.tcl << 'TCL'
run 50000ns
quit
TCL
./simv -no_save -ucli -i run.tcl -l sim.log
echo "${TB_NAME}: DONE"
