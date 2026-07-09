# LARA 性能优化审计报告

> 日期：2026-07-09
> 范围：vs xx毕设库 + vs 本项���技术文档 + 网络调研

---

## 一、对比 xx 毕设库 — 未实现的性能模式

### P0 — 关键性能差距

| # | xx 项目模式 | LARA 现状 | 性能影响 | 实现难度 |
|:---:|------------|-----------|----------|:---:|
| 1 | **Compute/Transfer 重叠** (ping-pong: DMA写bank A 同时计算bank B) | tile_buffer 有 ping-pong 硬件但 FSM 完全串行（等 load_done 才计算） | **~30% 吞吐提升** (隐藏 Q load 延迟) | 低 |
| 2 | **OBUF→IBUF 硬件直拷** (跨层 DMA 往返消除) | 当前每层都走 DDR 回写+重读 | **~50% 跨层延迟降低** | 中 |
| 3 | **Auto-increment burst DMA** (CSR 写 LEN 触发连续传输) | AXIS sink 有 cfg_len 但无 burst continue 模式 | 减少 CSR 交互开销 | 低 |
| 4 | **BRAM output pipeline register** (断 BRAM→逻辑的关键路径) | 存储模块无显式输出寄存器 | **10-20MHz 频率提升** | 低 |

### P1 — 重要优化

| # | xx 项目模式 | LARA 现状 | 说明 |
|:---:|------------|-----------|------|
| 5 | **C4 pipeline (L+M+MAC 三段流水)** | MAC 有 2-stage pipeline，FSM 仍是串行 | xx 把 FSM 也 pipelined |
| 6 | **Weight tile register banking** | 不适用 (QKV 在 host) | — |
| 7 | **DSP 输出寄存器 (`C4_MUL_PIPE`)** | bf16_mac 有但 attn_tile 没用到 | 应启用 DSP48E2 M-register |
| 8 | **双 bank 独立读写 (rd_bank_sel ≠ wr_bank_sel)** | tile_buffer 有 buf_sel 但读写不能同时不同 bank | 限定了无法真正 overlap |

---

## 二、对比本项目技术文档 — 未实现的性能特性

| # | 文档来源 | 特性 | 状态 |
|:---:|----------|------|:---:|
| 1 | track-b-roadmap.md §2 | **计算/传输重叠** (Ping-pong while compute) | ❌ |
| 2 | track-b-roadmap.md §7 | **GOPS/DSP 效率指标** (竞赛核心指标) | ❌ 无性能计数器 |
| 3 | mac_array_analysis.html | **16×32 最佳扩展阵列** (512 DSP) | ❌ 仍用 16×16 |
| 4 | dataflow_diagram.html | K/V Cache vs No-Cache 128× 带宽节省 | ✅ 已实现 |
| 5 | code_organization.html §15 | RoPE 可流水线 4 pairs/cycle | ❌ 当前 1 pair/cycle |
| 6 | architecture_diagram.html | 双 MAC 阵列 (Phase A/B 同时运行) | ❌ 分时复用单阵列 |

---

## 三、网络调研 — Llama3.1-8B 注意力加速前沿

### 3.1 Softmax 近似优化

| 技术 | 来源 | 收益 | 适用性 |
|------|------|------|:---:|
| **SafeSoftmax + 范围裁剪到 [-16,0]** | Leiva-Valverde 2025 | LUT 减小 16× | ✅ 我们 EXP LUT 已用 [-8,0] |
| **二阶 Taylor 近似替代 LUT** | MDPI Electronics 2025 | 14-20% 资源节省，0.2% 精度损失 | ⚠️ 可能替换 EXP LUT |
| **Pseudo-Softmax (2ˣ 替代 eˣ)** | Wang et al. | 无需除法，LOD+移位替代 | ⚠️ 精度需验证 |
| **Bipartite LUT** | MDPI Micromachines 2026 | 更小 LUT，并行双表查询 | ✅ 可升级 EXP LUT |

### 3.2 KV Cache 优化

| 技术 | 来源 | 收益 | 适用性 |
|------|------|------|:---:|
| **GTA (Grouped-Tied Attention)** | Princeton ICML 2025 | KV cache 减半，质量匹配 GQA | ⚠️ 需改模型结构 |
| **PD-Swap 动态部分重配置** | UC Irvine 2024 | KV260 上 27 tokens/s, 1.3-2.1× | ⚠️ 需要 DPR 支持 |
| **Prefill/Decode 分离加速** | Zhang et al. 2024 | Prefill用计算密集型，Decode用带宽优化型 | ✅ 可参考架构思路 |

### 3.3 算术强度优化

| 技术 | 来源 | 收益 | 适用性 |
|------|------|------|:---:|
| **K/V 跨 head 复用** | llama.cpp PR#12014 | 1.46-1.59× 加速 (GPU) | ✅ FPGA 上同样适用 |
| **GQA warp 优化** | llama.cpp | 更多 Q columns/warp → 更高算术强度 | ✅ 类似思路可用于 MAC 阵列调度 |
| **异步 KQ mask 加载** | llama.cpp | 隐藏 mask 延迟 | ⚠️ FPGA 上 mask 是组合逻辑 |

### 3.4 硬件 Softmax 参考实现

开源：[hls-fpga-accelerators](https://github.com/ECASLab/hls-fpga-accelerators/) — HLS 近似 softmax 加速器集合，含多种 LUT/Taylor 对比。

---

## 四、优化建议（按性价比排序）

### 立刻做（P0，<1天实现）

| # | 优化 | 预期收益 | 改动范围 |
|:---:|------|----------|----------|
| 1 | **FSM Ping-Pong Overlap**：Q load 下一 tile 与当前 tile 计算并行 | +30% 吞吐 | attn_core FSM (~40行) |
| 2 | **启用 C4_MUL_PIPE**：attn_tile 中 DSP48E2 输出寄存器 | +20MHz 频率 | attn_pkg 常量 (1行) |
| 3 | **性能计数器完善**：cycle_cnt, mac_cycles, stall_cycles, GOPS | 竞赛评分必需 | attn_core (~20行) |

### 短期（P1，<3天）

| # | 优化 | 预期收益 | 改动范围 |
|:---:|------|----------|----------|
| 4 | **OBUF→next-tile 直通**：跳过 DDR 回写+重读 (当 Q_tile 连续时) | -50% O write + next Q load | output_buffer + FSM |
| 5 | **Softmax 输入范围裁剪**：[-16,0] → [-8,0] 已实现，可增加 [-16,0] 支持大序列 | 覆盖更长序列 | softmax_engine (~10行) |
| 6 | **RoPE 4 pairs/cycle**：当前 1 pair/cycle → 4 pairs/cycle 流水线 | -75% RoPE 延迟 | rope_engine (~50行) |

### 中期（P2，<1周）

| # | 优化 | 预期收益 | 改动范围 |
|:---:|------|----------|----------|
| 7 | **16×32 MAC 阵列**：按 mac_array_analysis.html 推荐扩展 | +100% MAC 吞吐 | attn_tile + pkg |
| 8 | **AXIS burst continue**：auto-increment DMA 模式 | 减少 CSR 交互 | AXIS sink + CSR |
| 9 | **Pseudo-Softmax 评估**：2ˣ 替代 eˣ 的精度/面积 trade-off | 可能省 EXP LUT | Python 黄金模型评估 |

---

## 五、竞赛指标估算

基于当前设计 (L=512, 单 head, 200MHz)：

```
MAC 阵列: 256 DSP × 200MHz × 2 ops/DSP = 102.4 GOPS (理论峰值)
Attention FLOPs: ~34.4M MACs/GQA head-pair
Latency: ~260 cycles/KV_tile × 8 KV_tiles × 16 Q_tiles = ~33K cycles ≈ 165μs
Throughput: ~6K tokens/s (L=512)
GOPS/DSP: 102.4 / 256 = 0.4 GOPS/DSP

添加 P0 优化后:
Throughput: +30% (overlap) → ~7.8K tokens/s
GOPS/DSP: 不变 (同等硬件)

添加 16×32 阵列后:
MAC 吞吐: 512 DSP → 204.8 GOPS
GOPS/DSP: 0.4 (不变，但绝对吞吐翻倍)
```
