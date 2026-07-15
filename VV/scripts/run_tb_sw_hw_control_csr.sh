#!/bin/bash
set -euo pipefail
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
SIM_DIR="VV/sim/tb_sw_hw_control_csr"; mkdir -p "${SIM_DIR}"
cd "${SIM_DIR}"
iverilog -g2012 -s tb_sw_hw_control_csr -I ../../../hw/rtl/pkg -o simv \
  ../../../hw/rtl/pkg/attn_pkg.sv ../../../hw/rtl/axi/attn_axi_lite_slave.sv \
  ../../../VV/tb/tb_sw_hw_control_csr.sv
vvp simv
