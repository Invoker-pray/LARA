#!/bin/bash
# Continue the current Vivado project from completed synthesis through routing.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VIVADO_HOME="$HOME/xilinx/2025.2/Vivado"
VIVADO_BIN="${VIVADO_HOME}/bin/vivado"

if [ ! -f "${VIVADO_BIN}" ]; then
    echo "ERROR: vivado not found at ${VIVADO_BIN}"
    exit 1
fi

__vivado_lib_path="${VIVADO_HOME}/lib/lnx64.o/SuSE:${VIVADO_HOME}/lib/lnx64.o/Default:${VIVADO_HOME}/lib/lnx64.o"
export LD_LIBRARY_PATH="${__vivado_lib_path}:${LD_LIBRARY_PATH}"

cd "${PROJECT_ROOT}"
if [ ! -f vivado_proj/lara_attention.xpr ]; then
    echo "ERROR: matching synthesized project is missing: vivado_proj/lara_attention.xpr"
    exit 1
fi

echo "============================================================"
echo "LARA streaming-PV — continue matching Vivado implementation"
echo "  Project root: ${PROJECT_ROOT}"
echo "  Project:      vivado_proj/lara_attention.xpr"
echo "============================================================"

"${VIVADO_BIN}" -mode batch \
    -source hw/scripts/vivado_continue_impl.tcl \
    -log vivado_proj/vivado_continue_impl.log \
    -journal vivado_proj/vivado_continue_impl.jou

echo "============================================================"
echo "Matching implementation command completed"
echo "Reports: vivado_proj/reports/"
echo "============================================================"
