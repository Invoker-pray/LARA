# Track B 赛题对齐审计

审计日期：2026-07-18

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
| 性能证据 | 83.333 MHz post-route，v2.5 Phase 1 Explore WNS `+0.062 ns`、WHS `+0.010 ns`；driver 记录 DMA/compute/stall counter | `vivado_proj/reports`、board guide | 时序已完成，板上待测 |
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
- `256 DSP`：16×16 逻辑 PE 数，不是物理 DSP 用量；当前 v2.4 post-route 为 165 DSP。
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
