#!/bin/bash
# run_tb_kv_cache_ram.sh — VCS simulation for kv_cache_ram
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
set -e

TB_NAME="tb_kv_cache_ram"
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

cd "${SIM_DIR}"

vcs -full64 -sverilog \
    -timescale=1ns/1ps \
    +lint=all \
    +v2k \
    -l compile.log \
    +incdir+../../../hw/rtl/pkg \
    ../../../hw/rtl/pkg/attn_pkg.sv \
    ../../../hw/rtl/mem/kv_cache_ram.sv \
    ../../../VV/tb/${TB_NAME}.sv \
    -o simv

cat > run.tcl << 'TCL'
run 100000ns
quit
TCL
./simv -no_save -ucli -i run.tcl -l sim.log
echo "${TB_NAME}: DONE"
