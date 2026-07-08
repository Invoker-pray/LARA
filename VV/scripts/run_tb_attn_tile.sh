#!/bin/bash
# ============================================================================
# run_tb_attn_tile.sh — VCS simulation for attn_tile MAC array test
# ============================================================================
# Usage: cd LARA && bash VV/scripts/run_tb_attn_tile.sh
# Output: VV/sim/tb_attn_tile/
# ============================================================================

unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
set -e

TB_NAME="tb_attn_tile"
SIM_DIR="VV/sim/${TB_NAME}"
mkdir -p "${SIM_DIR}"

# GCC 15+ wrapper
WRAPPER_DIR="$(pwd)/${SIM_DIR}/.gcc_wrapper"
mkdir -p "${WRAPPER_DIR}"
REAL_GCC="$(command -v gcc)"
cat > "${WRAPPER_DIR}/gcc" << EOF
#!/bin/bash
exec ${REAL_GCC} -Wno-error=implicit-function-declaration "\$@"
EOF
chmod +x "${WRAPPER_DIR}/gcc"
export PATH="${WRAPPER_DIR}:${PATH}"

# Generate test vectors if missing
if [ ! -f "VV/data/attn_tile_vectors.hex" ]; then
    echo "[Pre] Generating golden test vectors..."
    python3 python_godel/attention_golden.py --export-tb-data --module attn_tile
fi

echo "============================================================"
echo "Compiling ${TB_NAME} with VCS..."
echo "============================================================"

cd "${SIM_DIR}"

# Symlink to data directory
ln -sf ../../../VV/data data

vcs -full64 -sverilog \
    -timescale=1ns/1ps \
    +lint=all \
    +v2k \
    -l compile.log \
    +incdir+../../../hw/rtl/pkg \
    ../../../hw/rtl/pkg/attn_pkg.sv \
    ../../../hw/rtl/core/attn_tile.sv \
    ../../../VV/tb/${TB_NAME}.sv \
    -o simv

echo "============================================================"
echo "Running simulation..."
echo "============================================================"

cat > run.tcl << 'TCL'
run 5000ns
quit
TCL
./simv -no_save -ucli -i run.tcl -l sim.log

echo ""
echo "============================================================"
echo "${TB_NAME}: DONE"
echo "Logs in ${SIM_DIR}/"
echo "============================================================"
