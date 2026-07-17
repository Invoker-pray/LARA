#!/bin/bash
# run_regression.sh — Full LARA regression suite
# Usage: cd LARA && bash VV/scripts/run_regression.sh
set -e
TESTS="bf16_mac psum_accum attn_tile softmax stream kv_cache_ram output_buffer attn_top attn_top_partial attn_top_loop_control attn_top_loop_control_delayed attn_top_two_tiles attn_top_full_traversal"
SYNTH_TESTS="attn_tile_synth psum_accum_synth softmax_synth"
XPM_TESTS="output_buffer_xpm"
PASS=0; FAIL=0
run_one() {
  local tb="$1"
  local log="/tmp/lara_regression_${tb}.log"
  if bash "VV/scripts/run_tb_${tb}.sh" >"${log}" 2>&1; then
    if grep -q 'ALL.*PASSED' "${log}"; then
      echo "  PASS"
      PASS=$((PASS+1))
      return 0
    fi
  fi
  echo "  FAIL (see ${log})"
  tail -n 12 "${log}" || true
  FAIL=$((FAIL+1))
}

for tb in $TESTS; do
  echo "=== $tb ==="
  run_one "$tb"
done

if [ "${RUN_SYNTH_PATHS:-0}" = "1" ]; then
  for tb in $SYNTH_TESTS; do
    echo "=== $tb ==="
    run_one "$tb"
  done
fi

if [ "${RUN_XPM_PATHS:-0}" = "1" ]; then
  for tb in $XPM_TESTS; do
    echo "=== $tb ==="
    run_one "$tb"
  done
fi
echo "=========================="
echo "Passed: $PASS / $((PASS+FAIL))"
if [ "$FAIL" -eq 0 ]; then
  echo "ALL TESTS PASSED"
else
  echo "SOME TESTS FAILED"
  exit 1
fi
