# LARA 项目提交记录

## 2026-07-07

### v1.0 — 框架构建、比赛思路与技术文档完成

- 完成 FPT'26 Track B 赛题目标、Llama3-8B attention 加速方案和 KV260 部署边界定义。
- 完成 `master` / `develop` 分支架构设计：部署源码与开发验证环境分离。
- 完成 Python Golden Model -> Verilator/VCS -> Vivado/KV260 三层验证流程设计。
- 完成架构图、数据流图、代码组织说明、MAC 阵列分析和 Track B roadmap 等技术文档。
- 建立 `hw/rtl`、`VV`、`python_godel`、`sw` 等项目目录结构。

## 2026-07-08

### feat: complete attention accelerator RTL framework (14 modules)

**核心计算**：

- bf16_mac.sv — 原子 bf16 MAC PE (103/103 PASS)
- attn_tile.sv — 16×16 逻辑 MAC 阵列，模块级 2 级流水线回归通过（“≥200 MHz”为当时目标，非 post-route 结论）
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

## 2026-07-09

### v2.0 — attn_core FSM 升级 + 设计对齐

**attn_core.sv v2.0** — 采纳同学 design_attn_core_fsm.md 方案中的关键设计：

- 新增 cfg_q_pos_base / cfg_kv_pos_base 绝对位置基准
- 新增 cfg_causal 可配置端口、start_ready valid/ready 握手
- 新增 q_tile_start / kv_tile_start 输出 (给 softmax_engine 做 causal masking)
- 新增 active_q_rows / active_kv_cols (partial last tile 支持)
- 新增 ST_ERROR + 配置校验 (seq_len=0, 越界检测)
- done/error 改为 sticky level
- 当时保留全量 K/V URAM 预加载 (ST_LOAD_KV；该行为已由后续请求驱动控制链替换)
- 保留 MAC 分时复用 Phase A/B (ST_QK_DOT + ST_AV_DOT)

**文档**：

- 新增 docs/review/attn_core_fsm_alignment.md — 同学文档审阅 + 对齐意见
- 记录 K/V 预加载机制、v2.0 端口列表、ST_ERROR 规则、Partial tile、Causal 位置

**回归**：全部 503+ tests PASS，全模块 VCS 0 errors

---

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

## 2026-07-15

### v2.2 — 83.333 MHz 时序收敛

- K26 PL0 无法精确生成 80 MHz，采用下一档可实现时钟 `83.333 MHz / 12.000 ns`，以证明设计满足不低于 80 MHz 的目标。
- 将 output buffer 的 `old * correction + delta` 从单周期 FMA 拆分为乘法、加法两级流水，消除 accumulator forwarding 长组合路径。
- 为 output buffer 增加 `acc_ready` 和同地址 RAW hazard 控制；顶层 `PB_UPDATE` 在未握手时保持行地址和数据。
- 增加 `PB_CAPTURE` 状态，让最终 MAC split 先提交到寄存器，再进入 output buffer 更新阶段。
- 归一化首读等待目标 bank 的累加流水排空，之后仍允许另一 ping-pong bank 并行累加，保留计算/写回重叠。
- 使用 `route_design -directive Explore` 完成最终物理收敛；默认布线结果仅差 `-0.007 ns`，Explore 最终达到 WNS `+0.040 ns`、TNS `0`、WHS `+0.010 ns`、THS `0`。
- route status：146248/146248 routable nets fully routed，0 routing errors；post-route DRC 0 errors。
- 最终资源：87235 LUT、57306 FF、50 BRAM、48 URAM、163 DSP。
- Python Golden 7/7、VCS 17/17、Verilator lint、XPM output buffer 和 full traversal 测试通过。
- 新增 `vivado_resume_route.tcl` 和恢复流程文档；成功 `.bit/.hwh/.xsa` 已归档到 `checkpoint/v2.2`。
- v2.2 部署产物 SHA-256：
  - `lara_attention.bit`: `1a786f7354dc543016ad6a4e616437ffbb39b6bc2a901d993772e1c935a51166`
  - `lara_attention.hwh`: `84635314da0d3d58370dbc042c7ec77a393fa9673db4bd7993526d8bb98bc448`
  - `lara_attention.xsa`: `5f525b1badfcd73315f105cfa2cea5901a146bd2348121452ef6680aed305151`
- 上述部署产物按仓库策略由 `.gitignore` 排除，不提交至 Git；`develop` 追踪 RTL、仿真测试、Vivado 脚本和开发文档，`master` 仅同步部署所需 RTL、构建配置及版本记录。

> 当前工作区后续控制链已将 v2.0 的“全量 K/V 预加载”替换为 `CSR_LOAD_REQ` 请求驱动：片上只驻留当前 GQA group 的一个 K/V head，host driver 在一次 `start` 后显式服务 K/V/Q DMA。v2.0 条目中的预加载描述仅保留为历史记录，不代表当前 RTL。

## 2026-07-15

### v2.3 — 宿主 QKV 投影与 FPGA Attention 控制链整合

- 选择性吸收 `fsm-driver-work` 的软硬件协同思路，不合并其与当前 KV cache 容量不匹配的旧 RTL 树。
- `attn_core`/`attn_top` 采用一次 `start` 覆盖完整 group/head/tile 遍历；通过 `CSR_LOAD_REQ` 请求当前 KV head 和 Q tile，由 host driver 显式启动 AXI DMA。
- `run_layer()` 串起宿主机 RMSNorm、QKV projection、RoPE、head-major bf16 packing、FPGA Attention 和输出恢复。
- 修复 AXI-Lite 独立 AW/W 锁存、W1P start、sticky request/status/error，以及 AXI-Stream transfer 边界、连续事务和 pending beat 覆盖问题。
- 新增 KV260 board bundle、零输入 smoke test、NPZ 预计算 Q/K/V 检查和上板验证指南。
- 已验证：Python Golden 7/7、Python unittest 3/3、host helper、CSR/sink smoke、AXI Stream 8/8、Verilator lint；完整 VCS 回归需在可用的 Synopsys license server 上重新执行。
- 默认 route 结果为 WNS `-0.233 ns`，随后从 `physopt.dcp` 使用 `route_design -directive Explore` 完成物理收敛。
- v2.3 post-route（83.333 MHz / 12.000 ns）：WNS `+0.021 ns`、TNS `0`、WHS `+0.011 ns`、THS `0`；146331/146331 routable nets fully routed，0 routing errors，0 DRC errors。
- 最终资源：87372 LUT、57219 FF、50 BRAM、48 URAM、163 DSP；关键资源由 `vivado_proj/reports/post_route_utilization.rpt` 固定记录。
- 生成并校验 `vivado_proj/deploy/{lara_attention.bit,lara_attention.hwh,lara_attention.xsa}`，同步归档到 `checkpoint/v2.3`；board bundle 另含 post-route timing/route/utilization/DRC 报告。
- v2.3 部署产物 SHA-256：bit `b720f04cb928b6b3d60805fb39f8c3a3f9727e704d4796017da42ff0dad67547`，hwh `e54091fbbd342cf8769f2def1b3146c6380896d37e2d8c692f57d60ad450330a`，xsa `7444bc69a0f69c8c7c6f9c42e96a1449a07883d4813c43789552a7cf9cf926ed`。
- 上述部署产物与 Vivado 工程仍由 `.gitignore` 排除；`develop` 追踪控制软件、仿真和板测工具，`master` 追踪可独立构建的 RTL、约束、脚本及版本记录。

## 2026-07-17

### v2.4 — 控制链回归、语义修正与 Explore 物理收敛

- 统一 RTL、Python golden model 和 softmax testbench 的边界语义：`x < -8 -> 0`、`-8 <= x <= 0 -> EXP LUT`、`x > 0 -> 1`。
- 为 `AXI DMA` 固定 `C_SG_LENGTH_WIDTH=26`，覆盖 `L=512` 最大输出传输；driver 增加可复用 DMA buffer、request-service profiling、bitstream SHA-256 和 git 元数据。
- 完成 causal KV tile 上界 early-exit，并修复 Q tile/head/group 切换时 `kv_tile_idx` 未复位的问题；回归覆盖 `L=512` 的 tile traversal。
- 新增 FPGA attention 学习路径文档，并修正调研资料中 Softermax（DAC 2021）、PD-Swap（2025）和 SWAT（sparse sliding-window attention）的过时描述。
- 新一轮完整 Vivado 默认 route 得到 WNS `-0.671 ns`，按门禁阻止 bitstream；随后从同一轮 `attn_soc_wrapper_physopt.dcp` 使用 `route_design -directive Explore` 恢复布线。
- v2.4 post-route（83.333 MHz / 12.000 ns）：WNS `+0.049 ns`、TNS `0`、WHS `+0.011 ns`、THS `0`；147793/147793 routable nets fully routed，0 routing errors，0 DRC errors。
- 最终资源：88065 LUT、57718 FF、50 BRAM（34 RAMB36 + 32 RAMB18）、48 URAM、165 DSP；HWH 已核验 `C_SG_LENGTH_WIDTH=26`。
- Python golden 7/7、driver unittest 5/5、`git diff --check` 通过；完整 VCS 回归仍需在可用 Synopsys license server 上执行，两个历史 backpressure testbench 失败已确认可在 clean baseline 重现。
- 成功部署文件归档到 `checkpoint/v2.4`，并生成 `vivado_proj/board_bundle`。SHA-256：
  - `lara_attention.bit`: `726554e2b44315b7e8cc57234c0b08b7c010354b2debca8e14c5069149625b70`
  - `lara_attention.hwh`: `51f56e1d2e32af2ad2decd890e6b6467448d49db8a8f415c2fdbee2ac7917540`
  - `lara_attention.xsa`: `9ed9fa0b5c37c8712377fe15c8fa456628dcc76149db8372766596cd27ff3520`
- `.bit/.hwh/.xsa`、Vivado 工程和仿真生成物继续由 `.gitignore` 排除；`develop` 保留控制软件、仿真和板测工具，`master` 只同步上板 RTL、构建脚本、约束和版本文档。
