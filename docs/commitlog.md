# LARA 项目提交记录

## 2026-07-07

### v1.0 — 框架构建、比赛思路与技术文档完成

- 完成 FPT'26 Track B 赛题目标、Llama3-8B attention 加速方案和 KV260 部署边界定义。
- 完成 `master` / `develop` 分支架构设计：部署源码与开发验证环境分离。
- 完成 Python Golden Model -> Verilator/VCS -> Vivado/KV260 三层验证流程设计。
- 完成架构图、数据流图、代码组织说明、MAC 阵列分析和 Track B roadmap 等技术文档。
- 建立 `hw/rtl`、`VV`、`python_godel`、`sw` 等项目目录结构。

## 2026-07-13

### v2.1 — 资源收敛与 60 MHz 时序收敛

- 通过 MAC `split=2` 共享物理 MAC/adder，完成 LUT 资源收敛。
- 将 `P_store` 改为 distributed RAM，降低 BRAM 使用量。
- 将 softmax 综合路径拆分为多级 FSM，消除原先约 32.9 ns 的长路径。
- 为 MAC 乘积和控制信号增加寄存级，切断乘法到累加器的关键路径。
- 最终资源：96477 LUT、59096 FF、50 BRAM、48 URAM、195 DSP。
- KV260 60 MHz post-route：WNS `+0.335 ns`、TNS `0`、WHS `+0.010 ns`、THS `0`。
- route status：156085/156085 nets fully routed，0 routing errors，0 DRC errors。
- Python 7/7、VCS 17/17、Verilator lint 通过。
- 生成 bitstream、HWH 和 XSA 部署文件（产物由 `.gitignore` 排除）。

## 2026-07-09

### v2.0 — attn_core FSM 升级 + 设计对齐

**attn_core.sv v2.0** — 采纳同学 design_attn_core_fsm.md 方案中的关键设计：
- 新增 cfg_q_pos_base / cfg_kv_pos_base 绝对位置基准
- 新增 cfg_causal 可配置端口、start_ready valid/ready 握手
- 新增 q_tile_start / kv_tile_start 输出 (给 softmax_engine 做 causal masking)
- 新增 active_q_rows / active_kv_cols (partial last tile 支持)
- 新增 ST_ERROR + 配置校验 (seq_len=0, 越界检测)
- done/error 改为 sticky level
- 保留全量 K/V URAM 预加载 (ST_LOAD_KV)
- 保留 MAC 分时复用 Phase A/B (ST_QK_DOT + ST_AV_DOT)

**文档**：
- 新增 docs/review/attn_core_fsm_alignment.md — 同学文档审阅 + 对齐意见
- 记录 K/V 预加载机制、v2.0 端口列表、ST_ERROR 规则、Partial tile、Causal 位置

**回归**：全部 503+ tests PASS，全模块 VCS 0 errors

---

## 2026-07-08

### feat: complete attention accelerator RTL framework (14 modules)

**核心计算**：
- bf16_mac.sv — 原子 bf16 MAC PE (103/103 PASS)
- attn_tile.sv — 16×16 MAC 阵列，2级流水线≥200MHz (64/64 PASS)
- softmax_engine.sv — Online Softmax + Causal Masking (304/304 PASS)
- psum_accum.sv — 列累加器，SPLIT=2 (32/32 PASS)
- attn_core.sv — FlashAttention 双层循环 FSM + GQA
- rope_engine.sv — RoPE 1024 sin/cos LUT + 线性插值

**存储**：
- kv_cache_ram.sv — K/V URAM 缓存 (TILE_KV 并行读)
- tile_buffer.sv — Q Ping-Pong 双缓冲
- output_buffer.sv — O_acc correction: O_new = O_old × correction + ΔO

**AXI**：
- attn_axi_lite_slave.sv — 14位 CSR 地址空间
- attn_axi_stream_sink.sv — 3目标路由，溢出/不足检测 (8/8 PASS)
- attn_axi_stream_source.sv — 5状态 FSM，2:1 打包

**顶层**：attn_top.sv — generate-based MUX，深度迭代控制

**扩展** (未来参考)：qkv_projection.sv, rms_norm.sv

**软件**：host_attention.py (QKV+RMSNorm+RoPE), attn_driver.py (PYNQ)

**验证**：14 testbenches, VCS 0 errors, Verilator lint clean

---

### 项目初始化

- 分支架构：master (部署源码) / develop (开发+验证)
- 三层验证：Python Golden → VCS/Verilator → KV260
- 目录结构建立：hw/rtl/{pkg,core,mem,axi}, VV/{tb,scripts,data}, sw/, python_godel/
- 参数包 attn_pkg.sv — 全局单一真相源
- Golden Model attention_golden.py — bf16 位精确参考
