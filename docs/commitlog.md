# LARA 项目提交记录

## 2026-08-02

### v2.6 P5 preparation — recovery verification, board-matrix hardening, and lint fix

- 重新校验 `checkpoint/v2.5-p4-architecture-dse/pause-round3-impl-interrupted-20260727/`
  的 `PAUSE_MANIFEST.md`、`SHA256SUMS` 和 `checkpoint/attn_soc_wrapper_opt.dcp`，
  以及 `vivado_proj/p4-explore-deploy/SHA256SUMS`；全部文件校验通过。
- 修复 `attn_core` 因果 KV tile 上限组合逻辑的缺省赋值和绝对位置计算位宽警告；
  Verilator lint 在非 fatal warning 模式下完成 elaboration，未再出现 latch/width
  错误。现存 shortreal/unused signal 警告属于既有模型表达和未接出诊断信号。
- 强化 `sw/board_matrix.py`：每个 case 归档输入/期望 NPZ，成功或失败均尽量保存
  实际输出和 profile，并在 `manifest.json` 记录 bitstream SHA-256。
- 修正 `L=512` 与非零绝对 position base 的边界处理：满长 case 明确回退到合法
  `q_pos_base=0/kv_pos_base=0`，短 case 保留非零 base；增加对应单元测试。
- 当前门禁：Python golden `7/7`、`sw/tests` `12/12`、driver mock self-test
  通过；VCS 首次因服务未启动而为 `0/25`，服务恢复后使用 `27000@archlinux`
  完整 behavioral/synthesis/A-B/XPM 回归 `25/25` 全部通过。KV260 尚未接入，
  因此 P5、P6、P7 仍未宣称完成。

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

### v2.5 Phase 0 — 基线冻结与可复现测量

- 新增 `hw/scripts/collect_signoff_metrics.py`，从 Vivado timing/route/utilization/DRC 报告、Git、HWH 和部署文件提取 JSON/CSV 基线；生成内容保存在被忽略的 `vivado_proj/optimization_baseline/`。
- 新增 `python_godel/benchmark_matrix.py`，以固定 seed 覆盖 `L=16/32/64/128/256/512`、causal/non-causal、32 Q heads、8 KV heads 和 GQA 4:1。
- 修正 Python golden model 的 `MAX_SEQ_LEN` 合同漂移：从早期 `2048` 改为当前部署上限 `512`，不改变已有小尺寸结果。
- Phase 0 基线保持 v2.4：WNS `+0.049 ns`、WHS `+0.011 ns`、88065 LUT、57718 FF、50 BRAM、48 URAM、165 DSP，147793/147793 routable nets fully routed，DRC errors `0`。
- Python golden `7/7`、driver unittest `5/5`、benchmark matrix、脚本语法和 `git diff --check` 通过；VCS 仍需可用 Synopsys license server。

## 2026-07-18

### v2.5 Phase 1 — MAC 控制扇出收敛与 clean-build Explore 签核

- 针对 v2.4 critical path 的 MAC 控制扇出，在 `attn_tile.sv` 中将 `split_phase`、
  `accum_en` 和 `clear_accum` 复制到每个 MAC 行的本地寄存器；所有副本同一时钟沿
  更新，不改变 tile、AXI、causal 或 GQA 时序协议。`KEEP` 属性保留局部复制意图，
  Vivado physical synthesis 进一步完成 329 个控制复制单元。
- 物理-only DCP 实验的 Explore route 达到 WNS `+0.103 ns`，但没有改变 netlist，
  因而只作为参考；随后从该 RTL 的 clean build 重新综合、布局、物理优化并从匹配
  `attn_soc_wrapper_physopt.dcp` 恢复 Explore，得到可复现的签核结果。
- 默认 route 按门禁拒绝：WNS `-0.585 ns`、WHS `+0.010 ns`。Explore post-route：
  WNS `+0.062 ns`、WHS `+0.010 ns`、TNS/THS `0`；187523 个 timing endpoints，
  144592/144592 routable nets fully routed，DRC errors `0`。
- 资源：95267 LUT、57838 FF、50 BRAM（34 RAMB36 + 32 RAMB18）、48 URAM、165 DSP。
  相比 v2.4 增加约 7202 LUT 和 120 FF；关键 setup path 已从 MAC split-phase 路径
  转移到 softmax `sm_row_idx -> sm_row_max`，下一阶段应优先处理 softmax 控制/归约，
  不再盲目扩大 MAC 阵列。
- 测试：Python golden `7/7`、driver unittest `5/5`、attn_tile Verilator lint、
  Python compile、shell syntax、`git diff --check` 通过。VCS 定向回归因 Synopsys
  license server 不可连接而未执行，未将 license 错误计为 RTL 失败。
- v2.5 Phase 1 部署产物 SHA-256：
  - `lara_attention.bit`: `3f67775c779ff432d86b47f96a9acd2d014a2c50c334bf28ec9f781e0f8c7248`
  - `lara_attention.hwh`: `9314cb7495468339de887d29d748f22b297af3f609be25d13e2ab7e3d1f2df75`
  - `lara_attention.xsa`: `3ca3e85016d4c9a13005b94fc85167d9d7483e0100efee859225e22f03bef43d`
- bitstream、Vivado 工程、报告和仿真生成物继续由 `.gitignore` 排除；`develop` 保留
  优化 RTL、分析脚本和验证环境，`master` 只同步可部署 RTL、约束、构建/签核脚本及
  版本记录。该结果只证明时序收敛，不代表已完成 KV260 实板吞吐测试。

## 2026-07-21

### v2.5 Phase 2 — Softmax scale/max 流水与 Explore 签核

- 针对 Phase 1 的 softmax `sm_row_idx -> sm_row_max` critical path，将 score scale
  与 row-max update 拆为 issue/commit 两拍；`SM_SCALE_DRAIN` 提交最后一个元素，保持
  每周期处理一个元素，仅每个 16×16 softmax subblock 增加一个 drain 周期。
  `SOFTMAX_SCALE_PIPE=0` 保留 Phase 1 调度作为一键回退路径，接口和 bf16 数值语义不变。
- 同时修正两个历史 testbench 模型：AXIS backpressure 现在 stall 已打包的完整 beat，
  delayed loop-control completion 改为单周期 acknowledgement，避免旧的常高完成电平
  掩盖后续 group/tile 请求。
- 当前 RTL 的 clean build 默认 route 完全布通且 DRC 为 0，但 setup 未通过：WNS
  `-0.818 ns`、WHS `+0.010 ns`、TNS `-566.236 ns`。随后从同轮
  `attn_soc_wrapper_physopt.dcp` 执行 Explore，最终达到 WNS `+0.078 ns`、WHS
  `+0.007 ns`、TNS/THS `0`；188107 个 timing endpoints，144745/144745 routable
  nets fully routed，DRC errors `0`。
- Phase 1 的 scale+max 组合链已被切断；新最差 setup path 为 softmax
  `sm_row_idx -> sm_scale_value_pipe`，18 个逻辑级、11.635 ns data-path delay，其中
  8.096 ns（69.6%）为 routing。它已满足 12 ns 时钟，但余量仍小，不宜继续叠加组合逻辑。
- post-route 资源：96180 LUT、58051 FF、50 BRAM（34 RAMB36 + 32 RAMB18）、48 URAM、
  165 DSP。相比 Phase 1 增加 913 LUT、213 FF，BRAM/URAM/DSP 不变。
- 回归：Python golden `7/7`、driver unittest `5/5`、deterministic benchmark matrix、
  Verilator behavioral/synthesis-path lint、VCS 完整 behavioral+synthesis+XPM `17/17`
  以及 shell syntax、`git diff --check` 全部通过。VCS softmax 为
  `ALL 306 CHECKS PASSED`，E2E、CSR 和 AXI sink smoke 均通过。
- 同轮部署产物和四份签核报告已归档到被忽略的
  `checkpoint/v2.5-softmax-scale-pipe/`。部署产物 SHA-256：
  - `lara_attention.bit`: `06edf0c970c9f3fe61e909da5faeef4def6e4a52d3f28107b5671cd7cce1a7fc`
  - `lara_attention.hwh`: `a479b01b297c1d5382cea6e9395a758ff2e718dd38001b291c64603115023eb8`
  - `lara_attention.xsa`: `7c3cb4ee5a7dccd070a14f83e1f70e967572ef5f93e4be5b7e533eac7b6a6744`
- 本阶段只完成本地仿真和 Vivado 签核；KV260 未连接，零输入、预计算 Q/K/V 数值
  对比和板上 latency/throughput 仍待后续实板验证。

## 2026-07-26

### v2.5 P0 — Causal traversal 与周期基线闭环

- 新增 `tb_attn_core_causal_skip.sv` 及独立 VCS 脚本，并加入正式回归。MAC、softmax
  和 output completion 均为单周期 acknowledgement；Q/KV 使用显式 bank-ready 模型，
  不再用常高完成电平掩盖后续请求。
- L=512 完整 32-head traversal 实测：causal 2304 tile pairs（每 head 72），
  non-causal 4096（每 head 128）。测试逐次检查 Q tile/head/group 切换时首个
  `kv_tile_idx=0`，并覆盖 L=70 partial（128 pairs）和 `q_pos_base=64`（192 pairs）。
- synthesis-path softmax 基线固定为每个 16x16 subblock 1106 cycles：scale/max+drain
  257、max/correction 48、P phase 768、l update+write 33。
- `sw/benchmark.py` 已移除 200 MHz、256 DSP、260 cycles/KV 和 L=1024/2048 等历史
  硬编码。当前只报告 83.333 MHz、165 DSP、MAX_SEQ_LEN=512 的部署合同、解析 tile
  计数和明确标注范围的 softmax 周期上界；在没有完整仿真/板测数据前不再输出伪
  end-to-end latency、throughput 或 GOPS。
- 本阶段未修改综合 RTL/CSR，因此沿用 Phase 2 post-route 签核，不重复运行 Vivado。

### v2.5 P1 — Exact softmax P 流水与默认 route 签核

- 新增默认开启的 `SOFTMAX_P_PIPE=1`，把逐元素 `P_SHIFT -> P_LOOKUP -> P_ACCUM`
  改为 shift、EXP、row-sum/P commit 三段流水；采用逐行 16 次 issue 加 2 拍 drain，
  保持旧路径的逐行、从左到右 FP32 累加顺序。`SOFTMAX_P_PIPE=0` 可一键恢复
  Phase 2 的三状态逐元素调度，不复制 EXP、FP32 adder、DSP 或 softmax lane。
- VCS synthesis-path 实测 P 阶段由 `768` 降至 `288 cycles`，完整 16x16 subblock
  由 `1106` 降至 `626 cycles`，减少 `480 cycles`（43.4%），满足 `<=630` 门限。
  `sw/benchmark.py` 已把 626 设为当前实测模型，同时保留 1106 P0 baseline 对比。
- `tb_softmax` 覆盖 full/partial rows/cols、`x<-8`、state load、非首 KV tile 和 causal
  all-masked；rollback/default 分别导出 m/l/correction/P 原始 bits，A/B 字节级比较通过。
  Python golden `7/7`、driver unittest `5/5`、benchmark matrix、Verilator behavioral 与
  synthesis-path lint、VCS behavioral/synthesis/XPM `19/19` 全部通过；focused synthesis
  softmax 为 `ALL 344 CHECKS PASSED`，A/B 为 `ALL SOFTMAX A/B BIT-EXACT CHECKS PASSED`。
- matching clean Vivado build 的默认 route 直接通过，无需 Explore：WNS `+0.003 ns`、
  TNS `0`、WHS `0.000 ns`、THS `0`，188074 个 timing endpoints，144612/144612
  routable nets fully routed，DRC errors `0`。最差 setup 为 MAC clear-accumulator replica
  到 output-buffer accumulator，31 个逻辑级、11.895 ns data delay，其中 routing
  7.709 ns（64.8%）；不再是新增 P pipeline 路径。
- post-route 资源为 95077 LUT、57956 FF、50 BRAM（34 RAMB36 + 32 RAMB18）、48 URAM、
  165 DSP。相对 Phase 2 分别减少 1103 LUT、95 FF，BRAM/URAM/DSP 不变，满足资源门限。
- bit/HWH/XSA 与四份签核报告已归档到被忽略的
  `checkpoint/v2.5-softmax-p-pipe/`。部署产物 SHA-256：
  - `lara_attention.bit`: `9eba4c051daa62dadb942771b4313a1220f9ff1aa4d5c95b6add2727aa72ab1e`
  - `lara_attention.hwh`: `f56fc11b3d231c6391a918accb2c4025311c052823cf054c14a8a5415e2808b0`
  - `lara_attention.xsa`: `c302ed7f97f44701dc0438ce2d17dc696f315fad02b975bec0aac2327f0d9fc6`
- 当前没有连接 KV260；本阶段结论仅覆盖仿真和 matching post-route 签核，不声称板上
  latency 或 throughput。

## 2026-07-27

### v2.5 P2 — Phase-A MAC/softmax overlap 与默认 route 签核

- 新增默认开启的 `PHASEA_SOFTMAX_OVERLAP=1`，把 MAC issue、`s_block` held block 和
  softmax retire 分成独立 tag/valid 所有权。`softmax_engine` 通过真实 `s_ready` 接收
  block；`s_valid` 在 `PA_LAUNCH` 保持到握手，backpressure 期间 score、microtile、
  KV block、active rows/cols 和 position context 均保持稳定。没有增加 score ping-pong RAM。
- `PA_LOAD_CTX` 与 `PA_LAUNCH` 分拍，避免 softmax 在 nonblocking assignment 同一边沿
  采到旧 m/l context；softmax first tag 收窄为
  `kv_tile_first && held_kv_block==0`，修复 64-column KV tile 内 subblock 1–3 被重复初始化的
  问题。`LARA_PHASEA_SOFTMAX_OVERLAP_ROLLBACK` 一键恢复串行调度，同时保留上述协议修复。
- focused synthesis-path A/B 覆盖连续 8 blocks、两个 Q microtiles、后续 partial KV tile、
  causal/all-masked 和确定性 1–4 cycle backpressure。完整 Phase-A 由 `7109` 降至
  `5310 cycles`，减少 `1799 cycles`（`25.31%`）；partial/all-masked 为
  `1777 -> 1520 cycles`。rollback/default 的 P、m、l、correction 原始 bits 完全一致，
  launch/retire 数量与顺序无丢块、重复或 tag 错位。
- 完整门禁：Python golden `7/7`、driver unittest `5/5`、deterministic benchmark matrix、
  Verilator behavioral/synthesis lint，以及 VCS behavioral/synthesis/A-B/XPM `20/20` 全部通过。
- matching clean Vivado build 的默认 route 直接通过，无需 Explore。router 中间 setup 一度为
  WNS `-0.251 ns`，同轮 post-route physical synthesis 最终收敛到 WNS `+0.001 ns`、
  TNS `0`、WHS `+0.010 ns`、THS `0`；184857 个 timing endpoints，144472/144472
  routable nets fully routed，routing errors `0`，DRC errors `0`。
- post-route 资源为 95356 LUT、56938 FF、50 BRAM（34 RAMB36 + 32 RAMB18）、48 URAM、
  165 DSP。相对 P1 为 `+279 LUT / -1018 FF`，BRAM/URAM/DSP 不变；softmax hierarchy 为
  10086 LUT、23000 FF、3 DSP，作为 P3 scratch/P-store 复用的量化基线。
- 最差 setup path 从 MAC `clear_accum_row_r` replica 到 output-buffer accumulator，data path
  11.590 ns，其中 logic 4.033 ns、route 7.557 ns（65.2%），不是新增 overlap 控制路径。
- bit/HWH/XSA、post-synth/post-route 报告、同轮 physopt/routed DCP 和实现日志已归档到
  被忽略的 `checkpoint/v2.5-phasea-softmax-overlap/`，`SHA256SUMS` 已逐项校验。部署产物
  SHA-256：
  - `lara_attention.bit`: `3f82daef4497041db788df1b86bb4c0c2a3430847897c0c1dd5f7f4c6ebcc7b3`
  - `lara_attention.hwh`: `58169f488fb5e4268d2e6c4e20f335ce6b15891800bf815b6d48d546438053b5`
  - `lara_attention.xsa`: `dd62730da7c8e4cc02c1b65d6e1fa393de807ae595f19ebb814856341c9bd6d8`
- 当前没有连接 KV260；P2 已完成软件、仿真和 matching implementation 闭环，但不声称板上
  latency 或 throughput。

### v2.5 P3 — softmax scratch/P-store 复用 DSE 结论

- 保留 `LARA_SOFTMAX_P_INPLACE_ENABLE`、`LARA_SOFTMAX_P_OUTPUT_DIRECT_ENABLE` 和
  `LARA_SOFTMAX_SCORE_INPLACE_ENABLE` 三个独立候选开关；默认值恢复为
  `SOFTMAX_P_INPLACE=0`、`SOFTMAX_P_OUTPUT_DIRECT=0`，即已签核的 P2 存储组织。
- Step 1（P 原址复用、保留注册输出）完成 clean synthesis，但 `u_softmax` 为
  `11751 LUT / 25182 FF / 3 DSP`，高于 P2 约 `23004 FF` 基线；top 为
  `102415 LUT / 60156 FF`。综合 setup WNS `+1.261 ns`、hold WHS `-0.090 ns`。
  该变体资源变差，拒绝进入 route。
- Step 2（P 原址复用 + direct output）功能和周期保持 bit-exact、626 cycles，
  但 softmax 仅为 `11545 LUT / 20922 FF`，FF 降幅约 `9.1%`，未达到 P3 的
  `20%` 目标；post-route WNS `-1.245 ns`、TNS `-882.633 ns`，因此拒绝。
- Step 3（score scratch 原址复用）softmax 为约 `15370 LUT / 12812 FF`，
  post-route Explore 为 WNS `-0.121 ns`、TNS `-8.624 ns`、WHS `+0.008 ns`，
  133654/133654 nets fully routed、DRC errors `0`，但 CLB 使用率达到 `99.17%`，
  拒绝。
- 三个候选均通过 focused P3 A/B、Python、Verilator 和完整 VCS `25/25`；
  没有候选同时满足资源目标和 post-route 时序门禁。P3 默认保留 P2，证据归档在
  `checkpoint/v2.5-p3-softmax-scratch-dse/`，其中 Step 1 的
  `SHA256SUMS` 已校验。

### v2.5 P4 — streaming/fused PV 接受

- candidate 1 使用 `LARA_STREAMING_PV_ENABLE` 完成功能、周期和资源筛选；32x32
  主循环 `4345 -> 3209` cycles，32x64 主循环 `8429 -> 5809` cycles，降低
  `31.08%`，partial 输出 A/B bit-exact。
- Python golden `7/7`、Python unittest/P4 model `9/9`、deterministic matrix
  `12/12`、Verilator behavioral/default-synthesis/streaming-synthesis、VCS
  behavioral/synthesis/A-B/XPM `25/25` 全部通过。
- matching clean post-synthesis 为 100148 LUT、57441 FF、50 BRAM、48 URAM、
  165 DSP。默认 route fully routed 但 WNS `-0.110 ns`、TNS `-4.889 ns`；
  同一轮 physopt checkpoint 的 Explore route 达到 WNS `+0.021 ns`、TNS `0`、
  WHS `+0.010 ns`、THS `0`，144158/144158 routable nets fully routed，
  routing errors `0`，DRC Error severity `0`。
- Explore post-route 资源为 95479 LUT、56940 FF、50 BRAM、48 URAM、165 DSP；
  最差 setup path 为 MAC product register 到 output-buffer read data，11.804 ns
  data delay，其中 logic 3.971 ns、route 7.833 ns。该候选满足 P4 接受门禁，
  已设为默认；`LARA_STREAMING_PV_ROLLBACK` 恢复 P2 调度。
- 结果、DCP、报告和校验和归档在
  `checkpoint/v2.5-p4-architecture-dse/candidate1-streaming-pv/`。本轮只产生
  routed DCP，没有从该 screening run 声称 bit/HWH/XSA；KV260 仍未连接。
