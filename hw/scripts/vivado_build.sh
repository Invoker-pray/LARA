#!/bin/bash
set -euo pipefail
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
#   vivado_proj/build-<UTC timestamp>/deploy/{lara_attention.bit,hwh,xsa}
#   Existing vivado_proj/ evidence is never removed or overwritten.
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
export LD_LIBRARY_PATH="${__vivado_lib_path}:${LD_LIBRARY_PATH:-}"

echo "  Vivado: $(${VIVADO_BIN} -version 2>/dev/null | head -1 || echo ${VIVADO_BIN})"

cd "${PROJECT_ROOT}"

BUILD_START_EPOCH=$(date +%s)
BUILD_START_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
BUILD_TAG="${LARA_BUILD_TAG:-$(date -u '+%Y%m%dT%H%M%SZ')}"
BUILD_DIR="${LARA_OUT_DIR:-vivado_proj/build-${BUILD_TAG}}"
if [[ "${BUILD_DIR}" != /* ]]; then
  BUILD_DIR="${PROJECT_ROOT}/${BUILD_DIR}"
fi
if [[ -e "${BUILD_DIR}" ]]; then
  echo "ERROR: build output already exists: ${BUILD_DIR}" >&2
  echo "       Set LARA_OUT_DIR to a new directory; existing evidence is preserved." >&2
  exit 1
fi
mkdir -p "${BUILD_DIR}"
export LARA_OUT_DIR="${BUILD_DIR}"
export LARA_ROUTE_DIRECTIVE="${LARA_ROUTE_DIRECTIVE:-Explore}"

VIVADO_PROCESS_PATTERN='(^|/)(vivado|task_worker)([[:space:]]|$)'
if pgrep -af "${VIVADO_PROCESS_PATTERN}" >/dev/null 2>&1; then
  echo "ERROR: another Vivado build process is already running." >&2
  pgrep -af "${VIVADO_PROCESS_PATTERN}" >&2 || true
  exit 1
fi

{
  echo "build_tag=${BUILD_TAG}"
  echo "build_dir=${BUILD_DIR}"
  echo "route_directive=${LARA_ROUTE_DIRECTIVE}"
  echo "vivado=${VIVADO_BIN}"
  echo -n "git_head="
  git rev-parse HEAD 2>/dev/null || echo unknown
  echo "git_status:"
  git status --short 2>/dev/null || true
} > "${BUILD_DIR}/build_metadata.txt"

report_build_timing() {
  local end_epoch end_utc elapsed
  end_epoch=$(date +%s)
  end_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  elapsed=$((end_epoch - BUILD_START_EPOCH))
  echo "  Build started (UTC): ${BUILD_START_UTC}"
  echo "  Build ended   (UTC): ${end_utc}"
  echo "  Build elapsed      : ${elapsed}s ($(printf '%02d:%02d:%02d' $((elapsed / 3600)) $(((elapsed / 60) % 60)) $((elapsed % 60))))"
}

echo "  Build started (UTC): ${BUILD_START_UTC}"
echo "  Build output       : ${BUILD_DIR}"
echo "  Route directive    : ${LARA_ROUTE_DIRECTIVE}"

# --- Check KV260 board part ---
BOARD_PART=$(grep "set_property.board_part\|BOARD_PART" hw/scripts/vivado_build.tcl 2>/dev/null | head -1 || echo "")
echo "  Board: ${BOARD_PART}"

# --- Run Vivado ---
if "${VIVADO_BIN}" -mode batch \
    -source hw/scripts/vivado_build.tcl \
    -log "${BUILD_DIR}/vivado_build.log" \
    -journal "${BUILD_DIR}/vivado_build.jou"; then
  BUILD_STATUS=0
else
  BUILD_STATUS=$?
fi

if [ $BUILD_STATUS -ne 0 ]; then
  echo ""
  echo "============================================================"
  echo " Build FAILED (exit code ${BUILD_STATUS})"
  echo " Check ${BUILD_DIR}/vivado_build.log for details."
  report_build_timing
  echo "============================================================"
  exit $BUILD_STATUS
fi

if [ "${LARA_STOP_AFTER_SYNTH:-0}" = "1" ]; then
    echo ""
  echo "============================================================"
  echo " Synthesis-only build SUCCESS"
  echo " Reports: ${BUILD_DIR}/reports/"
  report_build_timing
  echo "============================================================"
  exit 0
fi

for artifact in lara_attention.bit lara_attention.hwh lara_attention.xsa; do
  if [ ! -s "${BUILD_DIR}/deploy/${artifact}" ]; then
    echo "ERROR: successful Vivado run did not produce ${BUILD_DIR}/deploy/${artifact}" >&2
    report_build_timing
    exit 1
  fi
done
(
  cd "${BUILD_DIR}"
  sha256sum deploy/lara_attention.bit \
            deploy/lara_attention.hwh \
            deploy/lara_attention.xsa \
            reports/post_route_*.rpt > SHA256SUMS
)

echo ""
echo "============================================================"
echo " Build SUCCESS"
echo " Deploy files: ${BUILD_DIR}/deploy/"
report_build_timing
echo "   lara_attention.bit  — FPGA bitstream"
echo "   lara_attention.hwh  — hardware handoff (for PYNQ)"
echo "   lara_attention.xsa  — XSA export"
echo ""
echo " To program KV260:"
echo "   scp ${BUILD_DIR}/deploy/lara_attention.bit root@kv260:/lib/firmware/xilinx/"
echo "   ssh root@kv260 'xmutil unloadapp && xmutil loadapp lara_attention'"
echo "============================================================"
