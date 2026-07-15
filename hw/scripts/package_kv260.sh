#!/usr/bin/env bash
# Package the reproducible KV260 deployment bundle after a successful build.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY_DIR="${ROOT_DIR}/vivado_proj/deploy"
BUNDLE_DIR="${ROOT_DIR}/vivado_proj/board_bundle"

for artifact in lara_attention.bit lara_attention.hwh lara_attention.xsa; do
  test -s "${DEPLOY_DIR}/${artifact}" || {
    echo "ERROR: missing deployment artifact ${DEPLOY_DIR}/${artifact}" >&2
    exit 1
  }
done

rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}/sw" "${BUNDLE_DIR}/docs"
cp "${DEPLOY_DIR}"/lara_attention.{bit,hwh,xsa} "${BUNDLE_DIR}/"
cp "${ROOT_DIR}/sw/attn_driver.py" "${ROOT_DIR}/sw/host_attention.py" "${ROOT_DIR}/sw/board_test.py" "${BUNDLE_DIR}/sw/"
cp "${ROOT_DIR}/docs/kv260_board_validation.md" "${BUNDLE_DIR}/docs/"
(cd "${BUNDLE_DIR}" && sha256sum lara_attention.bit lara_attention.hwh lara_attention.xsa > SHA256SUMS)
printf 'LARA KV260 board bundle: %s\n' "${BUNDLE_DIR}"
