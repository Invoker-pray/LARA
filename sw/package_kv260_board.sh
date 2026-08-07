#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILD_DIR=${1:-"$ROOT_DIR/vivado_proj/build-20260806T_v4_71p428MHz"}
OUTPUT_DIR=${2:-"$ROOT_DIR/board_payload_v4_71p428MHz"}
OFFLINE_BUNDLE=${3:-"${HOME}/Downloads/kv260-pynq-offline/sd-bundle"}

required=(
  "$BUILD_DIR/deploy/lara_attention.bit"
  "$BUILD_DIR/deploy/lara_attention.hwh"
  "$BUILD_DIR/deploy/lara_attention.xsa"
  "$ROOT_DIR/sw/attn_driver.py"
  "$ROOT_DIR/sw/clear_pynq_cache.py"
  "$ROOT_DIR/sw/board_test.py"
  "$ROOT_DIR/sw/board_matrix.py"
  "$ROOT_DIR/sw/board_performance.py"
  "$ROOT_DIR/sw/run_board_full_validation.py"
  "$ROOT_DIR/sw/kv260_pynq_offline_install.sh"
  "$OFFLINE_BUNDLE/src/pynq-3.0.1.tar.gz"
  "$OFFLINE_BUNDLE/src/pynq-v3.0-binaries.tar.gz"
  "$OFFLINE_BUNDLE/OFFLINE_SHA256SUMS"
  "$OFFLINE_BUNDLE/wheels"
  "$OFFLINE_BUNDLE/Kria-PYNQ/dts/pynq.dtbo"
  "$OFFLINE_BUNDLE/Kria-PYNQ/dts/insert_dtbo.py"
)
for path in "${required[@]}"; do
  if [[ ! -e "$path" ]]; then
    echo "ERROR: required deployment input is missing: $path" >&2
    exit 2
  fi
done

if ! (cd "$OFFLINE_BUNDLE" && sha256sum -c OFFLINE_SHA256SUMS >/dev/null); then
  echo "ERROR: offline runtime bundle failed its source manifest: $OFFLINE_BUNDLE" >&2
  exit 2
fi

if [[ -e "$OUTPUT_DIR" ]] && find "$OUTPUT_DIR" -mindepth 1 -print -quit | grep -q .; then
  echo "ERROR: output directory is not empty: $OUTPUT_DIR" >&2
  echo "Choose a new output directory so stale files cannot enter the SD-card payload." >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIR"
cp -a "$BUILD_DIR/deploy/lara_attention.bit" "$OUTPUT_DIR/"
cp -a "$BUILD_DIR/deploy/lara_attention.hwh" "$OUTPUT_DIR/"
cp -a "$BUILD_DIR/deploy/lara_attention.xsa" "$OUTPUT_DIR/"
cp -a \
  "$ROOT_DIR/sw/attn_driver.py" \
  "$ROOT_DIR/sw/clear_pynq_cache.py" \
  "$ROOT_DIR/sw/board_test.py" \
  "$ROOT_DIR/sw/board_matrix.py" \
  "$ROOT_DIR/sw/board_performance.py" \
  "$ROOT_DIR/sw/run_board_full_validation.py" \
  "$OUTPUT_DIR/"
chmod 0755 "$OUTPUT_DIR/clear_pynq_cache.py" "$OUTPUT_DIR/run_board_full_validation.py"
cp -a "$ROOT_DIR/docs/kv260_board_validation.md" "$OUTPUT_DIR/"

mkdir -p "$OUTPUT_DIR/offline/src" "$OUTPUT_DIR/offline/wheels" \
  "$OUTPUT_DIR/offline/Kria-PYNQ/dts" "$OUTPUT_DIR/offline/scripts"
cp -a "$OFFLINE_BUNDLE/src/pynq-3.0.1.tar.gz" \
  "$OFFLINE_BUNDLE/src/pynq-v3.0-binaries.tar.gz" \
  "$OUTPUT_DIR/offline/src/"
cp -a "$OFFLINE_BUNDLE/wheels/." "$OUTPUT_DIR/offline/wheels/"
cp -a "$OFFLINE_BUNDLE/Kria-PYNQ/dts/pynq.dtbo" \
  "$OFFLINE_BUNDLE/Kria-PYNQ/dts/insert_dtbo.py" \
  "$OUTPUT_DIR/offline/Kria-PYNQ/dts/"
cp -a "$ROOT_DIR/sw/kv260_pynq_offline_install.sh" "$OUTPUT_DIR/offline/scripts/"
chmod 0755 "$OUTPUT_DIR/offline/scripts/kv260_pynq_offline_install.sh"

(
  cd "$OUTPUT_DIR/offline"
  find . -type f ! -name OFFLINE_SHA256SUMS -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 sha256sum > OFFLINE_SHA256SUMS
)

(
  cd "$OUTPUT_DIR"
  find . -type f ! -name LARA_SHA256SUMS -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 sha256sum > LARA_SHA256SUMS
)

echo "KV260 payload: $OUTPUT_DIR"
echo "Files: $(find "$OUTPUT_DIR" -type f | wc -l)"
echo "Offline runtime source: $OFFLINE_BUNDLE"
echo "Test cases: not included; generate and add them manually after packaging."
echo "Manual case copy:"
echo "  cp -a \"$ROOT_DIR/board_cases_rtl_contract_v2.6_fixed\" \"$OUTPUT_DIR/\""
echo "  cp -a \"$ROOT_DIR/board_cases_rtl_contract_v2.6_q31_kv7\" \"$OUTPUT_DIR/\""
echo "Refresh LARA_SHA256SUMS after adding any files:"
echo "  (cd \"$OUTPUT_DIR\" && find . -type f ! -name LARA_SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > LARA_SHA256SUMS)"
echo "Verify before copying to the board: cd \"$OUTPUT_DIR\" && sha256sum -c LARA_SHA256SUMS"
echo "Verify on the board: cd <target>/lara && sha256sum -c LARA_SHA256SUMS"
