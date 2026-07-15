#!/bin/bash
set -euo pipefail
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
SIM_DIR="VV/sim/tb_sw_hw_control_sink"; mkdir -p "${SIM_DIR}"
cd "${SIM_DIR}"
iverilog -g2012 -s tb_sw_hw_control_sink -I ../../../hw/rtl/pkg -o simv \
  ../../../hw/rtl/pkg/attn_pkg.sv ../../../hw/rtl/axi/attn_axi_stream_sink.sv \
  ../../../VV/tb/tb_sw_hw_control_sink.sv
vvp simv
