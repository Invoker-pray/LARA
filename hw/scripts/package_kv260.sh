#!/usr/bin/env bash
# Package the reproducible KV260 deployment bundle after a successful build.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY_DIR="${ROOT_DIR}/vivado_proj/deploy"
REPORT_DIR="${ROOT_DIR}/vivado_proj/reports"
BUNDLE_DIR="${ROOT_DIR}/vivado_proj/board_bundle"

for artifact in lara_attention.bit lara_attention.hwh lara_attention.xsa; do
  test -s "${DEPLOY_DIR}/${artifact}" || {
    echo "ERROR: missing deployment artifact ${DEPLOY_DIR}/${artifact}" >&2
    exit 1
  }
done

REPORT_FILES=(
  post_route_timing_summary.rpt
  post_route_status.rpt
  post_route_utilization.rpt
  post_route_drc.rpt
)
for report in "${REPORT_FILES[@]}"; do
  test -s "${REPORT_DIR}/${report}" || {
    echo "ERROR: missing signoff report ${REPORT_DIR}/${report}" >&2
    exit 1
  }
done

rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}/sw" "${BUNDLE_DIR}/docs" "${BUNDLE_DIR}/reports"
cp "${DEPLOY_DIR}"/lara_attention.{bit,hwh,xsa} "${BUNDLE_DIR}/"
cp "${REPORT_FILES[@]/#/${REPORT_DIR}/}" "${BUNDLE_DIR}/reports/"
cp "${ROOT_DIR}/sw/attn_driver.py" "${ROOT_DIR}/sw/host_attention.py" "${ROOT_DIR}/sw/board_test.py" "${BUNDLE_DIR}/sw/"
cp "${ROOT_DIR}/docs/kv260_board_validation.md" "${BUNDLE_DIR}/docs/"
(cd "${BUNDLE_DIR}" && sha256sum lara_attention.bit lara_attention.hwh lara_attention.xsa reports/*.rpt > SHA256SUMS)
printf 'LARA KV260 board bundle: %s\n' "${BUNDLE_DIR}"
