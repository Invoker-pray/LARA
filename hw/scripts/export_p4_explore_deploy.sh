#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VIVADO_HOME="${HOME}/xilinx/2025.2/Vivado"
VIVADO_BIN="${VIVADO_HOME}/bin/vivado"

test -x "${VIVADO_BIN}" || {
  echo "ERROR: Vivado not found at ${VIVADO_BIN}" >&2
  exit 1
}
export LD_LIBRARY_PATH="${VIVADO_HOME}/lib/lnx64.o/SuSE:${VIVADO_HOME}/lib/lnx64.o/Default:${VIVADO_HOME}/lib/lnx64.o:${LD_LIBRARY_PATH:-}"
cd "${ROOT_DIR}"
"${VIVADO_BIN}" -mode batch \
  -source hw/scripts/export_p4_explore_deploy.tcl \
  -log vivado_proj/export_p4_explore_deploy.log \
  -journal vivado_proj/export_p4_explore_deploy.jou

(
  cd vivado_proj/p4-explore-deploy
  sha256sum lara_attention.bit lara_attention.hwh lara_attention.xsa reports/*.rpt > SHA256SUMS
)
echo "Deployment artifacts: vivado_proj/p4-explore-deploy/"
