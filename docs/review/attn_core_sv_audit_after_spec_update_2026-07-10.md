# 审核记录：attn_core.sv 代码结果（spec 更新后修订版）

> 用途：根据 2026-07-10 重新调整后的 `docs/spec/*.md`，修订 `D:/projects/LARA/hw/rtl/core/attn_core.sv` 审核结论。新版 spec 已正式接纳 handover 路线，因此本报告不再把 pulse handshake、单 `seq_len`、全 32 Q heads 遍历、`ST_LOAD_KV` 和 `ST_SOFTMAX + ST_AV_DOT` 分离本身列为阻塞问题；审核重点转为：现有 RTL 是否满足新版 pulse/full-preload/single-seq 规格。

## 1. 审核基本信息

| 项目 | 内容 |
| --- | --- |
| 审核对象名称 | `attn_core.sv` |
| 审核对象类型 | 代码结果 |
| 审核对象路径 | `D:/projects/LARA/hw/rtl/core/attn_core.sv` |
| 关联模块 | `attn_core` / `attn_core_fsm` / `attn_top` 局部集成 |
| 规格基线 | `D:/projects/competition/docs/spec/interfaces.md`、`architecture.md`、`model.md`、`verification.md`，更新时间 2026-07-10 |
| 前序报告 | `D:/projects/competition/docs/review/attn_core_sv_audit_after_handover_2026-07-09.md` |
| 审核人 | Codex |
| 审核日期 | 2026-07-10 |
| 审核结论 | FAIL |
| 可执行确认 | 不可执行：路线已被 spec 接纳，但现有 RTL/顶层连接仍未满足新版 spec 的 P0 准出条件 |

## 2. 新版 spec 对审核结论的影响

已关闭或降级的旧问题：

| 旧问题 | 新版 spec 处理 | 本次结论 |
| --- | --- | --- |
| 缺 `cmd_valid/cmd_ready` downstream channel | `interfaces.md` 已改为 handover pulse `*_start/*_done` 协议 | 不再作为问题 |
| 缺 `cfg_seq_q/cfg_seq_kv` | Phase 1 只支持 prefill `S_q=S_kv=seq_len` | 不再作为问题 |
| 缺 `cfg_q_head_base/count` | Phase 1 默认遍历全 32 Q heads | 不再作为问题 |
| 缺 `soft_reset` | Phase 1 不要求 `soft_reset`，中断由 `rst_n` 或后续 wrapper 定义 | 不再作为问题 |
| `ST_LOAD_KV` 全量预加载 | 正式接纳 per-GQA-group / per-KV-head full preload | 不再作为问题，仍需资源证据 |
| `ST_SOFTMAX + ST_AV_DOT` 分离 | 正式接纳 MAC 复用下的分离状态 | 不再作为问题，但 AV 启动和 online correction 必须闭合 |
| `ST_DONE/ST_ERROR` 自动回 IDLE | 新版 spec 允许自动回 IDLE | 不再单独作为问题；但 status/counter 必须 sticky |

仍然阻塞的问题：新版 spec 明确写入 `mac_start/mac_done`、`active_q_rows`、`o_write_done`、连续 start 清计数、`cfg_causal` 传播、row-subtile 和 VCS 证据要求。这些与上一版审核结论一致，且现在已经成为正式规格准出项。

## 3. 审核依据

| 依据类型 | 路径 | 用途 | 是否已检查 |
| --- | --- | --- | --- |
| 接口规格 | `D:/projects/competition/docs/spec/interfaces.md` | pulse 协议、端口、payload、FSM、row-subtile | 是 |
| 架构规格 | `D:/projects/competition/docs/spec/architecture.md` | handover 路线裁决、未闭合阻塞项、资源口径 | 是 |
| 模型规格 | `D:/projects/competition/docs/spec/model.md` | prefill-only、GQA、causal、online softmax/AV 数学 | 是 |
| 验证规格 | `D:/projects/competition/docs/spec/verification.md` | 必测场景、误差门槛、证据要求 | 是 |
| RTL 控制 | `D:/projects/LARA/hw/rtl/core/attn_core.sv` | 被审实现 | 是 |
| 顶层连接 | `D:/projects/LARA/hw/rtl/attn_top.v` | 检查 pulse 与 wrapper 是否闭合 | 是 |
| 参数包 | `D:/projects/LARA/hw/rtl/pkg/attn_pkg.sv` | 参数、tile/head/cache 约束 | 是 |
| 本地前端检查 | `iverilog -g2012 -tnull ...` | 语法/工具兼容性参考 | 是 |

## 4. 功能性审核

| 检查项 | 结论 | 证据/说明 | 问题等级 |
| --- | --- | --- | --- |
| 是否符合新版 Phase 1 路线 | CONDITIONAL | FSM 形态包含 `ST_LOAD_KV -> ST_Q_INIT -> ST_KV_READ -> ST_QK_DOT -> ST_SOFTMAX -> ST_AV_DOT -> ST_NORMALIZE -> ST_WRITE_O`，与新版 spec 主线大体一致。 | NA |
| Pulse command 协议是否满足 | FAIL | 新版 spec 要求 `*_start` 为单周期 command pulse；代码中 `kv_load_start/q_load_start/o_write_start/softmax_start` 都在等待 done 前保持为 1，不是单周期 pulse。 | P0 |
| MAC QK/AV 闭环是否满足 | FAIL | `mac_start` 只在 `ST_KV_READ` 拉高；`ST_AV_DOT` 仅置 `mac_phase=1`，没有新的 `mac_start`。`attn_top.v` 又把 `mac_start` 当 level enable 使用，`depth_cnt` 在 `mac_start=0` 时清零。 | P0 |
| Writeback/normalize 闭环是否满足 | FAIL | `attn_top.v` 中 `o_write_done` 常绑 0；`output_buffer` 多周期输出未形成完成信号，core 无法可靠进入 done。 | P0 |
| Position/causal 配置是否生效 | FAIL | `cfg_causal` 在 core 内锁存为 `causal_r`，但没有传给 softmax；顶层将 `causal_mask_en` 硬绑 1。新版 spec 明确要求 `cfg_causal` 必须进入 softmax/mask。 | P1 |
| Full-head prefill baseline 是否可验证 | FAIL | handover 声称 VCS 503 tests，但未提供日志、seed、test list、report 或 `runs/` 路径；不满足新版 verification 证据要求。 | P1 |

功能性结论：

```text
FAIL：规格路线已经对齐 handover，但当前 RTL 仍没有满足新版 pulse command、MAC/AV、writeback、causal 和证据链要求。
```

## 5. 逻辑正确性审核

| 检查项 | 结论 | 证据/说明 | 问题等级 |
| --- | --- | --- | --- |
| 控制流/FSM 是否正确 | FAIL | accepted start 只锁存配置和清 `done/error`，没有清 `q_tile_idx/kv_tile_idx/head_cnt/group_cnt` 和 performance counters。新版 spec 明确要求 accepted start 清所有事务计数器。 | P0 |
| active row/col 边界是否正确 | FAIL | `active_q_rows` 为 5 bit；`TILE_Q=32` 时 `TILE_Q[4:0] == 0`，完整 Q tile 会输出 0。新版 spec 明确要求 `ACTIVE_Q_W = clog2(TILE_Q + 1)`。 | P0 |
| `TILE_Q` 与 `TILE_ROWS` 关系是否闭合 | FAIL | `attn_pkg.sv` 中 `TILE_Q=32`、`TILE_ROWS=16`；当前 `attn_core` 没有 row-subtile counter，也没有 `active_row_lanes` 语义。新版 spec 要求若 `TILE_ROWS<TILE_Q` 必须显式 row-subtile 调度。 | P1 |
| Position 合法性检查是否安全 | FAIL | `cfg_q_pos_base + seq_len`、`cfg_kv_pos_base + seq_len` 使用 16-bit 加法后比较，可能 wrap；新版 spec 要求足宽中间量。 | P1 |
| sticky status/counter 是否满足 | FAIL | `done/error` 在自动回 IDLE 后可保持，但 `cycle_cnt` 在 `state == ST_IDLE` 时清零，无法按新版 spec 保持 last transaction 计数到下一次 accepted start。`mac_cycles` 也未在 accepted start 清零。 | P1 |
| Online softmax / AV 数学闭环是否可确认 | FAIL | `softmax_engine` 输出 `correction` 和 `p_data`，但顶层 `ST_AV_DOT` 启动、O_acc row/dim 调度、normalize done 都未闭合；无法证明满足 `O_acc_new = alpha*O_old + sum(beta*V)`。 | P1 |

逻辑正确性结论：

```text
FAIL：新版 spec 已经允许当前 FSM 大方向，但实现细节仍存在确定性 P0/P1，尤其是 pulse 语义、AV 启动、active rows、连续事务计数和 row-subtile。
```

## 6. 一致性审核

| 检查项 | 结论 | 证据/说明 | 问题等级 |
| --- | --- | --- | --- |
| 是否符合 agent 审核模板 | PASS | 本报告按 `agents/templates/audit.md` 的功能性、逻辑正确性、一致性、问题列表、准出条件组织。 | NA |
| 接口是否与新版 `interfaces.md` 一致 | FAIL | 端口集合大体接近新版 handover 路线，但 `*_start` 不是单周期 pulse，缺 `cfg_causal_latched` 传播，缺 row-subtile payload/调度，`o_write_done` 无真实来源。 | P0/P1 |
| shape/scope 是否与新版 `model.md` 一致 | CONDITIONAL | 单 `seq_len`、prefill-only、全 32 heads 不再冲突；但 full-head/GQA 遍历需要连续事务和 counters 正确才能证明。 | P1 |
| 架构是否与新版 `architecture.md` 一致 | FAIL | 新版架构已把旧审核阻塞项写为正式要求；当前代码仍未关闭这些阻塞项。 | P0/P1 |
| 验证是否与新版 `verification.md` 一致 | FAIL | 缺可追溯 tests/logs；未覆盖 `seq_len_32_full_tile`、`causal_toggle`、`mac_pulse_latch_av`、`o_write_done_closure` 等必测项。 | P1 |
| 路径/落地位置是否一致 | CONDITIONAL | 被审代码位于 `D:/projects/LARA/hw/rtl/`，新版 spec 说明该目录只是 handover 来源；正式吸收应迁移或镜像到 `src/rtl/`。 | P2 |

一致性结论：

```text
FAIL：规格冲突已经从“路线不一致”收敛为“实现未满足新版路线”。当前代码可作为 handover 路线参考实现，但不能作为 spec-compliant RTL 签收。
```

## 7. 问题列表

| 编号 | 等级 | 类型 | 位置 | 问题描述 | 建议修改 | 负责人 | 状态 |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | P0 | 协议/功能性 | `attn_core.sv:240-274`; `interfaces.md` §4/§6/§7 | 新版 spec 要求 `*_start` 是单周期 command pulse；当前 `kv_load_start/q_load_start/o_write_start/softmax_start` 在等待 done 前保持为 1，可能被接收方重复锁存为多条命令。 | 为每个下游事务实现“进入状态打一拍 pulse，然后等待 done”的控制；或在 wrapper 明确 edge-detect，但 core 仍建议输出真正 pulse。 | RTL | open |
| 2 | P0 | MAC/集成 | `attn_core.sv:254-270`; `attn_top.v:27-31`; `attn_top.v:65`; `attn_top.v:70` | `mac_start` 不符合新版 pulse contract：QK 只可能借 `ST_KV_READ` 触发，AV 阶段没有 start pulse；顶层还把 `mac_start` 当 depth enable，导致计数清零。 | 增加 QK/AV 两类明确 `mac_start` pulse；MAC wrapper 锁存 `mac_phase` 和 payload，自行跑完整 `HEAD_DIM` 后产生 `mac_done`。 | RTL + 顶层 | open |
| 3 | P0 | 边界/位宽 | `attn_core.sv:51`; `attn_core.sv:76`; `attn_core.sv:85-87`; `attn_pkg.sv:115`; `interfaces.md` §2/§8 | `active_q_rows` 5 bit 无法表示 `TILE_Q=32`，完整 tile 输出 0，直接破坏 `seq_len_32_full_tile`。 | 使用 `ACTIVE_Q_W = clog2_safe(TILE_Q+1)`；足宽计算 `seq_len - q_tile_idx*TILE_Q`。 | RTL | open |
| 4 | P0 | 连续事务/FSM | `attn_core.sv:151-158`; `attn_core.sv:176-188`; `interfaces.md` §5 | accepted start 未清 `q_tile_idx/kv_tile_idx/head_cnt/group_cnt/perf counters`；连续 start 可能继承上一轮状态。 | 在 `start && start_ready` 同拍清所有 loop counters、row-subtile counter 和性能计数。 | RTL | open |
| 5 | P0 | writeback 闭环 | `attn_top.v:66`; `attn_core.sv:225-230`; `interfaces.md` §6 | `o_write_done` 常绑 0，`ST_WRITE_O` 无法完成；新版 spec 明确不能常绑 0。 | 将 output buffer/stream/writer 的真实完成信号接入 `o_write_done`；定义 normalize + writeback 的完整事务边界。 | 顶层 + mem | open |
| 6 | P1 | causal 配置 | `attn_core.sv:27`; `attn_core.sv:72`; `attn_core.sv:155`; `attn_top.v:78`; `attn_top.v:83`; `model.md` Online Softmax 约束 | `cfg_causal` 锁存后未传播；top 硬绑 causal=1，无法通过 `causal_toggle`。 | 输出 `cfg_causal_latched` 或随 softmax payload 传递；顶层禁止硬绑。 | RTL + 顶层 | open |
| 7 | P1 | row-subtile | `attn_pkg.sv:37`; `attn_pkg.sv:115`; `attn_core.sv:64-91`; `interfaces.md` §8 | `TILE_Q=32` 与 `TILE_ROWS=16` 时必须有 row-subtile 调度；当前没有 `row_subtile_idx/active_row_lanes`。 | 增加 row-subtile loop，或统一 `TILE_ROWS=TILE_Q` 并同步资源/验证。 | 架构 + RTL | open |
| 8 | P1 | position 检查 | `attn_core.sv:107-113`; `interfaces.md` §5 | 16-bit 加法后比较可能 wrap；`seq_len==0` 重复检查。 | 使用 `SEQ_POS_W+1` 或 17-bit 中间量；清理重复条件。 | RTL | open |
| 9 | P1 | status/counter | `attn_core.sv:119-128`; `attn_core.sv:231-232`; `interfaces.md` §5 | 新版 spec 允许 DONE/ERROR 自动回 IDLE，但要求 status/counters 在 IDLE sticky；当前 `cycle_cnt` 到 IDLE 清零，`mac_cycles` accepted start 不清。 | done/error/cycle/mac counters 保持到下一次 accepted start/reset；accepted start 清 counters。 | RTL | open |
| 10 | P1 | online softmax/AV 证据 | `softmax_engine.sv`; `output_buffer.sv`; `attn_top.v:83-85`; `model.md` Online Softmax 与 AV 分离 | `correction`、`P_tile`、AV dot、O_acc 更新和 normalize/writeback 没有形成可验证闭环，不能证明数学等价。 | 补 `tb_softmax_engine`、`tb_mac_wrapper`、`tb_attn_top`，覆盖 alpha/beta/O_acc 更新。 | RTL + 验证 | open |
| 11 | P1 | 验证证据 | handover 对齐说明；`verification.md` | “VCS 503 tests” 无日志、seed、test list、report 路径；新版 verification 明确不作为关闭依据。 | 把 VCS/xsim/iverilog/verilator 真实日志放入 `runs/`，并列出覆盖场景。 | 验证 | open |
| 12 | P2 | 参数化 | `attn_core.sv:64-67`; `attn_core.sv:182-187`; `interfaces.md` §2 | head/group/tile index 位宽和终值硬编码，虽不再因缺 head range 阻塞，但仍违反单一参数源原则。 | 从 `N_Q_HEADS`、`N_KV_HEADS`、`GQA_GROUP`、`MAX_N_*_TILES` 派生。 | RTL | open |
| 13 | P2 | 路径落地 | `D:/projects/LARA/hw/rtl/`; `architecture.md` RTL 分层 | LARA 路径是 handover 来源，不是 competition 仓库正式落地路径。 | 吸收时迁移/镜像到 `D:/projects/competition/src/rtl/`，保留来源记录。 | 项目总控 | open |
| 14 | P3 | 工具兼容性 | `attn_core.sv:79`; `attn_top.v:84` | 本地 Icarus：`attn_core.sv` 单独前端检查可过但有 constant select warning；加入 `attn_top.v` 后在复杂数组端口连接处失败。 | 若主仿真使用 VCS，补 VCS log；若需要 Icarus smoke，隔离或降级 unsupported SV 写法。 | 验证 | open |

## 8. 修改调整与复审记录

| 轮次 | 修改人 | 修改内容 | 对应问题编号 | 复审人 | 复审结论 | 备注 |
| ---: | --- | --- | --- | --- | --- | --- |
| 1 | 项目文档维护 | 2026-07-10 将 handover route 接纳进 `docs/spec` | 旧规格冲突类问题 | Codex | closed/降级 | valid/ready、双 seq、head range、soft_reset 不再作为 Phase 1 阻塞。 |
| 2 | 队友 RTL 实现负责人 | 当前 `attn_core.sv` v2.0 | 1-14 | Codex | still open | 路线对齐，但实现 P0/P1 未关闭。 |

## 9. 可执行确认

| 被审对象类型 | 可执行确认 | 允许进入的下一环节 | 限制条件 |
| --- | --- | --- | --- |
| 代码结果 | 否 | 只允许作为 handover route 的整改输入和局部 testbench 对象 | 不允许作为 spec-compliant `attn_core` 集成签收、回归通过或论文证据 |

确认语句：

```text
不可执行：新版 spec 已经接纳 handover 路线，但当前 RTL 没有满足新版 spec 对 pulse command、MAC QK/AV done、writeback done、active rows、连续 start 清计数、causal 传播和 row-subtile 的要求。必须修复 P0 并补可追溯仿真证据后复审。
```

## 10. 审核结论与准出条件

结论：`FAIL`

准出条件：

- [ ] `*_start` 全部改为符合 spec 的单周期 command pulse，或有明确 wrapper edge-detect 合同并通过测试。
- [ ] QK 和 AV 阶段都有 `mac_start -> mac_done` 闭环，`mac_done` 表示完整 tile/phase 完成。
- [ ] 接入真实 `o_write_done`，覆盖 normalize/output/writeback 完成。
- [ ] 修复 `active_q_rows=32` 编码问题，`seq_len_32_full_tile` 通过。
- [ ] accepted start 清所有 loop counters、row-subtile counter 和 performance counters。
- [ ] `cfg_causal` 真实传播到 softmax/mask，`causal_toggle` 通过。
- [ ] 若 `TILE_ROWS<TILE_Q`，实现并验证 row-subtile 调度。
- [ ] 提供 VCS/xsim/iverilog/verilator 可追溯日志、seed、test list 和 report 路径。

## 11. 后续动作

1. 先按新版 spec 修 `attn_core` 的 pulse 输出语义：进入状态打一拍 command，后续只等待 done。
2. 补或重写 MAC wrapper，使 `mac_start` pulse 被锁存，QK/AV 均能独立产生 `mac_done`。
3. 修 `active_q_rows`、accepted start 清计数、performance counters sticky 这三个低成本 P0/P1。
4. 给 output buffer/writeback 加完成信号，替换顶层常绑 0 的 `o_write_done`。
5. 用 `verification.md` 中的 `seq_len_32_full_tile`、`mac_pulse_latch_av`、`o_write_done_closure`、`causal_toggle` 作为第一轮复审门槛。
