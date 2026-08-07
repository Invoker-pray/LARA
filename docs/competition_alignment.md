# Track B 赛题对齐审计

审计日期：2026-08-02

## 1. 依据

- 官方赛题页面：[FPT'26 Design Competition](https://fpt2026.uark.edu/fpt26-design-competition/)
- 本地提交指南：[Track-B-Submission-Guidelines.docx](Track-B-Submission-Guidelines.docx)
- 外部调研与来源：[web_research_findings.md](web_research_findings.md)

2026-07-17 重新核对官方页面：Track B 明确要求面向 Llama3-8B（或参数一致模型）的 FPGA attention acceleration，支持 bf16，并强调 customized dataflow、fine-grained parallelism、hardware-aware optimization；评价维度为 performance、hardware architecture optimizations 和 scalability。当前设计满足这些硬性边界，QKV projection 保持 host-side 是系统分工选择，不是赛题偏离。

官方 Track B 的关键要求是：面向 Llama3-8B 或参数一致模型的 FPGA attention acceleration，支持 bf16；设计需要体现 customized dataflow、fine-grained parallelism 和 hardware-aware optimization；评价关注 performance、hardware architecture optimizations 和 scalability。

## 2. 当前实现对应关系

| 赛题要求 | 当前设计 | 证据 | 状态 |
|---|---|---|---|
| Llama3-8B 参数一致 | `HEAD_DIM=128`、32 Q heads、8 KV heads、GQA 4:1 | `hw/rtl/pkg/attn_pkg.sv`、`sw/host_attention.py` | 已对齐 |
| bf16 | bf16 MAC、host RNE packing、AXIS 2×bf16/beat | `hw/rtl/core/bf16_mac.sv`、`sw/attn_driver.py` | 已对齐 |
| Attention FPGA 加速 | QK dot、online softmax、AV dot、O accumulation/normalize 在 PL | `hw/rtl/attn_top.sv` 及 core/mem 子模块 | 已实现 |
| 自定义数据流 | K/V cache + Q ping-pong + MAC Phase A/B time-mux | `docs/architecture_diagram.html` | 已实现 |
| 细粒度并行 | 16×16 逻辑阵列、8-bank KV、tile/subtile 调度 | `attn_tile.sv`、`kv_cache_ram.sv`、`attn_core.sv` | 已实现 |
| 硬件感知优化 | C4/DSP pipeline、P_STORE distributed RAM、Explore route、GQA K/V reuse | v2.2 reports、`web_research_findings.md` | 已实现 |
| 无 AI Core 配置 | KV260 PL-only，不依赖 AI Engine | `hw/scripts/vivado_build.tcl` | 已对齐 |
| 性能证据 | 83.333 MHz post-route，v2.5 P4 Explore WNS `+0.021 ns`、WHS `+0.010 ns`；P4 主循环 32x32 为 3209 cycles、32x64 为 5809 cycles；driver 记录 DMA/compute/stall counter | P4 candidate archive、board guide | 时序与仿真已完成，板上待测 |
| scalability | 当前单序列 prefill，MAX_SEQ_LEN=512 | `attn_pkg.sv`、board guide | 明确边界，长上下文待后续 |

## 3. Host/FPGA 分工是否偏离赛题

没有偏离。赛题要求加速 attention mechanisms，并没有要求把 QKV projection 也放入 FPGA。当前边界是：

```text
Host: RMSNorm -> QKV projection -> RoPE -> head-major bf16
FPGA: QK^T -> online softmax -> P×V -> output normalization
```

这样避免用 KV260 PL 的 attention MAC 阵列承担远大于 attention kernel 的 QKV 权重矩阵乘法，同时仍然把 attention 主体放在 FPGA 上。`AttentionAccelerator.run_layer()` 将宿主机投影和 FPGA attention 串成一个可调用流程；Q/K/V 通过 DMA 进入 PL，不通过 AXI-Lite 传输 bulk tensor。

## 4. 不应再作为当前结论的旧内容

- `200 MHz`、`≥200 MHz`：早期模块/架构目标；当前可发布结论是 83.333 MHz post-route。
- `256 DSP`：16×16 逻辑 PE 数，不是物理 DSP 用量；当前 v2.5 P4 Explore post-route 为 165 DSP。
- `MAX_SEQ_LEN=2048`：早期参数草案；当前实现和构建合同为 512。
- “8 个 KV heads 全量同时驻留 URAM”：当前片上 cache 只承载当前 KV head/group，GQA group 切换时由 host driver 重载。
- “写 `CSR_STREAM_LEN` 触发 DMA”：当前 DMA 必须由 PYNQ send/recv channel 显式启动。

这些历史描述已在相关 HTML/Markdown 文档中改为当前状态或显式标注为历史估算。

## 5. 赛题准出条件

进入最终演示/论文前，还必须补齐：

1. KV260 实板零输入 smoke 和预计算 Q/K/V 数值对比。
2. Host projection、K/V DMA、Q DMA、PL compute、O DMA 的分项 latency。
3. 资源、83.333 MHz timing/DRC、端到端 tokens/s 和 stall counter 的可复现报告。
4. 对 `MAX_SEQ_LEN=512` 的边界、partial Q/KV tile、causal mask 和 GQA group 切换测试。
5. 5 分钟以内板上演示视频和两页以内技术论文主文。

## 6. v2.5 Phase 1 timing evidence

- The clean RTL build keeps the Track B host/FPGA boundary and exact bf16 semantics
  unchanged. `split_phase`, `accum_en`, and `clear_accum` are copied into one
  register bank per MAC row; all copies update on the same edge, so no protocol
  latency is added.
- Default route from this clean build was intentionally rejected at WNS `-0.585 ns`.
  Explore routing from the matching physopt checkpoint produced WNS `+0.062 ns`,
  WHS `+0.010 ns`, zero TNS/THS, 144592/144592 fully routed nets, and zero DRC
  errors. The post-route critical path moved to the softmax row-index/max path,
  showing that the previous MAC-control fanout was no longer dominant.
- The timing gain costs resources: 95267 LUT, 57838 FF, 50 BRAM, 48 URAM, and
  165 DSP. This is a signed-off optimization build, not a claim of higher
  throughput until board latency is measured.

## 7. v2.5 Phase 2 softmax timing evidence

- `SOFTMAX_SCALE_PIPE=1` separates scaled-score issue from row-max commit while
  retaining one element per cycle. One drain cycle per 16×16 subblock commits
  the final issued value; setting the parameter to zero restores Phase 1.
- The matching clean build's default route was rejected at WNS `-0.818 ns`.
  Explore routing met timing at WNS `+0.078 ns`, WHS `+0.007 ns`, zero TNS/THS,
  144745/144745 fully routed nets, and zero DRC errors.
- The former `sm_row_idx -> sm_row_max` path is no longer critical. The new
  worst setup path ends at `sm_scale_value_pipe`, with 11.635 ns data delay and
  69.6% routing delay. Post-route resources are 96180 LUT, 58051 FF, 50 BRAM,
  48 URAM, and 165 DSP.
- Python, driver, Verilator, and VCS regressions passed. KV260 numerical and
  performance measurements remain pending because no board was connected.

## 8. v2.5 P0 causal and measurement evidence

- A dedicated `attn_core` regression now uses one-cycle MAC/softmax/output
  acknowledgements and a bank-ready load model. It proves 72 causal versus
  128 non-causal tile pairs per Q head at L=512, or 2304 versus 4096 over all
  32 Q heads, including KV-index reset at every Q/head/group transition.
- Directed L=70 cases cover six active rows/columns and non-zero position bases.
  The synthesis-path softmax baseline is independently measured as 1106 cycles
  per 16x16 subblock.
- `sw/benchmark.py` no longer promotes architectural estimates to measured
  performance. It reports the current 83.333 MHz/165-DSP/512-token contract and
  explicitly withholds end-to-end latency and throughput until full simulation
  counters or KV260 measurements exist.

## 9. v2.5 P1 exact softmax-P evidence

- `SOFTMAX_P_PIPE=1` pipelines subtract, EXP lookup, and P/row-sum commit while
  preserving the legacy left-to-right FP32 recurrence. Setting it to zero restores
  the Phase 2 schedule. Default and rollback runs are byte-exact for P, m, l, and
  correction across full, partial, masked, state-load, and later-KV-tile cases.
- Synthesis-path VCS measures 288 P-phase cycles and 626 total cycles per 16x16
  subblock, versus the 768/1106 P0 baseline. Python 7/7, driver 5/5, both Verilator
  paths, and the 19-test VCS behavioral/synthesis/XPM regression all pass.
- The matching clean default route meets 83.333 MHz without an Explore reroute:
  WNS `+0.003 ns`, WHS `0.000 ns`, zero TNS/THS, 144612/144612 fully routed nets,
  and zero DRC errors. Resources are 95077 LUT, 57956 FF, 50 BRAM, 48 URAM, and
  165 DSP, so no scarce resource increased relative to Phase 2.
- This is repeatable implementation evidence, not a KV260 throughput claim; board
  measurements remain pending while no board is connected.

## 10. v2.5 P2 Phase-A overlap evidence

- `PHASEA_SOFTMAX_OVERLAP=1` decouples MAC issue, the held score block, and
  softmax retire with explicit ready/valid and tags. It reuses the existing
  `s_block` holding location; no score ping-pong RAM or second softmax lane was added.
  `LARA_PHASEA_SOFTMAX_OVERLAP_ROLLBACK` restores serialized scheduling.
- Focused synthesis-path A/B testing covers eight consecutive blocks, two Q
  microtiles, a later partial KV tile, causal/all-masked rows, and deterministic
  1–4-cycle input backpressure. P, m, l, and correction are bit-exact. Phase-A
  falls from 7109 to 5310 cycles (25.31%), exceeding the 15% P2 acceptance gate.
- Python 7/7, driver 5/5, both Verilator paths, and the 20-test VCS
  behavioral/synthesis/A-B/XPM regression pass. The matching clean default route
  meets 83.333 MHz at WNS `+0.001 ns`, WHS `+0.010 ns`, zero TNS/THS,
  144472/144472 fully routed nets, zero routing errors, and zero DRC errors.
- Resources are 95356 LUT, 56938 FF, 50 BRAM, 48 URAM, and 165 DSP. The worst
  setup path remains a MAC-to-output-buffer path (11.590 ns, 65.2% routing), not
  the new overlap controller. This is a tight but valid implementation signoff,
  not an on-board throughput measurement.

## 11. v2.5 P3 scratch/P-store DSE conclusion

P3's three single-variable candidates retain independent rollback/enable defines
and all pass functional regression:

| Candidate | Softmax hierarchy | Implementation evidence | Verdict |
|---|---:|---|---|
| P in-place, registered output | 11,751 LUT / 25,182 FF | Synth WNS `+1.261 ns`, WHS `-0.090 ns` | Reject, FF exceeds P2 |
| P in-place, direct output | 11,545 LUT / 20,922 FF | Route WNS `-1.245 ns`, TNS `-882.633 ns` | Reject, only ~9.1% FF reduction and setup failure |
| Score in-place | 15,370 LUT / 12,812 FF | Explore WNS `-0.121 ns`, TNS `-8.624 ns`, CLB 99.17% | Reject, routing congestion |

The P3 storage organization therefore remains the P2 form:
`SOFTMAX_P_INPLACE=0` and `SOFTMAX_P_OUTPUT_DIRECT=0`. These are
implementation results, not KV260 performance claims; the board is still
unconnected.

## 12. v2.5 P4 streaming/fused PV

Candidate 1 keeps exact bf16 arithmetic and the P2 ready/valid contracts while
retiring P blocks into the existing P-store and scheduling atomic PV tasks in
idle shared-MAC windows. It passes the required bit-exact and regression gates:
32x32 cycles fall from `4345` to `3209`, 32x64 cycles from `8429` to `5809`,
and the partial output is byte-for-byte identical.

The matching clean build uses `LARA_STREAMING_PV_ENABLE` and produces
100148 LUT, 57441 FF, 50 BRAM, 48 URAM, and 165 DSP at post-synthesis. Its
default route is fully routed but fails setup at WNS `-0.110 ns`; Explore
routing from the same physopt checkpoint passes with WNS `+0.021 ns`,
WHS `+0.010 ns`, zero TNS/THS, 144158/144158 fully routed nets, zero routing
errors, and zero DRC Error severity violations. The Explore post-route
utilization is 95479 LUT, 56940 FF, 50 BRAM, 48 URAM, and 165 DSP.

The candidate is accepted via matching Explore route and is now the source
default. `LARA_STREAMING_PV_ROLLBACK` restores the P2 schedule. This is not a
KV260 throughput claim; no board is connected.
