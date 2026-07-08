#!/bin/bash
# run_tb_softmax.sh — VCS simulation for softmax_engine
# Usage: cd LARA && bash VV/scripts/run_tb_softmax.sh
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
set -e
TB_NAME="tb_softmax"
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

# Generate test vectors if missing  
if [ ! -f "VV/data/softmax_vectors.hex" ]; then
    echo "[Pre] Generating test vectors + EXP LUT..."
    cd python_godel && python3 -c "
import numpy as np, os, sys; sys.path.insert(0, '.')
from attention_golden import *
np.random.seed(42); n_rows, n_cols = 16, 16
S = np.random.randn(n_rows, n_cols).astype(np.float32) * 2.0
S_s = (S / np.sqrt(HEAD_DIM)).astype(np.float32)
m = np.full(n_rows, -np.inf, dtype=np.float32); l = np.zeros(n_rows, dtype=np.float32)
lut = build_exp_lut()
row_max = S_s.max(axis=1); m_new = np.maximum(m, row_max)
correction = exp_lut_lookup(m - m_new, lut)
P_online = exp_lut_lookup(S_s - m_new[:, np.newaxis], lut)
l_new = l * correction + P_online.sum(axis=1)
os.makedirs('../VV/data', exist_ok=True)
with open('../VV/data/softmax_vectors.hex', 'w') as f:
    for i in range(n_rows):
        f.write(' '.join(f'{S[i,j].view(np.uint32):08x}' for j in range(n_cols)) + '\n')
    f.write(' '.join(f'{m_new[i].view(np.uint32):08x}' for i in range(n_rows)) + '\n')
    f.write(' '.join(f'{l_new[i].view(np.uint32):08x}' for i in range(n_rows)) + '\n')
    for i in range(n_rows):
        f.write(' '.join(f'{P_online[i,j].view(np.uint32):08x}' for j in range(n_cols)) + '\n')
    f.write(' '.join(f'{correction[i].view(np.uint32):08x}' for i in range(n_rows)) + '\n')
with open('../VV/data/exp_lut.hex', 'w') as f:
    for i in range(EXP_LUT_DEPTH):
        f.write(f'{lut[i].view(np.uint32):08x}\n')
print('Generated test vectors + EXP LUT')
" && cd ..
fi

echo "Compiling ${TB_NAME}..."
cd "${SIM_DIR}"
ln -sf ../../data data

vcs -full64 -sverilog -timescale=1ns/1ps +lint=all +v2k \
    -l compile.log \
    +incdir+../../../hw/rtl/pkg \
    ../../../hw/rtl/pkg/attn_pkg.sv \
    ../../../hw/rtl/core/softmax_engine.sv \
    ../../../VV/tb/${TB_NAME}.sv \
    -o simv

echo "Running..."
cat > run.tcl << 'TCL'
run 5000ns
quit
TCL
./simv -no_save -ucli -i run.tcl -l sim.log
echo "${TB_NAME}: DONE"
