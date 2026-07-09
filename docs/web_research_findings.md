# LARA 网络调研发现 — 可借鉴的优化技术

> 调研日期：2026-07-09
> 用途：追踪从网络/论文/GitHub 发现的优化技术及其在 LARA 中的应用状态

---

## 1. Softmax 近似优化

### 1.1 Softermax: Base-2 Softmax (NVIDIA 2023)
- **来源**: Stevens et al., "Softermax: Hardware/Software Co-Design of an Efficient Softmax for Transformers", DAC 2023
- **核心思想**: 将 `eˣ` 替换为 `2ˣ`，correction factor `exp(m_old - m_new)` 变为移位操作，消除 EXP LUT
- **收益**: 2.35× 能效, 0.90× 面积
- **LARA 应用状态**: ⬜ 未实现 — 当前使用 1024-entry EXP LUT + 线性插值
- **实现难度**: 低 — 替换 `exp_lookup()` 函数 + `$bitstoshortreal` 移位操作
- **备注**: 精度需 Python golden model 验证，对 bf16 的 3 位十进制精度可能足够

### 1.2 SafeSoftmax 输入范围裁剪
- **来源**: Leiva-Valverde et al., "A Quantitative Evaluation of Approximate Softmax Functions", arXiv:2501.13379, 2025
- **核心思想**: 将 softmax 输入裁剪到 [-16, 0]（e^(-16) ≈ 1.1e-7, 可忽略），LUT 大小减少 16×
- **LARA 应用状态**: ✅ 已实现 — EXP LUT 范围 [-8, 0]，可扩展至 [-16, 0] 支持更长序列
- **参考**: [arXiv:2501.13379](http://arxiv.org/abs/2501.13379)

### 1.3 开源 HLS Softmax 加速器集合
- **来源**: [ECASLab/hls-fpga-accelerators](https://github.com/ECASLab/hls-fpga-accelerators)
- **核心思想**: 多种近似 softmax (Taylor, LUT, bipartite LUT) 的 HLS 参考实现
- **LARA 应用状态**: ⬜ 可参考 LUT 设计模式
- **备注**: HLS 代码可转换为 SystemVerilog 参考

### 1.4 Pseudo-Softmax (LOD + 移位除法)
- **来源**: Wang et al., "SOLE: Hardware-Oriented Approximations of Softmax"
- **核心思想**: 用 Leading-One-Detector + 移位替代除法，完全定点化
- **LARA 应用状态**: ⬜ 未实现
- **备注**: 适合资源极度受限场景，精度损失待评估

---

## 2. KV Cache 优化

### 2.1 PD-Swap: KV260 动态部分重配置
- **来源**: Zhang et al. (UC Irvine), "PD-Swap: Prefill-Decode Logic Swapping for End-to-End LLM Inference on Edge FPGAs", arXiv:2512.11550, 2024
- **核心思想**: Prefill 和 Decode 使用不同的硬件加速器，通过动态部分重配置 (DPR) 在毫秒级切换
- **收益**: KV260 上 27 tokens/s, 1.3-2.1× 高于静态加速器
- **LARA 应用状态**: ⬜ 未实现 — DPR 需要 Vivado 特殊流程
- **参考**: [arXiv:2512.11550](http://arxiv.org/abs/2512.11550)

### 2.2 GQA 跨 Head K/V 复用
- **来源**: llama.cpp PR #12014 (JohannesGaessler, 2024)
- **核心思想**: 同 GQA group 内, 加载的 K/V 数据被 4 个 Q head 复用, 减少 token/block
- **收益**: RTX 3090 上 1.59× 加速 (Llama 8B)
- **LARA 应用状态**: ✅ FSM 已有 group_cnt/head_cnt 循环，但 K/V 加载未跨 head 缓存复用
- **参考**: [GitHub PR #12014](https://github.com/ggml-org/llama.cpp/pull/12014)

### 2.3 KV Cache 量化压缩
- **来源**: AccLLM (2025), KV4 quantization + pruning on FPGA
- **核心思想**: 4-bit KV cache, 动态剪枝
- **收益**: 4.07× 能效 vs FlightLLM
- **LARA 应用状态**: ⬜ 超出 Phase 1 范围

---

## 3. FlashAttention 架构优化

### 3.1 FlatAttention: Tile-Based Many-PE Dataflow
- **来源**: Li et al., "FlatAttention", ISVLSI 2025
- **核心思想**: Tile-based systolic array, 89.3% MAC 利用率
- **LARA 应用状态**: ⬜ 当前是单 MAC 阵列分时复用，利用率较低

### 3.2 ELSA: Associative Prefix Scan Softmax
- **来源**: Hsu et al., "ELSA", CVPR 2026
- **核心思想**: O(log n) 并行深度 online softmax, 二叉树归约
- **收益**: 1.3-3.5× vs SDPA
- **LARA 应用状态**: ⬜ 未实现 — 当前是串行 m/l update

### 3.3 VFA: Vector-Relieved FlashAttention
- **来源**: 2026, 矢量近似初始化 running max, 消除条件 rescale
- **核心思想**: 从 key-block 近似初始化 m, 减少 correction 分支
- **收益**: ~20% softmax 延迟降低
- **LARA 应用状态**: ⬜ 可简化 online softmax 控制逻辑

---

## 4. BF16/DSP48E2 优化

### 4.1 DSP48E2 bf16 标准映射
- **来源**: Xilinx UG579 + 社区实践
- **核心思想**: 9×9 尾数乘法在 DSP, 8-bit 指数+符号在 LUT, `(* use_dsp="yes" *)` 属性
- **LARA 应用状态**: ✅ 已在 bf16_mac.sv 中设计, `(* use_dsp="yes" *)` 已加入
- **备注**: 1 DSP48E2 + ~100 LUT per bf16 MAC

### 4.2 C4_MUL_PIPE: DSP48E2 M-Register
- **来源**: xx 毕设项目 cim_tile.sv C4 设计
- **核心思想**: 启用 DSP48E2 内部 M 寄存器 (乘法→寄存器→累加)，断关键路径
- **收益**: 10-20MHz 频率提升
- **LARA 应用状态**: ✅ 已启用 (C4_MUL_PIPE=1)

---

## 5. KV260 平台参考

### 5.1 KV260 Tiled MM Accelerator
- **来源**: 2025, DistilBERT 32×32 int8 systolic array on KV260
- **收益**: 7× vs ARM, 3.1 GFLOPS at 100 MHz
- **LARA 参考价值**: 提供 KV260 实际吞吐基准 (~2 GFLOPS bf16 expected)

### 5.2 FFVTA: Frequency-Focused ViT on KV260
- **来源**: IEEE 2025, KV260 ViT accelerator
- **收益**: 16.61× speedup, 0.46 GOPS/DSP efficiency
- **LARA 参考价值**: GOPS/DSP 指标对标基准

---

## 6. 汇总：已采纳 vs 待评估

### 已采纳并实现
| 技术 | 来源 | 实现位置 |
|------|------|----------|
| bf16 MAC DSP48E2 推断 | UG579 + xx 项目 | bf16_mac.sv |
| C4_MUL_PIPE M-Register | xx 项目 | attn_pkg.sv |
| `(* use_dsp="yes" *)` | xx 项目 | bf16_mac.sv |
| `(* ram_style="block" *)` | xx 项目 | kv_cache_ram.sv, tile_buffer.sv |
| SafeSoftmax 范围裁剪 | Leiva-Valverde 2025 | softmax_engine.sv |
| FSM Ping-Pong Overlap | xx 项目 + roadmap | attn_core.sv v2.1 |
| 性能计数器 (GOPS/DSP) | roadmap §7 | attn_core.sv v2.1 |

### 待评估 (Phase 2)
| 技术 | 优先级 | 关键问题 |
|------|:---:|------|
| Softermax (base-2) | P1 | bf16 精度损失待验证 |
| 16×32 MAC 阵列 | P1 | Softmax 硬件需同步扩展 |
| 3 级流水线 LOAD/COMPUTE/WRITE | P1 | FSM 重构工作量 |
| Pseudo-Softmax | P2 | 精度验证 + 定点化 |
| PD-Swap DPR | P2 | Vivado DPR 流程复杂 |
| KV Cache 量化 | P2 | 需要量化训练 |
