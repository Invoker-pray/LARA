#!/bin/bash
# ============================================================================
# run_tb_bf16_mac.sh — VCS compile + run bf16 MAC testbench
# ============================================================================
# Prerequisites:
#   1. lmg            — start Synopsys license service (required before VCS)
#   2. Test vectors    — auto-generated if missing
#
# Usage:
#   bash VV/scripts/run_tb_bf16_mac.sh
#
# Pattern: inherited from ~/git/xx/ CIM capstone simulation flow.
# ============================================================================
set -e
cd "$(dirname "$0")/../.."

echo "============================================"
echo " bf16_mac — VCS Simulation"
echo "============================================"

# --- Step 0: Check prerequisites ---
if ! command -v vcs &> /dev/null; then
    echo "ERROR: vcs not found. Run 'lmg' first to start Synopsys license service."
    exit 1
fi

# --- Step 1: Generate golden test data (if missing) ---
HEX_FILE="VV/data/bf16_mac_vectors.hex"
if [ ! -f "$HEX_FILE" ]; then
    echo "[1/3] Generating golden test vectors..."
    python3 python_godel/attention_golden.py --export-tb-data --module bf16_mac
else
    echo "[1/3] Test vectors already exist: $HEX_FILE"
fi

# --- Step 2: Compile with VCS ---
echo "[2/3] Compiling with VCS..."

vcs -full64 -sverilog \
    +lint=all \
    +v2k \
    -timescale=1ns/1ps \
    +incdir+hw/rtl/pkg \
    hw/rtl/pkg/attn_pkg.sv \
    hw/rtl/core/bf16_mac.sv \
    VV/tb/tb_bf16_mac.sv \
    -o simv_bf16_mac

echo "   Compilation complete."

# --- Step 3: Run simulation ---
echo "[3/3] Running simulation..."
./simv_bf16_mac +vcs+finish

echo ""
echo "============================================"
echo " tb_bf16_mac: DONE"
echo "============================================"
