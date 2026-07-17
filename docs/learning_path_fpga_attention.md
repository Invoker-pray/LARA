# LARA 学习路线：从 RTL 到 FPGA Attention 优化

本文面向希望系统理解并继续开发 LARA 的读者。LARA 不是单一的 Verilog 练习，而是一个同时涉及 Transformer attention、bf16 数值实现、SystemVerilog RTL、AXI4-Lite/AXI4-Stream、AXI DMA、Vivado 时序收敛和 KV260 上板验证的软硬件协同项目。建议按下面的顺序学习，不要一开始就尝试修改 MAC 阵列或 softmax。

## 1. 先建立 LARA 的整体心智模型

当前设计的边界是：

```text
Host ARM/Python: RMSNorm -> QKV projection -> RoPE -> bf16 packing
KV260 PL:        QK^T -> online softmax -> P*V -> output normalize/writeback
```

当前部署合同为 32 个 Q heads、8 个 KV heads、GQA 4:1、head dimension 128、causal prefill、`MAX_SEQ_LEN=512`，PL-only，不使用 AI Engine。片上 KV cache 保存当前 GQA group 的 KV 数据，不能理解成 8 个 KV heads 全部同时驻留。

阅读顺序：

1. `docs/competition_alignment.md`：赛题边界和当前实现对应关系。
2. `docs/architecture_diagram.html`、`docs/dataflow_diagram.html`：模块和数据流图。
3. `hw/rtl/pkg/attn_pkg.sv`：所有公共参数、CSR 和 FSM 状态。
4. `hw/rtl/attn_top.sv`：AXI 外设、内存、MAC、softmax、核心 FSM 的连接。
5. `hw/rtl/core/attn_core.sv`：Q tile/KV tile/head/group 的控制循环。
6. `hw/rtl/core/attn_tile.sv`、`bf16_mac.sv`、`psum_accum.sv`：计算和累加路径。
7. `hw/rtl/core/softmax_engine.sv`、`output_buffer.sv`：数值敏感路径。
8. `sw/attn_driver.py`、`sw/host_attention.py`、`sw/board_test.py`：主机控制和上板流程。

先画出一张自己的时序图：`CSR configure -> arm S2MM -> start -> CSR_LOAD_REQ -> K/V DMA -> Q DMA -> PL compute -> O DMA`。只有能够解释每个握手信号何时产生、谁清除它、谁等待它，才适合修改控制器。

## 2. 推荐的系统课程和视频

### 2.1 数字电路、Verilog 和 RTL

- **HDLBits**：<https://hdlbits.06xz.com/wiki/Main_Page>
  - 用短题目练习组合逻辑、时序逻辑、FSM、移位寄存器和 RAM inference。
  - 对应 LARA：先完成 FSM、握手、同步 RAM、参数化 generate 题目。
- **Nandland FPGA/Verilog 教程**：<https://nandland.com/learn-verilog-with-vivado/>
  - 适合快速建立 Verilog、时钟、复位、Vivado 工程的基础。
- **VerilogPro**：<https://www.verilogpro.com/
  - 重点阅读 ready/valid、CDC、nonblocking assignment、FSM 和 AXI 相关文章。
- **Doulos HDL/FPGA 视频和教程**：<https://www.doulos.com/knowhow/fpga/
  - 适合补 SystemVerilog、断言、验证方法学和工程编码规范。
- **MIT 6.111 Digital Systems Laboratory**：<https://www.youtube.com/@MITOpenCourseWare>
  - 在频道中搜索 `6.111 digital systems`；重点看 FSM、流水线、存储系统和 FPGA 实验。
- **Nandland YouTube**：<https://www.youtube.com/@Nandland>
  - 搜索 `Verilog`, `VHDL`, `FPGA clock`, `UART`, `RAM`；适合作为 HDLBits 的视频补充。

学习目标不是背语法，而是能够回答：一个信号是组合产生还是寄存产生？复位释放后第几个周期有效？valid 拉高时 ready 是否稳定？一个数组最终被综合成 LUTRAM、BRAM、URAM 还是寄存器？

### 2.2 FPGA 架构、Vivado 和 KV260

- **AMD Vivado Design Suite User Guide: Design Analysis and Closure Techniques (UG906)**：<https://docs.amd.com/r/en-US/ug906-vivado-design-analysis>
  - 学习 `report_timing_summary`、关键路径、逻辑延迟、拥塞和物理优化。
- **AMD Vivado Design Suite User Guide: Using Constraints (UG903)**：<https://docs.amd.com/r/en-US/ug903-vivado-using-constraints>
  - 学习时钟约束、I/O delay、false path/multicycle 的正确边界。不要用错误约束掩盖真实数据路径。
- **AMD UltraScale+ DSP48E2 User Guide (UG579)**：<https://docs.amd.com/r/en-US/ug579-ultrascale-dsp>
  - 学习 DSP48E2 的乘法器、M/A/P 寄存器、级联和 SIMD 模式；LARA 的 bf16 mantissa 乘法和 `C4_MUL_PIPE` 都应回到此文档核对。
- **AMD AXI DMA Product Guide (PG021)**：<https://docs.amd.com/r/en-US/pg021_axi_dma>
  - 学习 MM2S/S2MM、simple mode、scatter-gather、BTT/length 宽度、TLAST、数据对齐和中断。
- **AMD AXI Reference Guide (UG1037)**：<https://docs.amd.com/r/en-US/ug1037-vivado-axi-reference-guide>
  - 学习 AXI4-Lite CSR、AXI4-Stream ready/valid 和 AXI memory-mapped 通道。
- **Kria KV260 官方资源**：<https://www.amd.com/en/products/adaptive-socs-and-fpgas/kria/k26/kv260-vision-ai-starter-kit.html>
  - 上板前阅读板卡启动、供电、启动介质、网络和 PYNQ/Vitis 环境说明。
- **AMD Adaptive Computing YouTube**：<https://www.youtube.com/@AMDAdaptiveComputing>
  - 搜索 `Vivado timing closure`, `AXI DMA`, `Kria KV260`, `UltraScale+ DSP`。
- **AMD FPGA YouTube**：<https://www.youtube.com/@AMDDevelopers>
  - 搜索 `Vivado Design Analysis`, `AXI4-Stream`, `PYNQ`。

推荐实践：每次改 RTL 后先看 post-synthesis hierarchy 和 critical path，再决定是否长时间 route。LARA 当前 v2.4 的 83.333 MHz post-route WNS 约为 `+0.049 ns`（需用 Explore 恢复流程获得），这意味着几乎没有“顺便再加一点组合逻辑”的余量。

## 3. 如何从 critical path 判断是否需要流水线

### 3.1 先定位，不要凭资源百分比猜

常用 Vivado 命令：

```tcl
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained
report_timing -max_paths 20 -sort_by group -path_type full_clock_expanded
report_design_analysis -congestion -logic_level_distribution
report_high_fanout_nets -max_nets 50
```

重点记录：

- 起点寄存器和终点寄存器。
- data path delay 与 routing delay 的比例。
- 逻辑级数、是否经过大范围 mux/reduction/fanout。
- 所属层级：MAC、softmax、output buffer、AXI 或控制器。
- setup、hold、clock uncertainty 和 slack。

### 3.2 用路径类型选择优化方法

| 关键路径特征 | 常见原因 | 优先手段 |
|---|---|---|
| DSP 乘法后到累加寄存器 | DSP 内部 M/P 寄存器未启用 | 使用 DSP48E2 内部寄存器，增加一级 product pipeline |
| 大量 bf16/FP32 bit-level 运算 | 尾数对齐、规格化、优先编码器过长 | 拆成输入寄存、运算、规格化/输出三级；避免一个 always_comb 串完所有步骤 |
| 16 路或 32 路归约 | adder tree 深、扇出大 | 平衡 tree，分组归约并在组间插寄存器 |
| 控制信号跨大层级布线 | 高扇出、跨区域 routing | 本地寄存控制、register slice、floorplan/区域约束；不要先加 false path |
| AXI/DDR 互连路径 | 宽总线、协议转换、未使用的高复杂度 DMA 配置 | 简化 DMA 参数、启用必要的 register slice、检查时钟域和数据宽度 |
| hold violation | 局部过短路径或时钟 skew | 让 Vivado 做 hold fix，检查时钟约束和过度的手工约束 |

### 3.3 “打开流水线”的正确步骤

1. 先用仿真锁定模块接口和周期行为，写下旧的 latency/handshake contract。
2. 在模块内部增加寄存器，不改变输入输出协议；如果 latency 改变，明确增加 `valid/done` 延迟。
3. 对 MAC：优先使用 `A/B -> M -> P/ACC` 的 DSP 内部寄存器，而不是把浮点运算全部搬到 LUT。
4. 对 reduction：将 `N` 项拆成 `N/2`、`N/4` 等平衡阶段，每阶段之间插寄存器。
5. 对 FSM：把“发起操作”和“等待结果”拆成不同状态，不要在一个周期同时依赖长组合结果和更新多个计数器。
6. 对存储器：先确保读延迟建模正确；BRAM/URAM 同步读通常至少增加一个周期。
7. 重新跑 focused VCS/Verilator test，特别检查 backpressure、partial tile、最后一个 beat 和 reset。
8. 重新综合，确认关键路径是否真的转移；只有 timing report 改善才保留改动。
9. 重新 place/route。旧 DCP 不能证明修改后 RTL 的时序。

不要把 multicycle path 或 false path 当作普通流水线手段。只有在架构上确实存在协议保证、且路径不需要在每个时钟周期采样时，才可以使用这些约束。

## 4. AXI DMA 优化学习和实践

### 4.1 必须掌握的概念

- **MM2S**：DDR/CMA buffer 到 PL stream。
- **S2MM**：PL stream 到 DDR/CMA buffer。
- **BTT/length**：DMA 一次事务的字节数；必须和 AXIS beat、TLAST 和 endpoint counter 一致。
- **CMA buffer**：PYNQ `allocate()` 得到的连续物理内存；反复分配会产生开销和碎片。
- **cache coherency**：MM2S 前 flush，S2MM 完成后 invalidate。
- **alignment**：保持 beat、行、tile 边界，避免拆开 128-bit 行或产生 DMA 对齐错误。
- **backpressure**：`valid && ready` 才算一个 beat；不能仅按 valid 计数。

### 4.2 推荐资料

- **AMD PG021 AXI DMA**：先读 simple mode，再读 S2MM、TLAST、length width 和错误状态。
- **PYNQ DMA 文档**：<https://pynq.readthedocs.io/en/latest/pynq_libraries.html>
  - 搜索 `DMA` 和 `allocate`，结合实际 overlay metadata 使用。
- **PYNQ 官方 GitHub**：<https://github.com/Xilinx/PYNQ>
  - 阅读 DMA Python driver 和 buffer API 的实现。
- **ZipCPU AXI/AXI-Stream 博客**：<https://zipcpu.com/blog/>
  - 搜索 `AXI stream`, `DMA`, `FIFO`, `formal`；重点学习 ready/valid 规则和如何写断言。
- **AMD/Xilinx AXI4-Stream 视频**：<https://www.youtube.com/@AMDAdaptiveComputing>
  - 搜索 `AXI4 Stream handshake`, `AXI DMA simple mode`, `PYNQ DMA`。
- **参考项目 `xx`**：
  - `/home/jiao/git/xx/docs/c3_dma_design.md`
  - `/home/jiao/git/xx/sw/cim_driver.py`
  - 重点看预分配 buffer、4-word 对齐分块、direct-register MM2S、S2MM readback、ping-pong 和 profiling。

### 4.3 LARA 中的 DMA 检查清单

每个传输都应能回答：

1. CSR 的 destination 是 K、V 还是 Q？
2. CSR length 的单位是 bytes 还是 32-bit beats？
3. 软件何时 arm DMA，何时写 accelerator configuration？
4. sink/source 何时锁存 destination 和 length？
5. `TLAST` 是否与最后一个有效 beat 同周期？
6. 最后一个半 beat 是否需要补零？
7. DMA status 的 halted/idle/error/IOC 位是否被清除？
8. buffer 是否 flush/invalidate？
9. 16 KiB 边界和最大 4 MiB 输出是否测试过？

LARA 当前应遵循“CSR 配置 endpoint，软件显式启动 DMA”的描述。不要把写 `CSR_STREAM_LEN` 写成 PYNQ DMA 已经自动启动。

## 5. Llama Attention 优化学习路线

### 5.1 数学和基础实现

- **The Annotated Transformer**：<https://nlp.seas.harvard.edu/annotated-transformer/>
  - 复习 QK^T、scale、mask、softmax、PV 和多头 reshape。
- **Hugging Face LLM Course**：<https://huggingface.co/learn/llm-course/chapter1/1>
  - 适合补 Transformer、tokenization、推理和模型张量布局。
- **Stanford CS25 Transformers**：<https://web.stanford.edu/class/cs25/>
  - 视频和讲义适合了解 attention、长上下文和系统优化背景。

### 5.2 必读论文和工程实现

- **FlashAttention**：<https://arxiv.org/abs/2205.14135>
  - 理解 tiled attention、IO-aware dataflow、online softmax 和不保存完整 score matrix。
- **FlashAttention-2**：<https://arxiv.org/abs/2307.08691>
  - 重点是减少 non-matmul FLOPs、改善 work partition；FPGA 上对应减少 FSM 空拍和 tile 间等待。
- **vLLM PagedAttention**：<https://arxiv.org/abs/2309.06180>
  - 学 KV cache 分页、prefix reuse 和 serving runtime；这是长上下文/多请求的系统方向，不是当前 dense kernel 的直接替换。
- **FlashInfer**：<https://github.com/flashinfer-ai/flashinfer>
  - 观察工业实现如何分别处理 prefill、decode、paged/ragged KV cache 和 mixed batching。
- **llama.cpp GQA/KV cache 实现**：<https://github.com/ggerganov/llama.cpp>
  - 搜索 GQA、KV cache、flash attention；理解 4 个 Q heads 复用一个 KV head 的实际数据搬运。
- **Softermax**：<https://arxiv.org/abs/2103.09301>
  - DAC 2021 的 base-2 softmax 硬件/软件协同方法。它是近似/重定义数值路径，必须先做模型级精度回归。
- **TeLLMe**：<https://arxiv.org/abs/2504.16266>
  - KV260 上的低比特 LLM 加速器，关注 prefill scheduling、memory hierarchy 和 edge FPGA 约束；不要直接复制其 ternary arithmetic。
- **AccLLM**：<https://arxiv.org/abs/2505.03745>
  - 观察 pruning、低比特权重和 KV4 如何通过算法-硬件协同降低内存带宽；超出当前精确 bf16 Phase 1。
- **FAST-Prefill**：<https://arxiv.org/abs/2602.20515>
  - 关注长上下文 sparse prefill 的 memory-aware execution 和 dual-tier cache；适合作为未来 `MAX_SEQ_LEN=512` 之外的研究方向。
- **FlatAttention**：<https://arxiv.org/abs/2505.18824>
  - 关注 many-PE tile fabric 的 dataflow；不要把大规模 tile mesh 的利用率直接外推到 KV260。

### 5.3 应该如何映射到 LARA

| 学到的概念 | LARA 对应点 | 当前建议 |
|---|---|---|
| IO-aware tiled attention | `attn_core` 的 Q/KV tile 循环 | 保持，先做 causal KV tile early-exit |
| online softmax | `softmax_engine` 的 m/l state | 保持精确语义，先做 row-lane DSE |
| GQA reuse | `CSR_LOAD_REQ` 和 driver request service | 先用板上 DMA 计数确认 4:1 复用 |
| paged/chunked KV | 当前尚未实现 | 作为 `L>512` scalability 路线 |
| approximate softmax | EXP LUT/Softermax | 先做 exact 路径和精度回归 |
| memory-aware prefill | Q ping-pong、KV URAM、DMA overlap | 先测 stall counter，再决定是否 double score buffer |

## 6. 推荐的动手练习顺序

### 阶段 A：能读懂并验证

1. 用 HDLBits 完成 FSM、RAM、FIFO、ready/valid 练习。
2. 跑 `python_godel/attention_golden.py --test-all`。
3. 跑 `python3 -m unittest -v sw.tests.test_attn_driver`。
4. 逐个运行 `VV/scripts/run_tb_*.sh`，阅读每个 testbench 如何驱动握手。
5. 修改一个无功能影响的参数或 debug counter，观察综合 hierarchy 和报告变化。

### 阶段 B：能修改一个模块

1. 给 AXIS sink/source 增加 directed test：stall、TLAST、underflow、overflow、奇数半 beat。
2. 给 softmax 增加 `-8` 边界和 causal partial tile test。
3. 给 driver 增加 profile JSON，记录 DMA bytes、PL cycles 和 commit hash。
4. 使用 Verilator 做快速模块迭代，再用 VCS 做最终时序/数组语义回归。

### 阶段 C：能做一次时序优化

1. 导出 post-synth/post-route critical path。
2. 判断路径属于 DSP、FP32、reduction、fanout、RAM 或 AXI。
3. 只改变一个流水线边界，并给 `valid/done` 配套增加测试。
4. 比较旧/新 WNS、WHS、逻辑级数、资源和周期数。
5. 只有功能、时序和资源都更好，才保留改动。

### 阶段 D：能做 attention 性能优化

1. 先修 DMA length width、buffer allocation 和 exp semantic mismatch。
2. 对 causal attention 实现 exact KV tile early-exit；用 cycle counter 证明减少了 tile pairs。
3. 参数化 `SOFTMAX_ROW_LANES=1/2`，比较 cycle、LUT、BRAM、WNS 和数值误差。
4. 最后评估 score-buffer overlap、chunked prefill 和 long-context fallback。

## 7. 学习时最容易犯的错误

- 把 `256` 个逻辑 PE 当成 `256` 个实际 DSP；当前 routed design 实际使用 163 DSP。
- 把历史 200 MHz、`MAX_SEQ_LEN=2048` 当成当前签收结果；当前 post-route 基线是 83.333 MHz、`MAX_SEQ_LEN=512`。
- 看到 LUT/BRAM 余量就直接扩大 MAC；关键路径和布线拥塞可能先失败。
- 用 false path/multicycle path 掩盖真实 setup violation。
- 只验证 Python，不验证综合 RTL 的 truncation、同步 RAM latency 和 backpressure。
- 只测 DMA transfer 成功，不核对 bytes、TLAST、cache flush/invalidate 和输出布局。
- 看到论文中的 2x/4x 就直接写进项目结果；必须区分论文结果、分析估计、仿真、post-route 和实板测量。

## 8. 建议的每周学习产出

每周保留一份短记录，包含：

- 本周读过的 1 个官方硬件文档、1 篇论文或 1 个实现。
- 对 LARA 一个具体模块的理解图。
- 一个新增 directed test 或 assertion。
- 一次 timing/utilization 对比。
- 一个没有采用的方案及原因。

这样学习最终会沉淀为可复现的工程证据，而不是只记住“某个优化据说有几倍加速”。
