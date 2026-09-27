#!/bin/bash
set -euo pipefail
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
export SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE:-27000@127.0.0.1}"
export LM_LICENSE_FILE="${LM_LICENSE_FILE:-$SNPSLMD_LICENSE_FILE}"

SIM_DIR="VV/sim/tb_attn_top_real_request_xpm"
XPM_SV="${XPM_SV:-/home/jiao/xilinx/2025.2/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv}"
mkdir -p "${SIM_DIR}"
cd "${SIM_DIR}"
ln -sf ../../data/exp_lut.hex exp_lut.hex
ln -sf ../../data/recip_lut.hex recip_lut.hex

vcs -full64 -sverilog -timescale=1ns/1ps +lint=all +v2k \
  +define+SYNTHESIS +define+KV_CACHE_USE_XPM \
  -l compile.log \
  +incdir+../../../hw/rtl/pkg \
  "${XPM_SV}" \
  ../../../hw/rtl/pkg/attn_pkg.sv \
  ../../../hw/rtl/core/attn_tile.sv \
  ../../../hw/rtl/core/softmax_engine.sv \
  ../../../hw/rtl/core/softmax_engine_basic.sv \
  ../../../hw/rtl/core/psum_accum.sv \
  ../../../hw/rtl/core/psum_accum_basic.sv \
  ../../../hw/rtl/core/attn_core.sv \
  ../../../hw/rtl/mem/kv_cache_ram.sv \
  ../../../hw/rtl/mem/tile_buffer.sv \
  ../../../hw/rtl/mem/output_buffer.sv \
  ../../../hw/rtl/axi/attn_axi_lite_slave.sv \
  ../../../hw/rtl/axi/attn_axi_stream_sink.sv \
  ../../../hw/rtl/axi/attn_axi_stream_source.sv \
  ../../../hw/rtl/attn_top.sv \
  ../../../VV/tb/tb_attn_top_real_request.sv \
  -o simv

./simv -no_save ${SIM_ARGS:-} -l sim.log
grep -q "REAL REQUEST PATH PASS" sim.log
./simv -no_save ${SIM_ARGS:-} +DESC_QUEUE -l sim_desc_queue.log
grep -q "transport=descriptor-batch" sim_desc_queue.log
./simv -no_save ${SIM_ARGS:-} +INBAND_COMMAND -l sim_inband.log
grep -q "inband-stream" sim_inband.log
./simv -no_save ${SIM_ARGS:-} +IRQ_PROTOCOL +IRQ_LATENCY_CYCLES=0 -l sim_irq0.log
grep -q "IRQ PROTOCOL" sim_irq0.log
./simv -no_save ${SIM_ARGS:-} +IRQ_PROTOCOL +IRQ_LATENCY_CYCLES=100 -l sim_irq100.log
grep -q "IRQ PROTOCOL" sim_irq100.log
irq0_cycles="$(awk '/IRQ PROTOCOL/ {for (i=1; i<=NF; i++) if ($i ~ /^cycles=/) {sub("cycles=", "", $i); print $i; exit}}' sim_irq0.log)"
irq100_cycles="$(awk '/IRQ PROTOCOL/ {for (i=1; i<=NF; i++) if ($i ~ /^cycles=/) {sub("cycles=", "", $i); print $i; exit}}' sim_irq100.log)"
test -n "${irq0_cycles}" && test -n "${irq100_cycles}"
test "${irq100_cycles}" -gt "${irq0_cycles}"
echo "IRQ protocol latency A/B PASS: latency0=${irq0_cycles} cycles latency100=${irq100_cycles} cycles"

# Repeat the protocol A/B with descriptor transport enabled.  This keeps the
# IRQ performance gate tied to the optimized KV+Q path used by the driver.
./simv -no_save ${SIM_ARGS:-} +DESC_QUEUE +IRQ_PROTOCOL +IRQ_LATENCY_CYCLES=0 -l sim_irq_desc0.log
./simv -no_save ${SIM_ARGS:-} +DESC_QUEUE +IRQ_PROTOCOL +IRQ_LATENCY_CYCLES=100 -l sim_irq_desc100.log
grep -q "transport=descriptor-batch" sim_irq_desc0.log
grep -q "transport=descriptor-batch" sim_irq_desc100.log
irq_desc0_cycles="$(awk '/IRQ PROTOCOL/ {for (i=1; i<=NF; i++) if ($i ~ /^cycles=/) {sub("cycles=", "", $i); print $i; exit}}' sim_irq_desc0.log)"
irq_desc100_cycles="$(awk '/IRQ PROTOCOL/ {for (i=1; i<=NF; i++) if ($i ~ /^cycles=/) {sub("cycles=", "", $i); print $i; exit}}' sim_irq_desc100.log)"
test -n "${irq_desc0_cycles}" && test -n "${irq_desc100_cycles}"
test "${irq_desc100_cycles}" -gt "${irq_desc0_cycles}"
echo "IRQ descriptor latency A/B PASS: latency0=${irq_desc0_cycles} cycles latency100=${irq_desc100_cycles} cycles"
echo "ALL REAL REQUEST PATH XPM CHECKS PASSED"
