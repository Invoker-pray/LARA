#!/bin/bash
set -euo pipefail
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
export SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE:-27000@127.0.0.1}"
export LM_LICENSE_FILE="${LM_LICENSE_FILE:-$SNPSLMD_LICENSE_FILE}"

XPM_SV="${XPM_SV:-/home/jiao/xilinx/2025.2/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv}"
SIM_DIR="VV/sim/tb_output_buffer_rows_xpm"
mkdir -p "${SIM_DIR}"
cd "${SIM_DIR}"
ln -sf ../../../VV/data/recip_lut.hex recip_lut.hex

vcs -full64 -sverilog -timescale=1ns/1ps +lint=all +v2k \
  +define+SYNTHESIS +define+USE_XPM_MEMORY \
  -l compile.log \
  +incdir+../../../hw/rtl/pkg \
  "${XPM_SV}" \
  ../../../hw/rtl/pkg/attn_pkg.sv \
  ../../../hw/rtl/mem/output_buffer.sv \
  ../../../VV/tb/tb_output_buffer_rows.sv \
  -o simv

./simv -no_save -l sim.log
grep -q "OUTPUT BUFFER ROWS PASS" sim.log
echo "OUTPUT BUFFER ROWS XPM CHECK PASSED"
