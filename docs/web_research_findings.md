# LARA 网络调研发现 — 可借鉴的优化技术

> 调研日期：2026-07-09
> 用途：追踪从网络/论文/GitHub 发现的优化技术及其在 LARA 中的应用状态

---

## 1. Softmax 近似优化

### 1.1 Softermax: Base-2 Softmax (DAC 2021)
- **来源**: Stevens et al., "Softermax: Hardware/Software Co-Design of an Efficient Softmax for Transformers", DAC 2021; preprint: <https://arxiv.org/abs/2103.09301>
- **核心思想**: 将 `eˣ` 替换为 `2ˣ`，correction factor `exp(m_old - m_new)` 变为移位操作，消除 EXP LUT
- **收益**: 2.35× 能效, 0.90× 面积
- **LARA 应用状态**: ⬜ 未实现 — 当前使用 1024-entry EXP LUT + 线性插值
- **实现难度**: 中 — 需要重定义缩放/归一化路径并同步更新 Python golden model；不能用 `$bitstoshortreal` 作为可综合实现
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
- **来源**: Zhang et al. (UC Irvine), "PD-Swap: Prefill-Decode Logic Swapping for End-to-End LLM Inference on Edge FPGAs", arXiv:2512.11550, 2025
- **核心思想**: Prefill 和 Decode 使用不同的硬件加速器，通过动态部分重配置 (DPR) 在毫秒级切换
- **收益**: KV260 上 27 tokens/s, 1.3-2.1× 高于静态加速器
- **LARA 应用状态**: ⬜ 未实现 — DPR 需要 Vivado 特殊流程
- **参考**: [arXiv:2512.11550](http://arxiv.org/abs/2512.11550)

### 2.2 GQA 跨 Head K/V 复用
- **来源**: llama.cpp PR #12014 (JohannesGaessler, 2024)
- **核心思想**: 同 GQA group 内, 加载的 K/V 数据被 4 个 Q head 复用, 减少 token/block
- **收益**: RTX 3090 上 1.59× 加速 (Llama 8B)
- **LARA 应用状态**: ✅ 已通过 `CSR_LOAD_REQ` + driver request-service 实现跨 head K/V 复用；每个 group 加载一次，服务 4 个 Q heads
- **参考**: [GitHub PR #12014](https://github.com/ggml-org/llama.cpp/pull/12014)

### 2.3 KV Cache 量化压缩
- **来源**: AccLLM (2025), KV4 quantization + pruning on FPGA
- **核心思想**: 4-bit KV cache, 动态剪枝
- **收益**: 4.07× 能效 vs FlightLLM
- **LARA 应用状态**: ⬜ 超出 Phase 1 范围

---

## 3. FlashAttention 架构优化

### 3.1 FlatAttention: Tile-Based Many-PE Dataflow
- **来源**: Li et al., "FlatAttention", ISVLSI 2025 / follow-up preprint 2026
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

---

## 7. 优化优先级路线图 (2026-07-09)

### P0 — 综合路径完善
| 优化 | 参考 | 收益 |
|------|------|------|
| attn_tile: 256×bf16_mac 综合实例化 | bf16_mac 已双模 ✅ | ✅ 已实现 |
| psum_accum: fp32 bit-level 累加 | xx psum_accum 模式 | 🔧 进行中 |
| softmax_engine: LUT-based exp + fp32 逻辑 | 现有 EXP LUT ROM | 🔧 进行中 |
| kv_cache_ram: 多 bank URAM | code_org §9, xx URAM 经验 | ⬜ |
| UCIO-1 端口映射 | Vivado BD 约束 | 🔧 进行中 |

### P1 — 性能关键
| 优化 | 参考 | 收益 |
|------|------|------|
| Softermax (eˣ→2ˣ) | DAC 2021 | 省 BRAM, 消除 EXP LUT 插值误差；必须先完成精度回归 |
| C4 流水线 L→M→ACC 三段 | xx C4 pipeline | 100→125MHz |
| 16×32 MAC 参数化 | mac_array_analysis.html | 2× MAC 吞吐 |

### P2 — 加分项
| 优化 | 参考 | 收益 |
|------|------|------|
| RoPE 4 pairs/cycle | roadmap §2 | RoPE 延迟 ÷4 |
| KV260 上板实测 | — | 真实频率/吞吐/WNS |

---

## 8. 2026-07-09 补充调研（论文 + GitHub 实践）

这一轮补充调研的目标不是泛泛罗列，而是回答三个问题：

1. Llama3.1-8B / GQA 模型在实际系统里，attention 性能瓶颈通常卡在哪。
2. 现有高性能实现到底优先优化了哪些点。
3. 这些点里哪些适合 LARA 当前的 KV260 + RTL 路线。

### 8.1 FlashAttention 官方实现：关键不是“能算”，而是减少 non-matmul FLOPs 和改 work partition

- **来源**: [FlashAttention GitHub](https://github.com/Dao-AILab/flash-attention), [FlashAttention-2 paper](https://arxiv.org/abs/2307.08691)
- **关键信息**:
  - FlashAttention 官方仓库已经迭代到 FlashAttention-2/3/4 路线。
  - FlashAttention-2 的核心改进不是换公式，而是：
    1. 减少 non-matmul FLOPs
    2. 沿 sequence 维度并行化单头 attention
    3. 改善 block/warp 间 work partition
  - 论文报告 FlashAttention-2 相对 FlashAttention 约 **2×** 速度提升。
- **对 LARA 的启发**:
  - LARA 现在的 `softmax_engine + attn_core` 仍然是“功能完整优先”的实现，控制路径和中间状态更新偏串行。
  - 对 FPGA 版 LARA 来说，最可落地的不是照搬 GPU kernel，而是吸收其思想：
    - 减少 softmax 阶段的额外算术
    - 减少状态机空拍
    - 把 prefill 主循环做成更强的 load/compute/write overlap

### 8.2 vLLM / PagedAttention：KV cache 管理本身就是吞吐核心

- **来源**: [PagedAttention paper](https://arxiv.org/abs/2309.06180), [vLLM GitHub](https://github.com/vllm-project/vllm)
- **关键信息**:
  - vLLM 将高吞吐建立在 **PagedAttention + continuous batching + chunked prefill + prefix caching** 上。
  - 仓库 README 明确把这些列为核心能力。
- **对 LARA 的启发**:
  - LARA 当前仍是单序列 prefill kernel，而不是 serving-oriented runtime；但控制已升级为一次 start 覆盖完整 group/head/tile 遍历。
  - 但其中两个思想可以直接迁移到硬件控制：
    1. **chunked prefill**：将大 prefill 分块处理，减少缓存峰值压力，适合 `L > 512` 的降级模式。
    2. **prefix reuse / KV reuse**：如果上层软件以后支持多轮对话，KV cache 不能只看“本次层内复用”，还要看“跨请求/跨步复用”。
  - 这类优化偏系统层；当前先维持 `MAX_SEQ_LEN=512` 的可复现路径，长上下文再引入 chunked/paged fallback。

### 8.3 FlashInfer：当前工业实践已经把 prefill / decode / mixed batching 分开优化

- **来源**: [FlashInfer GitHub](https://github.com/flashinfer-ai/flashinfer)
- **关键信息**:
  - FlashInfer 自述重点包括：
    - **Paged and Ragged KV-Cache**
    - **Decode / Prefill / Append** 分阶段 attention kernel
    - **Cascade Attention**（共享 prefix 的层级缓存）
    - **POD-Attention**（prefill + decode 混合批次）
    - **RoPE / RMSNorm** 的高性能配套算子
  - 其设计目标是“按 workload 自动选后端”，而不是单一 kernel。
- **对 LARA 的启发**:
  - LARA 当前模块边界是对的，但还缺少“按阶段分别优化”的意识。
  - 对应到现有代码，建议将后续优化拆成三块：
    1. **Prefill-fast path**：当前主路径，优先做满。
    2. **Long-context fallback path**：L 超过 URAM 容量时的分块缓存。
    3. **RoPE / RMSNorm optional offload**：只在性能收益明确时搬到硬件。

### 8.4 llama.cpp 的 GQA 实践：K/V 复用是 Llama3 类模型的直接收益点

- **来源**: [llama.cpp PR #12014](https://github.com/ggml-org/llama.cpp/pull/12014)
- **关键信息**:
  - 该优化明确提到：**对 GQA 模型，在多个 attention heads 之间复用已加载的 K/V 数据**。
  - 同时降低每个 CUDA block 处理的 token 数，减少 padding 带来的浪费计算。
  - PR 中还直接点名：**LLaMA 3 uses GQA with 4 Q per K/V**。
- **对 LARA 的启发**:
  - 这是最贴近 Llama3.1-8B 的现实优化。
  - LARA 当前 `attn_core.sv` 保留 `group_cnt/head_cnt` 循环，`attn_top.sv` 通过 `CSR_LOAD_REQ` 将“一个 KV head 服务 4 个 Q heads”接入真实 CSR/DMA request-service。
  - **这项优化已实现，下一步应以板上 DMA/数值结果确认，而不是继续停留在架构假设。**

### 8.5 KV cache 压缩：更适合 Phase 2 或更大板卡，不适合现在先做

#### ZipCache
- **来源**: [ZipCache paper](https://arxiv.org/abs/2405.14256)
- **关键信息**:
  - 通过 token-saliency 感知量化压缩 KV cache。
  - 在 LLaMA3-8B 长上下文评估中，论文给出显著的延迟和显存收益。
- **对 LARA 的启发**:
  - ZipCache 说明 KV cache 压缩确实能直接改善长上下文性能。
  - 但它改变了 KV 表示和调度，需要完整的软件-硬件协同；不适合当前“先把 bf16 精确 attention 跑完整”的阶段。

#### LeanKV / G-KV
- **来源**: [LeanKV paper](https://arxiv.org/abs/2412.03131), [G-KV paper](https://arxiv.org/abs/2512.00504), [G-KV GitHub](https://github.com/microsoft/G-KV)
- **关键信息**:
  - LeanKV 走的是 **混合精度 + selective pruning + per-head dynamic sparsity**。
  - G-KV 走的是 **global scoring eviction**。
- **对 LARA 的启发**:
  - 两者都证明“KV cache 管理”本身已经成为 attention 推理系统的一等公民。
  - 但对 KV260 这个目标板卡，Phase 1 仍应优先做：
    - 正确多 bank
    - 正确复用
    - 正确 overlap
  - 而不是先引入压缩误差。

### 8.6 FPGA 方向的近年论文：真正有效的优化通常是 memory hierarchy + overlap，而不是只堆 MAC

#### FlightLLM
- **来源**: [FlightLLM paper](https://arxiv.org/abs/2401.03868)
- **关键信息**:
  - 强调 always-on-chip decode、混合精度、FPGA memory hierarchy 的整体映射。
- **对 LARA 的启发**:
  - LARA 现在最缺的不是“更多计算模块”，而是把现有 memory hierarchy 从 behavioral model 变成真正可综合结构。

#### AccLLM
- **来源**: [AccLLM paper](https://arxiv.org/abs/2505.03745)
- **关键信息**:
  - 算法-硬件协同，采用 pruning、Lambda-shaped attention、**W2A8KV4**。
  - 在 FPGA 上相对 FlightLLM 报告 **2.98× throughput** 和 **4.07× energy efficiency**。
- **对 LARA 的启发**:
  - 这再次说明长上下文瓶颈非常大程度在 memory / KV cache。
  - 但其前提是 aggressive compression，超出 LARA 当前 bf16 精确实现目标。

#### FAST-Prefill
- **来源**: [FAST-Prefill paper](https://arxiv.org/abs/2602.20515)
- **关键信息**:
  - 面向长上下文 prefill，重点是：
    - memory-aware execution order
    - dual-tier cache
    - 高吞吐矩阵处理单元
  - 在 FPGA 上聚焦 prefill，而不是 decode。
- **对 LARA 的启发**:
  - LARA 当前实际上也是 prefill-first 架构。
  - 这条路线是合理的，说明优先把 prefill attention 做深做透，是对的。

### 8.7 FlatAttention / ELSA：给出两个值得追踪但不该现在硬上车的方向

#### FlatAttention
- **来源**: [FlatAttention 2025](https://arxiv.org/abs/2505.18824), [FlatAttention 2026](https://arxiv.org/abs/2604.02110)
- **关键信息**:
  - 核心是 dataflow 和 on-chip collective primitives 的协同优化。
  - 报告高利用率和显著 HBM 流量下降。
- **对 LARA 的启发**:
  - 对大规模 many-PE / tile mesh 很有参考价值。
  - 但对 KV260 上的 16×16 attention 阵列，近期更现实的是把 `16×16 → 16×32` 参数化探索做出来。

#### ELSA
- **来源**: [ELSA paper](https://arxiv.org/abs/2604.23798)
- **关键信息**:
  - 把 online softmax 更新重写成 associative prefix scan，平行深度从串行更新压到 `O(log n)`。
- **对 LARA 的启发**:
  - 如果后续 `softmax_engine` 真成为主瓶颈，这是最值得研究的算法级替代路线之一。
  - 当前综合路径已进入 v2.2 routed design；ELSA 只作为 softmax 成为新瓶颈后的算法研究方向。

---

## 9. 基于代码、文档和外部调研的直接结论

### 9.1 历史 P0 审计项及当前关闭状态

按优先级排序：

1. **`kv_cache_ram.sv` 的真正多 bank URAM 实现：已关闭**
   - 当前使用 8-bank XPM/URAM 组织，v2.4 post-route 使用 48 URAM tiles。
   - 容量合同是当前 KV head、`MAX_SEQ_LEN=512`，不是 8 个 KV heads 同时驻留。

2. **`softmax_engine.sv` 的完整 synthesis path：已关闭**
   - LUT exp、correction、m/l state 和 partial tile 路径已进入当前综合版本。

3. **`psum_accum.sv` 的完整 synthesis 累加路径：已关闭**
   - split/reuse 累加路径已通过 VCS/综合回归。

4. **`output_buffer.sv` 的 synthesis 数值路径：已关闭**
   - correction multiply/add 已流水化，normalize、RAW hazard 和 bank drain 已进入 v2.2 routed design。

5. **`attn_top.sv` 的 head/group/tile 数据流：数据通路已关闭，板控继续验证**
   - 32 Q heads / 8 KV groups / partial Q/KV tile traversal 已通过 full traversal；本轮继续关闭真实 CSR/DMA 板控。

6. **GQA 级别的 K/V 复用：本轮实现**
   - CSR_LOAD_REQ + driver 每 group 发送一次 K/V，4 个 Q heads 复用。

### 9.2 相比 `~/git/xx`，LARA 还没完全继承到的性能工程能力

`xx` 已有、LARA 仍需继续补齐的能力（当前 RTL/driver 已有基本闭环，板上证据仍待补齐）：

- **完整 DMA 数据通路和状态机打磨**
  - `xx` 的 stream sink/source 更完整，包含 staging、一致的 commit 时序、read-back pipeline。

- **软件侧的 DMA / overlap / profiling 闭环**
  - `xx/sw/cim_driver.py` 已经把 DMA load、S2MM readback、ping-pong overlap、分项 timing 做得很完整。
  - LARA 的 `sw/attn_driver.py` 已支持 request-service、DMA/compute/stall counter 和 workstation mock；真正的 PYNQ latency/overlap 仍需板上测量。

- **批处理 / overlap 导向的 driver 设计**
  - `xx` 有明确的 ping-pong batch 推进逻辑；
  - LARA 还没把 `Q tile` 加载、`O tile` 写回、下一 tile 预取在 driver 和 top 上闭成环。

- **参数 sweep 与回归脚本**
  - `xx` 有更成熟的 build / regression / sweep 工作流；
  - LARA 目前验证已经不少，但性能扫描还不成体系。

### 9.3 对 LARA 最现实的性能路线

**P0：当前改为关闭板上控制和可复现证据链**
- CSR/AXIS request-service 控制
- PYNQ DMA zero-input smoke
- 预计算 Q/K/V 与 Golden Model 对比
- board latency / DMA / stall counter 记录

**P1：在不改变模型语义前提下做性能增强**
- GQA 跨 4 个 Q heads 的 K/V 复用
- load / compute / write overlap
- RoPE 吞吐提升（如 2 或 4 pair/cycle）
- 16×32 参数化探索

**P2：再考虑近似或压缩**
- Softermax
- KV cache quantization / eviction
- 稀疏 prefill

结论很直接：

> 对 Llama3.1-8B 这类 GQA 模型，LARA 眼下最大的收益来自  
> **把 K/V cache、softmax、psum、output 的综合版本做真**，再把  
> **GQA 复用 + overlap** 做完整。  
> 这两类工作带来的收益，大概率会比立即引入近似 softmax 或 KV 压缩更稳、更可控。

---

## 10. 2026-07-15 赛题复核与本轮采用的优化

### 10.1 官方赛题事实（重新核对）

- **官方页面**：[FPT'26 Design Competition](https://fpt2026.uark.edu/fpt26-design-competition/)。页面明确将 Track B 定义为 FPGA attention acceleration，目标为 Llama3-8B 或参数一致模型。
- Track B 要求支持 **bf16**，并允许选择带 AI Core 或不带 AI Core 的配置；当前 LARA 选择“不带 AI Core”的 KV260 配置，目标是尽量减少 DSP/LUT/FF。
- 官方评价维度是 **performance、hardware architecture optimizations、scalability**，因此只证明功能正确不够，还需要报告资源、时序、DMA/板上吞吐和可扩展边界。
- 官方提交要求包括 IEEE 双栏两页以内技术论文（可附录）、最多 5 分钟板上演示；本地 `docs/Track-B-Submission-Guidelines.docx` 还要求 Vivado/Vitis 2025.2、可复现源码、FPGA 工程和 testbench。

当前设计与硬性要求的对应关系：

| 要求 | 当前状态 | 证据/边界 |
|---|---|---|
| Llama3-8B 参数一致 | 符合 | 32 Q heads、8 KV heads、head dim 128、GQA 4:1 |
| bf16 | 符合 | bf16 MAC、host bf16 packing、AXIS 两个 bf16/beat |
| Attention 在 FPGA | 符合 | QK、online softmax、AV、O accumulation 在 PL |
| QKV projection 是否必须上板 | 不要求 | 架构文档将其定义为 host-side boundary；本轮补齐自动化 host→DMA→FPGA 流程 |
| 无 AI Core 资源约束 | 符合 | KV260 PL-only，v2.4 post-route 165 DSP、88065 LUT、57718 FF |
| performance/scalability | 部分完成 | 83.333 MHz 已收敛；当前单序列 prefill、`MAX_SEQ_LEN=512`，decode/batching 尚未承诺 |

早期 HTML 文档中的“≥200 MHz”“256 DSP”等是架构估算或历史目标，不是当前签收结果。论文和演示应使用 Vivado post-route 报告中的 83.333 MHz、资源和实测板上数据。

### 10.2 外部方案的可追溯结论

1. **FlashAttention-2**：论文摘要明确指出减少 non-matmul FLOPs、沿 sequence 并行和重新划分 work partition；来源：[arXiv:2307.08691](https://arxiv.org/abs/2307.08691)。LARA 对应采用 online softmax、K/V on-chip reuse、Q/K/V tile overlap，而不是照搬 GPU warp 实现。
2. **llama.cpp GQA 实践**：已合并的 [PR #12014](https://github.com/ggml-org/llama.cpp/pull/12014) 明确写出 GQA 时跨多个 Q head 复用已加载 K/V，并指出 LLaMA 3 使用 4 个 Q 对 1 个 K/V。LARA 本轮将这一点从“文档建议”落实为 driver 请求服务：每个 KV group 只发送一次 K/V，服务 4 个 Q heads。
3. **KV cache/long-context 系统**：PagedAttention、FlashInfer、FlightLLM 等方案都把 KV cache 的分页、复用和 memory hierarchy 当作核心；但它们通常面向 decode、batch 或更大平台。KV260 当前优先关闭真实 URAM/BRAM 容量和事务正确性，不在 bf16 基线尚未板上验证前引入 KV 压缩或稀疏误差。

### 10.3 本轮实现的优化

- **GQA-aware DMA**：硬件通过 `CSR_LOAD_REQ` 暴露 KV/Q load request；driver 按 group/head/tile 描述符响应。K/V 从每 Q head 重复加载变为每 GQA group 加载一次，理论 K/V 传输次数降低 4×。
- **固定 Q tile padding**：最后不足 32 行的 Q tile 在 host 侧补零，硬件仍使用 `active_q_rows` 屏蔽无效行，避免 tile buffer 写计数跨 tile 错位。
- **单次 start、请求驱动**：取消同学分支中与当前单 bank KV cache 不匹配的 full-run 全量 K/V preload；一次 start 覆盖完整 group/head/tile 遍历，软件只服务硬件请求。
- **AXI 控制可靠性**：AW/W 地址和数据独立锁存，start 改为 W1P；status/error/done sticky；`0x100` performance CSR 不再与 `CTRL` 别名。
- **AXIS 事务边界**：sink 每个 DMA transfer 独立清零计数并锁存 destination，等高 halfword 真正写入后才发 done；source 限制 pending beat 不能被新 halfword 覆盖。
- **Host bf16/RoPE**：driver 使用 IEEE bf16 RNE packing，不把 float16 内存布局误当 bf16；host RoPE 改为向量化实现并支持 Q/K position base。

### 10.4 下一步优化优先级

1. **P0：完成真实板上控制链签收**：CSR/AXIS VCS test、零输入 smoke、预计算 Q/K/V 对 Golden Model，记录 DMA byte count、stall cycles 和端到端 latency。
2. **P1：双缓冲事务重叠**：保留当前单 KV cache，继续让下一 Q tile 在当前 tile 计算/写回时填入空闲 Q bank；若要 KV double-buffer，需要重新评估 URAM（当前 48/64 tiles）。
3. **P1：提高 softmax/psum 的真实综合效率**：先以 post-route critical path 为依据，再评估 base-2 Softermax；近似方案必须增加 bf16 误差回归，不能只看 LUT/频率。
4. **P2：长上下文扩展**：将 512 上限拆成 chunked prefill 或分页 KV cache；这属于 scalability 加分项，不应破坏当前 Llama3.1 bf16 基线。
5. **P2：性能模型和板上 benchmark**：分离 host projection、DMA K/V、DMA Q、PL compute、DMA O 时间，报告 tokens/s、有效 MAC 利用率和 bytes/token。
