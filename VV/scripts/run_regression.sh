#!/bin/bash
# run_regression.sh — Full LARA regression suite
# Usage: cd LARA && bash VV/scripts/run_regression.sh
set -e
TESTS="bf16_mac psum_accum attn_tile softmax stream kv_cache_ram output_buffer attn_top attn_top_partial attn_top_loop_control attn_top_loop_control_delayed attn_top_two_tiles attn_top_full_traversal"
SYNTH_TESTS="attn_tile_synth psum_accum_synth softmax_synth"
XPM_TESTS="output_buffer_xpm"
PASS=0; FAIL=0
for tb in $TESTS; do
  echo "=== $tb ==="
  if bash VV/scripts/run_tb_${tb}.sh 2>&1 | grep -q 'ALL.*PASSED'; then
    echo "  PASS"; PASS=$((PASS+1))
  else
    echo "  FAIL"; FAIL=$((FAIL+1))
  fi
done

if [ "${RUN_SYNTH_PATHS:-0}" = "1" ]; then
  for tb in $SYNTH_TESTS; do
    echo "=== $tb ==="
    if bash VV/scripts/run_tb_${tb}.sh 2>&1 | grep -q 'ALL.*PASSED'; then
      echo "  PASS"; PASS=$((PASS+1))
    else
      echo "  FAIL"; FAIL=$((FAIL+1))
    fi
  done
fi

if [ "${RUN_XPM_PATHS:-0}" = "1" ]; then
  for tb in $XPM_TESTS; do
    echo "=== $tb ==="
    if bash VV/scripts/run_tb_${tb}.sh 2>&1 | grep -q 'ALL.*PASSED'; then
      echo "  PASS"; PASS=$((PASS+1))
    else
      echo "  FAIL"; FAIL=$((FAIL+1))
    fi
  done
fi
echo "=========================="
echo "Passed: $PASS / $((PASS+FAIL))"
[ $FAIL -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
