# Track B 深度分析：FPGA Attention 加速器

## FPT'26 Design Competition — 完整准备路线图

> 状态说明（2026-07-18）：本文主体是项目启动阶段的学习/规划材料，不代表当前实现状态。当前部署上限为 `MAX_SEQ_LEN=512`，v2.5 Phase 1 已在 KV260 83.333 MHz 完成 post-route 时序收敛（WNS `+0.062 ns`，WHS `+0.010 ns`），资源为 165 DSP、95267 LUT、57838 FF、50 BRAM、48 URAM。当前 P0 已转为 CSR/DMA 软硬件协同、真实板上数值验证和端到端性能测量；文中的 200 MHz、2048 长度及早期资源数字只能作为探索目标。

---

## 目录

1. [知识体系分层](#1-知识体系分层)
2. [分层学习内容详解](#2-分层学习内容详解)
3. [6周开发路径](#3-6周开发路径)
4. [如何开始（第一周的具体操作）](#4-如何开始第一周的具体操作)
5. [你的主要工作与技术攻坚点](#5-你的主要工作与技术攻坚点)
6. [参考资源清单](#6-参考资源清单)
7. [毕设资产：INT8-CIM 项目可迁移分析](#7-毕设资产int8-cim-项目可迁移分析)

---

## 1. 知识体系分层

你需要的是一个**倒金字塔式**的知识结构，从算法到硬件逐层深入：

```
┌─────────────────────────────────────────┐
│  Layer 5: 论文写作 & Profiling 方法论    │ ← 最后一周
├─────────────────────────────────────────┤
│  Layer 4: Vitis HLS 综合优化 & 时序收敛   │ ← 开发后期
├─────────────────────────────────────────┤
│  Layer 3: FPGA 数据流架构设计 & 内存层级   │ ← 核心开发
├─────────────────────────────────────────┤
│  Layer 2: FlashAttention 算法与 bf16 精度 │ ← 前期理解
├─────────────────────────────────────────┤
│  Layer 1: Transformer / Attention 基础    │ ← 你已经有了
└─────────────────────────────────────────┘
```

---

## 2. 分层学习内容详解

### Layer 1: Transformer / Attention 基础

**你已有的基础：** 3Blue1Brown + The Illustrated Transformer → 建立了对 Q/K/V、多头注意力、softmax 的直观理解

**还需要补齐的（LLaMA 特有结构）：**

| 知识点 | 重要性 | 说明 |
|--------|--------|------|
| **GQA (Grouped Query Attention)** | ⭐⭐⭐⭐⭐ | Llama3-8B 用 8 个 KV head 服务 32 个 Q head，直接决定你的硬件架构——每4个Q head共享同一份K/V |
| **RoPE (Rotary Position Embedding)** | ⭐⭐⭐⭐ | 在 QK^T **之前**对 Q 和 K 施加旋转，bf16 硬件需要处理这个额外的元素级操作 |
| **RMSNorm** | ⭐⭐ | LayerNorm 的简化版，去掉减均值，只看 RMS 缩放 |
| **SwiGLU FFN** | ⭐ | Feed-Forward，这次不做，但要知道它在注意力层之后 |

**GQA 对你硬件设计的关键影响：**

```
标准 MHA (32 heads):    Q: 32×128,  K: 32×128,  V: 32×128
Llama3 GQA (32Q/8KV):   Q: 32×128,  K:  8×128,  V:  8×128
                                         ↑          ↑
                                    KV 只有 1/4 大小！
```

GQA 是**利好你的**：KV 缓存更小，对 FPGA 的 BRAM 压力降低 4 倍。

---

### Layer 2: FlashAttention 算法与 bf16 精度

这是你**真正需要深挖的核心层**。

#### 2.1 从朴素 Attention 到 FlashAttention：为什么必须做分块

朴素 Attention 的问题：

```
S = Q × K^T          # [N, 128] × [128, N] = [N, N]  
P = softmax(S)       # [N, N] 需要完整的 N×N 矩阵
O = P × V            # [N, N] × [N, 128] = [N, 128]
```

那个 **N × N 的中间矩阵是灾难**。假设序列长度 N=4096：

| 数据类型 | N×N 矩阵大小 |
|----------|-------------|
| fp32 | 4096² × 4 = **64 MB** |
| bf16 | 4096² × 2 = **32 MB** |

KV260 的片上存储由约 **5.1 Mb BRAM + 20.7 Mb URAM** 组成（合计约 3.2 MB）。即使合计计算，仍无法容纳 4096×4096 的 N×N 矩阵，因此不可能用朴素方法。

**FlashAttention 的核心洞察：**

不存完整的 N×N 矩阵，而是把 Q 按行分块（每块 B_r 行），K/V 按列分块（每块 B_c 行），逐块计算，利用 **online softmax** 逐步更新结果。

**Online Softmax 的数学技巧（这是你必须在硬件里实现的）：**

```
传统 softmax 需要两遍：
  第1遍: m = max(x_i),  d = Σ exp(x_i - m)
  第2遍: y_i = exp(x_i - m) / d

Online softmax 一遍完成：
  维护状态: (m_old, ℓ_old, O_old)
  对新来的 score s_new:
    m_new = max(m_old, s_new)
    ℓ_new = ℓ_old × exp(m_old - m_new) + exp(s_new - m_new)
    O_new = O_old × (ℓ_old/ℓ_new) × exp(m_old - m_new)  
            + V_new × exp(s_new - m_new) / ℓ_new
```

**这是你 FPGA 数据流控制的核心——你的硬件就是在循环执行这三个更新公式。**

#### 2.2 bf16 数据格式与 DSP48E2 实现

**bf16 格式：**

```
┌───┬──────────┬───────────┐
│ S │  Exp(8)  │ Mant(7)   │
└───┴──────────┴───────────┘
 1b     8b          7b

与 fp32 对比:
fp32: 1 + 8 + 23  → 范围 ±3.4e38, 精度 ~7 位十进制
bf16: 1 + 8 + 7   → 范围 ±3.4e38, 精度 ~2 位十进制  
                    ↑ 范围相同！精度降低但不会溢出
```

bf16 是专门为深度学习设计的——**保持 fp32 的动态范围，牺牲精度换面积**。

**DSP48E2 实现 bf16 乘法：**

DSP48E2 的结构 (UG579)：
```
输入A (30-bit)  ──┐
                  ├── 27×18 乘法器 ──→ 48-bit 累加器 ──→ 输出P (48-bit)
输入B (18-bit)  ──┘        ↑
输入C (48-bit)  ───────────┘
```

bf16 乘法分解：
```
a = (-1)^sa × 2^(ea-127) × (1.ma)
b = (-1)^sb × 2^(eb-127) × (1.mb)

结果 = (-1)^(sa⊕sb) × 2^(ea+eb-127) × (1.ma)(1.mb)

三部分计算:
  sign:   sa ⊕ sb                    → 1 bit XOR，用 LUT
  exp:    ea + eb - 127              → 8-bit 加法 + 常数减，用少量 LUT
  mant:   (1.ma) × (1.mb)           → 8×8 无符号乘法，用 1 个 DSP48E2
  normalize & round                  → 前导零检测 + 移位，用 LUT
```

**一个 bf16 乘法 ≈ 1 个 DSP48E2 + ~100 LUT**

对于 bf16 MAC（乘加），需要累加器精度更高（bf16 乘积的有效精度约 16 bit，多次累加后需要更宽），可以用 DSP48E2 的 48-bit 累加器做定点累加，最后再转回 bf16。

**但更实用的方法：Vitis HLS 2023+ 原生支持 bf16**

```cpp
#include <hls_half.h>  // 或 ap_fixed 自定义

// 方式 1: 用 AMD 提供的 bf16 库
typedef hls::bfloat16 bf16;

// 方式 2: 自定义定点模拟 bf16
typedef ap_fixed<16, 8> bf16_custom;  // 16-bit, 8-bit 整数部分

// 方式 3: 手动实例化 DSP48E2 (最底层控制)
```

**推荐路线**：先用 Vitis HLS 的 `hls::bfloat16` 快速出原型，如果资源不够再考虑手动优化。

---

### Layer 3: FPGA 数据流架构设计

参考 **SWAT（sparse sliding-window attention，arXiv:2405.17025）** 的窗口化数据流。它是稀疏滑动窗口 attention 研究，不是 LARA 当前 dense、causal baseline 的直接性能基线；这里仅借鉴窗口调度和片上复用的思路：

```
                    ┌────────── Q Buffer ──────────┐
DDR4 ──────────────→│  (BRAM, 一个 Q row block)    │──→ 各 attention core
                    └──────────────────────────────┘

                    ┌───────── K/V Buffers ─────────┐
DDR4 ──────────────→│  (BRAM, 滑动窗口内多行 K/V)   │──→ 各 attention core
                    └──────────────────────────────┘

每个 Attention Core = {
    1 行 K (128 × bf16),
    1 行 V (128 × bf16),
    1 个 QK^T 点积单元 (128 MACs, DSP48E2),
    1 个 exp 单元 (LUT),
    1 个 SV 乘加单元
}
```

**数据流三阶段流水线：**

```
Stage 1: LOAD     ──  从 DDR4 加载 Q 行和 K/V 行到 BRAM
Stage 2: QK^T     ──  点积 + softmax 分子 (全部在片上)
Stage 3: SV+DIV   ──  与 V 乘加 + 行求和 + 归一化
```

三个阶段用 `#pragma HLS dataflow` 重叠执行——当前 token 在做 QK^T 时，下一 token 的数据已经在加载了。

**KV260 资源规划（早期估算；当前签收值见文档顶部和 `competition_alignment.md`）：**

| 资源 | KV260 总量 | 建议分配 | 用途 |
|------|-----------|---------|------|
| DSP48E2 | 1,248 | ~800-1000 | 512 给矩阵乘法阵列 + 余量给 softmax |
| BRAM | 5.1 Mb | 50 tiles（v2.2） | Q/输出缓冲、LUT 和辅助存储 |
| URAM | 20.7 Mb | 48 tiles（v2.4） | 当前 GQA group 的 K/V cache |
| LUT | 117,120 | 87,235（v2.2） | bf16 控制逻辑、exp 查表、地址生成 |
| FF | 234,240 | 57,306（v2.2） | 流水线寄存器 |
| DDR4 | 4 GB | 按需 | 模型权重 + 输入/输出 |

**为什么用行优先而不是 systolic array？**

两个原因：
1. Softmax 是**行级操作**，行优先数据流天然匹配：一行 Q 算完 softmax 后立即归一化，不需要跨行同步
2. GQA 下 K/V 复用：8 个 KV head 每行可以被 4 个 Q head 共享，行优先让复用更自然

---

### Layer 4: Vitis HLS 综合优化

关键 pragma 和技巧：

```cpp
// 1. 顶层数据流
#pragma HLS dataflow
void attention_accelerator(...) {
    #pragma HLS stream variable=q_stream depth=16
    #pragma HLS stream variable=k_stream depth=16
    load_data(...);     // 数据加载
    compute_qk(...);    // QK^T 点积
    compute_sv(...);    // Softmax + SV
    write_output(...);  // 写回 DDR
}

// 2. 点积循环 — 关键是 II (Initiation Interval)
// 目标 II=1 意味着每个 cycle 发射一个新乘法
for (int i = 0; i < HEAD_DIM; i++) {
    #pragma HLS pipeline II=1
    acc += q[i] * k[i];  // bf16 MAC, 映射到 DSP48E2
}

// 3. 数组分区 — 使 BRAM 多端口
bf16 k_buffer[MAX_SEQ][HEAD_DIM];
#pragma HLS array_partition variable=k_buffer cyclic factor=16 dim=2
// 把 HEAD_DIM=128 分成 16 份，每份 8 个元素，可并行读取

// 4. 循环展开
for (int h = 0; h < NUM_HEADS; h++) {
    #pragma HLS unroll factor=4  // 4 个 head 并行
    ...
}
```

**SWAT 论文中的经验数据（值得参考）：**

| 操作 | 最优 II | 原因 |
|------|---------|------|
| bf16 MAC (QK^T) | **II=3** | 更低的 II 会显著增加资源（DSP 级联路径变长） |
| bf16 乘法 (SV) | **II=3** | 与 QK 阶段匹配，平衡流水线 |
| 除法 (归一化) | **II=2** | 1/ℓ 用倒数近似 + 乘法；不需要更高吞吐 |

---

### Layer 5: Profiling 分析与论文写作

竞赛明确要求用 profiling 工具作为主要性能指标。你需要掌握：

1. **Vitis HLS Synthesis Report** → 资源使用 (DSP/BRAM/LUT/FF)、latency (cycles)、II
2. **Vitis Analyzer** → 实际运行时的带宽利用率、流水线停顿
3. **性能指标换算**：
   ```
   Latency (ms) = cycles / frequency
   Throughput (tokens/s) = 1 / latency_per_token
   GOPS = MAC_ops / latency
   GOPS/DSP = GOPS / DSP_count    ← 这是竞赛看重的效率指标
   ```

**论文 2 页正文的结构建议：**

```
第1栏:  Introduction + 架构设计图
        - 为什么 attention 是瓶颈
        - 你的数据流架构示意图
        - GQA 适配的要点

第2栏:  实现细节 + 结果
        - bf16 在 DSP48E2 上的实现
        - 资源使用表
        - 性能对比表 (vs CPU/GPU baseline)
        - Latency vs seq_len 折线图

附录 (不限页数): 
        - 消融实验 (tile size、DSP数量等参数扫描)
        - HLS 综合报告截图
        - 更多硬件细节
```

---

## 3. 6周开发路径

```
Week 1  ████ 算法理解 + 参考实现
Week 2  ████ HLS 最小原型 + C仿真
Week 3  ████ 架构优化 + 资源调优
Week 4  ████ 综合迭代 + Profiling
Week 5  ████ 论文初稿 + 补充实验
Week 6  ████ 论文打磨 + 提交
```

| 周次 | 日期 | 目标 | 具体产出 |
|------|------|------|---------|
| **W1** | 6/28–7/6 | 算法吃透 | Python 参考模型（bf16 attention），HLS 环境搭好，跑通第一个乘加 kernel |
| **W2** | 7/7–7/13 | 最小可行原型 | 单 head attention 在 C 仿真下通过（不做优化），注册报名 7/7 |
| **W3** | 7/14–7/20 | 架构迭代 | 数据流流水线，多 head 并行，K/V 复用，资源初步达标 |
| **W4** | 7/21–7/27 | 综合优化 | Vitis HLS 综合通过，收集资源/时序数据，调 tile size |
| **W5** | 7/28–8/3 | 实验+论文 | 完成所有消融实验，论文初稿（2页正文），profiling 数据收齐 |
| **W6** | 8/4–8/7 | 打磨提交 | 论文反复修改，附录整理，8/7 提交 |

---

## 4. 如何开始（第一周的具体操作）

### Day 0 (现在): 确认工具链

```bash
# 确认 Vitis 版本 (建议 2023.2 或 2024.1)
which vitis_hls
vitis_hls --version

# 确认 KV260 平台文件位置
ls $PLATFORM_REPO_PATHS  # 或检查你的 xpfm 文件
```

### Day 1–2: 写 Python 参考模型

```python
import torch
import torch.nn.functional as F

def flashattn_reference(q, k, v, block_size=64):
    """
    q, k, v: [batch, heads, seq_len, head_dim] in bf16
    在你的 KV260 上跑不了 PyTorch，这步在 PC 上做
    """
    B, H, N, D = q.shape
    O = torch.zeros_like(q)
    
    for i_start in range(0, N, block_size):
        i_end = min(i_start + block_size, N)
        qi = q[:, :, i_start:i_end, :]  # [B, H, Br, D]
        
        # 重置 online softmax 状态
        m = torch.full((B, H, Br, 1), -float('inf'), dtype=torch.float32)
        l = torch.zeros((B, H, Br, 1), dtype=torch.float32)
        O_block = torch.zeros((B, H, Br, D), dtype=torch.float32)
        
        for j_start in range(0, N, block_size):
            j_end = min(j_start + block_size, N)
            kj = k[:, :, j_start:j_end, :]  # [B, H, Bc, D]
            vj = v[:, :, j_start:j_end, :]
            
            # QK^T: [Br, D] × [D, Bc] = [Br, Bc]
            s = torch.matmul(qi, kj.transpose(-2, -1)) / (D ** 0.5)
            
            # Online softmax update
            m_new = torch.maximum(m, s.max(dim=-1, keepdim=True).values)
            l_new = l * torch.exp(m - m_new) + torch.exp(s - m_new).sum(dim=-1, keepdim=True)
            
            # 更新输出
            O_block = O_block * (l / l_new) * torch.exp(m - m_new) \
                       + torch.exp(s - m_new) @ vj
            
            m = m_new
            l = l_new
        
        O[:, :, i_start:i_end, :] = O_block.to(torch.bfloat16)
    
    return O

# 验证：与标准 attention 对比
q = torch.randn(1, 8, 512, 128, dtype=torch.bfloat16)
k = torch.randn(1, 8, 512, 128, dtype=torch.bfloat16)
v = torch.randn(1, 8, 512, 128, dtype=torch.bfloat16)

ref = F.scaled_dot_product_attention(q, k, v)
mine = flashattn_reference(q, k, v)

print(f"Max diff: {(ref - mine).abs().max().item():.6f}")
```

这个 Python 模型是你的**黄金参考**——HLS 的 C 仿真输出要和它逐比特对齐。

### Day 3–4: 搭建 HLS 环境 + 最小乘法单元

参考 [XUP PBL Matmult Tutorial](https://xilinx.github.io/xup_high_level_synthesis_design_flow/pbl.html)，跑通一个简单的 bf16 矩阵乘法 kernel：

```cpp
#include <hls_stream.h>
// bf16 × bf16 → bf16, 用 DSP48E2

void bf16_matmul(
    hls::stream<float> &a_stream,   // 通过 AXI stream 进入
    hls::stream<float> &b_stream,
    hls::stream<float> &c_stream,
    int M, int N, int K
) {
    #pragma HLS interface ap_ctrl_none port=return
    #pragma HLS dataflow
    
    // ... 你的矩阵乘法逻辑
}
```

目标：在 Vitis HLS 里跑通 C simulation，看到波形/周期数。

### Day 5–6: 把 FlashAttention 翻译成 HLS C++

关键数据结构设计：

```cpp
// 每一行的 K/V 缓存（BRAM 实现）
bf16 K_cache[MAX_SEQ][HEAD_DIM];  
bf16 V_cache[MAX_SEQ][HEAD_DIM];

// online softmax 状态（寄存器实现）
float m_state[B_r];       // running max
float l_state[B_r];       // running sum
float O_state[B_r][D];    // running output (fp32 累加，最后转 bf16)

// 分块循环
for (int i = 0; i < N; i += B_r) {
    // 外循环：加载 Q block
    for (int j = 0; j < N; j += B_c) {
        // 内循环：加载 K/V block, 做 QK^T + online softmax
        compute_block(i, j);
    }
}
```

### Day 7: 注册报名 (7月7日截止！)

这不能忘。访问 [www.fpgachina.cn](http://www.fpgachina.cn) 注册。

---

## 5. 你的主要工作与技术攻坚点

### 核心工作（占 80% 精力）

```
┌──────────────────────────────────────────────┐
│           你的核心工作 = 映射                  │
│                                              │
│   FlashAttention 算法  ──映射──→  HLS C++     │
│         (数学)                    (硬件描述)   │
│                                              │
│   关键映射决策:                                │
│   1. 哪个循环用 pipeline, 哪个用 dataflow      │
│   2. 哪些数组用 BRAM, 哪些用寄存器              │
│   3. 哪个维度展开 (unroll), 展开多少            │
│   4. bf16 累加器是用 fp32 还是自定义定点         │
│   5. tile size B_r, B_c 设多大                 │
└──────────────────────────────────────────────┘
```

### 技术攻坚点（按难度排序）

| 攻坚点 | 难度 | 说明 |
|--------|------|------|
| **Online softmax 的状态管理** | ⭐⭐⭐⭐⭐ | m/l/O 三个状态的更新逻辑是数据流中最复杂的部分，必须确保流水线不阻塞 |
| **bf16 乘累加的精度验证** | ⭐⭐⭐⭐ | HLS C 仿真输出与 Python 参考对比，查精度损失源头 |
| **DDR4 带宽优化** | ⭐⭐⭐⭐ | KV260 DDR4 理论带宽 ~19.2 GB/s，必须用 burst transfer + 双缓冲；SWAT 的窗口化复用可作为稀疏访问参考，但其带宽数字不能直接套用到 LARA dense 路径 |
| **多 head 并行调度** | ⭐⭐⭐ | GQA 下 Q-head / KV-head 的映射和复用调度 |
| **RoPE 实现** | ⭐⭐⭐ | 在 QK^T 之前对 Q/K 施加旋转变换，用 CORDIC 或查表 |
| **资源利用率拉满** | ⭐⭐⭐ | DSP/BRAM/LUT 的平衡——用了太多 DSP 则 LUT 不够做控制，反之亦然 |

### 你不需要做的

- ❌ 完整的 Llama3-8B 推理（只需要 attention 层，不是整个模型）
- ❌ Transformer 其他部分（FFN、Embedding、LM Head）
- ❌ 训练/微调（只做推理时的 attention 计算）
- ❌ 板上部署完整的 LLM 推理系统（profile 可以用 HLS 综合报告 + Vitis Analyzer，不一定需要完整端到端运行）

### 论文中需要展示的关键图

1. **架构框图**：数据在 DDR → BRAM → DSP → BRAM → DDR 之间的流动
2. **流水线时序图**：LOAD / QK^T / SV+DIV 三个阶段的重叠执行
3. **资源利用率饼图**：DSP/BRAM/LUT/FF 各自的占比
4. **性能对比图**：Latency vs Seq_len (你的设计 vs CPU baseline vs GPU baseline)
5. **消融实验表**：不同 tile size / DSP 数量对延迟和资源的影响

---

## 6. 参考资源清单

### 论文（必读）

| 论文 | 为什么重要 |
|------|-----------|
| [FlashAttention (NeurIPS 2022)](https://arxiv.org/abs/2205.14135) | 分块 + online softmax 的原始论文，算法基础 |
| [FlashAttention-2 (2023)](https://arxiv.org/abs/2307.08691) | 改进的并行策略和缩放技巧 |
| [SWAT (sparse sliding-window attention)](https://arxiv.org/abs/2405.17025) | 稀疏窗口调度和片上复用的参考；不作为 LARA dense attention 的直接性能基线 |
| [Persistent-State Dataflow (2025)](https://arxiv.org/abs/2603.05931) | 另一种 FPGA attention 数据流范式 |
| [Llama 3 技术报告](https://arxiv.org/abs/2407.21783) | GQA、RoPE 等 Llama3 特有结构的权威描述 |

### 教程/工具

| 资源 | 用途 |
|------|------|
| [XUP HLS PBL Tutorial (Matmult)](https://xilinx.github.io/xup_high_level_synthesis_design_flow/pbl.html) | 跑通 Vitis HLS 全流程：Python → HLS → 板上 |
| [Online Softmax 推导 (UW CSE599M)](https://courses.cs.washington.edu/courses/cse599m/23sp/notes/flashattn.pdf) | 数学证明，帮你彻底理解 online softmax |
| UG579 (DSP48E2 User Guide) | DSP48E2 架构细节，查你的 bf16 乘法能多高效 |
| UG1399 (Vitis HLS User Guide) | pragma 参考，interface 和 dataflow 的官方文档 |

### 代码参考

| 项目 | 用途 |
|------|------|
| [huggingface transformers — LlamaAttention](https://github.com/huggingface/transformers/blob/main/src/transformers/models/llama/modeling_llama.py) | Llama3 GQA attention 的 PyTorch 参考实现 |
| [llama.c](https://github.com/karpathy/llama2.c) | 纯 C 的 Llama 推理，FP32 attention，可做 C 参考 |
| [Xilinx Vitis-Tutorials](https://github.com/Xilinx/Vitis-Tutorials) | KV260 + HLS 的多种官方示例 |

---

## 7. 毕设资产：INT8-CIM 项目可迁移分析

> 本节是项目启动阶段的迁移思路，不是当前 RTL 的模块合同。当前实现使用 `kv_cache_ram.sv` 的多 bank URAM（每次驻留一个 GQA group 的 KV head）和 `tile_buffer.sv` 的 Q ping-pong；不要将下方示例中的 BRAM 滑动窗口或 HLS pragma 视为已实现功能。

> 你的毕设仓库：[Invoker-pray/INT8-CIM-of-jiao](https://github.com/Invoker-pray/INT8-CIM-of-jiao)  
> 在 PYNQ-Z2 / KV260 上做的 INT8 存算一体 SoC FPGA 验证平台，跑 LeNet-5/MNIST

### 7.1 毕设项目概览

| 维度 | 你的毕设 (INT8-CIM) | Track B (Attention) |
|------|-------------------|-------------------|
| **精度** | INT8 | bf16 |
| **核心计算** | MAC 阵列 (DSP48) | QK^T 点积 + Softmax + SV |
| **数据流** | 前馈 (load→compute→store) | 循环嵌套 + tile 间状态依赖 |
| **内存模式** | 权重驻留 SRAM，一次加载 | K/V 滑动窗口，动态换入换出 |
| **控制** | 简单 FSM / PicoRV32 | Online softmax 状态机 |
| **规模** | MNIST (28×28 → 10类) | head_dim=128, seq 可变 |
| **开发方式** | SystemVerilog RTL 手写 | Vitis HLS (C++ → RTL) |
| **FPGA** | PYNQ-Z2 (Zynq-7020) | KV260 (Zynq UltraScale+) |

### 7.2 核心可迁移组件对照

#### 7.2.1 MAC 阵列拓扑 → Attention QK^T 点积阵列

**毕设做法**：16×16 DSP48 MAC 阵列，每列串行累加 16 个乘法结果，16 列并行输出 16 个通道。

**Track B 对应**：

```
毕设 CIM MAC 阵列:                   Track B QK^T 点积阵列:

w[0][0] → [DSP] ↘                  q[0]   → [DSP] ↘
w[0][1] → [DSP] → [+] → ch[0]      q[1]   → [DSP] → [+] → score[0]
  ...                                  ...
w[0][15]→ [DSP] ↗                  q[127] → [DSP] ↗

16 列并行 = 16 通道输出              16 列并行 = 16 个 attention score
```

**改动**：INT8→bf16，DSP48E1→DSP48E2，但阵列拓扑和树形加法器结构完全相同。

**迁移难度**：⭐（直接复用，改精度即可）

---

#### 7.2.2 双缓冲 IBUF/OBUF → Attention K/V 滑动窗口

**毕设做法**（Phase B）：IBUF/OBUF ping-pong — DMA 往 bank A 写数据时，CIM 从 bank B 读数据计算，重叠数据搬运和计算。

**Track B 对应**：

```
                    ┌─────────────────┐     ┌─────────────────┐
DDR4 ─── DMA ─────→│  K/V Buffer A    │←───→│  K/V Buffer B    │
                    │  (当前 Q block   │     │  (预加载下一个    │
                    │   正在使用)       │     │   block 的 K/V)  │
                    └─────────────────┘     └─────────────────┘
```

这是将 SWAT 的窗口化/片上复用思想映射到 LARA 的一种候选实现。SWAT 面向稀疏滑动窗口，不能直接把论文中的数据流或吞吐数字当作当前 dense attention 的结论；LARA 的实际边界仍以 RTL、Vivado 和板上测量为准。

**关键差异**：毕设的缓冲区切换是**层间**的（FC1 OBUF → FC2 IBUF）；Track B 的缓冲区切换是 **tile 间**的（K/V block j → block j+1），但物理实现是一样的。

**迁移难度**：⭐⭐（控制逻辑稍复杂——需要维护滑动窗口的 FIFO 替换策略）

---

#### 7.2.3 层融合 (OBUF→IBUF) → Online Softmax Tile 间状态传递

**毕设做法**（Phase C）：OBUF→IBUF 硬件直拷 FSM，消除 FC 层间 DMA 往返。FC1 的 OBUF 直接拷到 FC2 的 IBUF，连 S2MM+MM2S 的 DMA 开销都省了。

**Track B 对应**：

```
Tile 1 K/V block → online softmax 更新 → (m₁, ℓ₁, O₁)
                                              ↓ 直通（不经过 DDR）
Tile 2 K/V block → online softmax 更新 → (m₂, ℓ₂, O₂)
                                              ↓
Tile 3 K/V block → ...
```

同一个思想——**避免中间数据经过 DDR 往返**：

| 毕设 | Track B |
|------|---------|
| 融合对象 | 两层 FC 之间 | 两个 K/V tile 之间 |
| 传递数据 | 784 维激活向量 | m/l/O 三个状态标量/小向量 |
| 硬件机制 | OBUF→IBUF 直拷 FSM | 寄存器直通 + scale/rescale 逻辑 |

**迁移难度**：⭐⭐⭐（多了 scale/rescale 的乘法操作，但数据量极小，全寄存器实现）

---

#### 7.2.4 AXI DMA 数据通路 → Attention 权重/数据搬运

**毕设做法**（C3/P0 DMA）：全程 AXI4-Stream DMA——

```
DDR → S_AXI_HP0 → axi_dma → AXIS → cim_axi_stream_sink (加载)
cim_axi_stream_source → AXIS → axi_dma → S2MM → DDR (读回)
```

对比 MMIO 基线获得了 **13.2× 加速**。

**Track B 对应**：

```
DDR4 → DMA → AXIS → 加载 Q/K/V 权重 + 输入 token 到 BRAM
输出 BRAM → AXIS → DMA → DDR4
```

Vitis HLS 里用 interface pragma 一行搞定：

```cpp
#pragma HLS interface axis port=q_stream
#pragma HLS interface m_axi port=weights offset=slave bundle=gmem
```

你毕设里踩过的 DMA 对齐、burst length、stream width 的坑（比如 AXI 4KB 边界问题），Track B 全都会遇到——但这次你有经验了。

**迁移难度**：⭐⭐（HLS 屏蔽了很多底层细节，但带宽分析的方法论一致）

---

#### 7.2.5 Golden Model → 硬件验证方法论

**毕设做法**：`golden_model.py` 提供 INT8 bit-accurate 参考输出，testbench 自动对比。

**Track B 对应**：

```
Python 参考模型            HLS C 仿真
(bf16 FlashAttention)  →  逐比特对比
     ↓                        ↓
 黄金参考输出              硬件输出
```

完全一样的验证哲学，只是参考模型从 INT8 MLP 变成 bf16 FlashAttention。

**你在毕设里的 golden model 可以直接改造成 Track B 的参考模型**——把矩阵乘法换成 attention，INT8 换成 bf16，逻辑框架不变。

**迁移难度**：⭐（纯软件工作，在 PC 上完成）

---

#### 7.2.6 Performance Counter → Profiling 数据

**毕设做法**：CIM 加速器内部硬件周期计数器，提供 cycle-accurate 性能数据。

**Track B 对应**：

```cpp
// HLS 中获取 cycle count
#ifdef __SYNTHESIS__
    unsigned int start_cycle = __builtin_amd_cycle_slr();
    // ... attention 计算 ...
    unsigned int end_cycle = __builtin_amd_cycle_slr();
    unsigned int latency = end_cycle - start_cycle;
#endif
```

或直接用 Vitis HLS synthesis report 的 latency 数据。

竞赛明确要求 profiling tool 作为 primary performance metric——你的毕设已经建立了完整的 profiling 方法论。

**迁移难度**：⭐

---

#### 7.2.7 参数化设计 → Tile Size / Head Num 可配置

**毕设做法**：`cim_pkg.sv` 用 SystemVerilog package 统一管理 tile size、CSR 地址、FSM 状态编码等全局参数。

**Track B 对应**：

```cpp
// HLS 中用 constexpr / template 做参数化
template<int B_r = 64, int B_c = 64, int HEAD_DIM = 128, int NUM_HEADS = 8>
void attention_accelerator(...) { ... }
```

消融实验（不同 tile size / head 数的性能对比）可以直接通过改 template 参数来跑。

**迁移难度**：⭐（HLS 的 template 比 SV package 更灵活）

---

### 7.3 毕设优化路径的启发

你的毕设优化演进史是一个经过实战检验的模板，**Track B 可以直接套用**：

```
毕设优化路径:                         Track B 对应阶段:

MMIO 基线 (1690 ms) ──────────→  HLS 朴素实现 (功能正确)
       ↓ 13.2×                           ↓
DMA 数据通路 (128 ms) ─────────→  AXI Stream + dataflow pragma
       ↓ 2.3×                            ↓
双缓冲 (29.2 ms) ──────────────→  K/V ping-pong buffer
       ↓ 15×                             ↓
层融合 (1.9 ms) ───────────────→  Online softmax tile 间直通
       ↓                                 ↓
频率提升 (60→100 MHz) ─────────→  综合优化 (II 调优, 资源平衡)
       ↓                                 ↓
DSP SIMD packing (计划) ───────→  bf16 精度优化 (DSP48E2 级联)
```

**你的毕设已经完整走过一遍这个循环了**——Track B 是用 HLS 重新走一遍相同的方法论，换了一个更复杂的算法。论文中可以把每个优化阶段和对应的硬件改动讲清楚，这个叙事结构评委很买账。

### 7.4 毕设经验带来的竞争优势

| 优势 | 对 Track B 的意义 |
|------|------------------|
| **你已经调过 DSP48 阵列** | 知道资源瓶颈在哪，不会再犯初级错误 |
| **你已经做过 AXI DMA 数据通路** | 数据搬运和计算重叠的设计直觉已经建立 |
| **你已经写过 golden model** | 验证方法论成熟，知道怎么保证硬件输出正确 |
| **你已经做过 KV260 移植** | 平台文件和工具链不需要从零学起 |
| **你已经做过从 1690ms→1.9ms 的优化** | 你知道 FPGA 加速器的优化节奏和关键路径在哪里 |
| **你有 SystemVerilog 经验** | 即使 Track B 用 HLS，理解生成的 RTL 对你也是有帮助的 |

### 7.5 需要注意的关键差异

| 差异 | 毕设 (CIM) | Track B (Attention) | 影响 |
|------|-----------|-------------------|------|
| **开发语言** | SystemVerilog RTL | Vitis HLS (C++) | 需要适应 HLS 的 pragma 思维，但设计空间探索更快 |
| **精度** | INT8 | bf16 | DSP 用量翻倍（一个 bf16 MAC ≈ 2× INT8 MAC 的 DSP 消耗） |
| **算法复杂度** | MLP/CNN 前馈 | FlashAttention 分块 + online softmax | 控制状态机复杂得多，需要仔细设计数据流 |
| **验证重点** | 功能正确性 (输出 label) | **精度验证** (bf16 逐比特对比) | 浮点舍入误差分析是个新课题 |
| **规模** | MNIST (784→10) | head_dim=128, seq 可变 | 数据量大了很多，DDR 带宽是关键瓶颈 |

### 7.6 可用代码直接复用清单

| 毕设文件 | Track B 复用方式 |
|----------|-----------------|
| `weight_sram.sv` (16 bank 权重 SRAM) | K/V 缓存的 bank 划分思路 → HLS `array_partition cyclic factor=16` |
| `input_buffer.sv` + `output_buffer.sv` (双缓冲) | Q buffer / O buffer 的 ping-pong → HLS `stream` + `dataflow` |
| `cim_axi_stream_sink.sv` (AXIS→内部) | AXI4-Stream 接口 → HLS 里 `#pragma HLS interface axis` |
| `golden_model.py` (bit-accurate 参考) | 改造为 bf16 FlashAttention Python 参考 |
| `cim_pkg.sv` (参数化配置) | 改造为 HLS `constexpr` / template 参数 |
| `cim_accel_core.sv` (FSM 控制) | 作为 HLS dataflow 的控制逻辑参考 |

### 7.7 论文叙事建议

你的毕设优化历程本身就是一个强力的论文叙事：

> "我们之前在 INT8 CIM 加速器上经历过从 MMIO→DMA→双缓冲→层融合的优化循环，在 Track B 的 attention 加速器设计中，我们系统性地将这套方法论应用到 bf16 FlashAttention 的硬件映射中，同时针对 online softmax 的状态依赖和 softmax 的数值特性做了额外的定制优化..."

这个叙事有两层优势：
1. 证明你的优化方法论是**可复现的、系统性的**（不是碰运气）
2. 顺便展示你有丰富的 FPGA 加速器开发经验（给评委留下好印象）
