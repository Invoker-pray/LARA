#!/bin/bash
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
set -e
export SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE:-27000@archlinux}"
export LM_LICENSE_FILE="${LM_LICENSE_FILE:-$SNPSLMD_LICENSE_FILE}"
TB_NAME="tb_softmax"
SIM_DIR="VV/sim/${TB_NAME}_synth"
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

if [ ! -f "VV/data/softmax_vectors.hex" ]; then
    bash VV/scripts/run_tb_softmax.sh >/dev/null
fi

cd "${SIM_DIR}"
ln -sf ../../data data
ln -sf ../../data/exp_lut.hex exp_lut.hex
vcs -full64 -sverilog -timescale=1ns/1ps +lint=all +v2k +define+SYNTHESIS \
    -l compile.log \
    +incdir+../../../hw/rtl/pkg \
    ../../../hw/rtl/pkg/attn_pkg.sv \
    ../../../hw/rtl/core/softmax_engine.sv \
    ../../../VV/tb/${TB_NAME}.sv \
    -o simv

cat > run.tcl << 'TCL'
run 50000ns
quit
TCL
./simv -no_save -ucli -i run.tcl -l sim.log
echo "${TB_NAME}_synth: DONE"
