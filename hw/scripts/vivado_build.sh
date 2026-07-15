#!/bin/bash
# ============================================================================
# vivado_build.sh — LARA Attention Accelerator for KV260
# ============================================================================
# Usage: cd <project_root> && bash hw/scripts/vivado_build.sh
#
# Prerequisites:
#   - Vivado 2022.2+ (source settings64.sh or add to PATH)
#   - KV260 board files installed (XilinxBoardStore or manual)
#   - Synopsys license NOT required (Vivado has its own)
#
# Output:
#   vivado_proj/deploy/lara_attention.bit
#   vivado_proj/deploy/lara_attention.hwh
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "============================================================"
echo "LARA Attention Accelerator — Vivado Build"
echo "  Project root: ${PROJECT_ROOT}"
echo "  Target:       Kria KV260 (XCK26-SFVC784-2LV-C)"
echo "============================================================"

# --- Vivado 2025.2 setup (Arch Linux) ---
VIVADO_HOME="$HOME/xilinx/2025.2/Vivado"
VIVADO_BIN="${VIVADO_HOME}/bin/vivado"

if [ ! -f "${VIVADO_BIN}" ]; then
    echo "ERROR: vivado not found at ${VIVADO_BIN}"
    echo "  Expected installation: ~/xilinx/2025.2/Vivado/"
    exit 1
fi

# Fix ncurses5 on Arch Linux: Vivado needs libncurses.so.5
# Bundled with Vivado at <install>/lib/lnx64.o/SuSE/
__vivado_lib_path="${VIVADO_HOME}/lib/lnx64.o/SuSE:${VIVADO_HOME}/lib/lnx64.o/Default:${VIVADO_HOME}/lib/lnx64.o"
export LD_LIBRARY_PATH="${__vivado_lib_path}:${LD_LIBRARY_PATH}"

echo "  Vivado: $(${VIVADO_BIN} -version 2>/dev/null | head -1 || echo ${VIVADO_BIN})"

cd "${PROJECT_ROOT}"

# --- Check KV260 board part ---
BOARD_PART=$(grep "set_property.board_part\|BOARD_PART" hw/scripts/vivado_build.tcl 2>/dev/null | head -1 || echo "")
echo "  Board: ${BOARD_PART}"

# --- Clean previous ---
rm -rf vivado_proj .Xil
mkdir -p vivado_proj  # Pre-create so Vivado can write logs immediately

# --- Run Vivado ---
${VIVADO_BIN} -mode batch \
    -source hw/scripts/vivado_build.tcl \
    -log vivado_proj/vivado_build.log \
    -journal vivado_proj/vivado_build.jou
BUILD_STATUS=$?

if [ $BUILD_STATUS -ne 0 ]; then
    echo ""
    echo "============================================================"
    echo " Build FAILED (exit code ${BUILD_STATUS})"
    echo " Check vivado_proj/vivado_build.log for details."
    echo "============================================================"
    exit $BUILD_STATUS
fi

echo ""
echo "============================================================"
echo " Build SUCCESS"
echo " Deploy files: vivado_proj/deploy/"
echo "   lara_attention.bit  — FPGA bitstream"
echo "   lara_attention.hwh  — hardware handoff (for PYNQ)"
echo "   lara_attention.xsa  — XSA export"
PACKAGE_SCRIPT="${PROJECT_ROOT}/hw/scripts/package_kv260.sh"
if [ -f "${PACKAGE_SCRIPT}" ] && bash "${PACKAGE_SCRIPT}"; then
  echo "   board_bundle/       — bit/hwh/xsa + driver + smoke-test guide"
fi
echo ""
echo " To program KV260:"
echo "   scp vivado_proj/deploy/lara_attention.bit root@kv260:/lib/firmware/xilinx/"
echo "   ssh root@kv260 'xmutil unloadapp && xmutil loadapp lara_attention'"
echo "============================================================"
