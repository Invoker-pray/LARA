#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VIVADO_HOME="${HOME}/xilinx/2025.2/Vivado"
VIVADO_BIN="${VIVADO_HOME}/bin/vivado"

if [ $# -ne 1 ]; then
  echo "Usage: bash hw/scripts/export_build_deploy_from_routed.sh <build-dir>" >&2
  exit 1
fi

BUILD_DIR="$1"
if [[ "${BUILD_DIR}" != /* ]]; then
  BUILD_DIR="${ROOT_DIR}/${BUILD_DIR}"
fi

test -x "${VIVADO_BIN}" || {
  echo "ERROR: Vivado not found at ${VIVADO_BIN}" >&2
  exit 1
}

export LD_LIBRARY_PATH="${VIVADO_HOME}/lib/lnx64.o/SuSE:${VIVADO_HOME}/lib/lnx64.o/Default:${VIVADO_HOME}/lib/lnx64.o:${LD_LIBRARY_PATH:-}"
export LARA_EXPORT_BUILD_DIR="${BUILD_DIR}"

cd "${ROOT_DIR}"
"${VIVADO_BIN}" -mode batch \
  -source hw/scripts/export_build_deploy_from_routed.tcl \
  -log "${BUILD_DIR}/export_build_deploy.log" \
  -journal "${BUILD_DIR}/export_build_deploy.jou"

(
  cd "${BUILD_DIR}"
  sha256sum deploy/lara_attention.bit \
            deploy/lara_attention.hwh \
            deploy/lara_attention.xsa \
            reports/post_route_*.rpt > SHA256SUMS
)

echo "Deployment artifacts: ${BUILD_DIR}/deploy/"
