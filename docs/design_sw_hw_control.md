# 软硬件协同模块设计方案：Host/DMA/Top/Core Control

> 状态：整改版 / 待复审。本文根据 `docs/review/sw_hw_control_design_audit_2026-07-11.md` 修订。正式接口合同以 `docs/spec/interfaces.md` 第 10-13 节为准；本文只保留设计解释、取舍、任务拆分和验证入口。

## 1. 文档信息

| 项目 | 内容 |
| --- | --- |
| 模块名称 | `sw_hw_control` / host-driver-DMA-top-core control path |
| RTL 路径 | `src/rtl/axi/attn_axi_lite_slave.sv`、`src/rtl/axi/attn_axi_stream_sink.sv`、`src/rtl/axi/attn_axi_stream_source.sv`、`src/rtl/attn_top.sv`、`src/rtl/core/attn_core.sv` |
| 软件路径 | `sw/attn_driver.py`、`sw/host_attention.py` |
| 所属子系统 | `driver / axi / top / core-control` |
| 设计负责人 | 外围驱动 + FSM 负责人 |
| 验证负责人 | Golden/验证 + AXI/top 负责人 |
| 状态 | 整改版 / 待复审 |
| 正式合同 | `docs/spec/interfaces.md` 第 10-13 节 |

## 2. 功能定位

`sw_hw_control` 位于 Host PS 与 PL attention accelerator 之间，负责把软件侧 Q/K/V/O buffer、PYNQ DMA、AXI4-Lite CSR、AXI4-Stream 数据流、top wrapper 和 `attn_core` 控制 FSM 串成可验证的 Phase 1 full-run prefill transaction。

本模块负责：

- 定义 host 端如何配置 CSR、启动 DMA、启动计算、轮询状态和读回结果。
- 定义 AXI-Lite CSR 与 `attn_core`、AXIS sink/source 的配置关系。
- 定义 top wrapper 如何把 AXIS stream 路由到 K staging、V staging、Q staging，并把 output path 接回 AXIS source。
- 定义 `attn_core` 与软件的协同边界：core 不直接访问 DDR，也不直接控制 PYNQ DMA IP。
- 固定 Phase 1 主模式：软件显式 DMA 预加载完整 Q/K/V，之后一次 `start` 由 core 内部遍历全部 Q heads 和 tiles。

本模块不负责：

- QKV projection、RMSNorm、RoPE 的数学实现细节。
- bf16 MAC、softmax、O_acc correction 的数值实现。
- 具体板卡上的 Vivado block design、AXI DMA IP 参数和地址分配；这些需要在平台约束/工程脚本中记录。
- 把 Python mock 结果当作硬件通过证据。

## 3. 关键裁决

| 审核问题 | Phase 1 裁决 | 影响 |
| --- | --- | --- |
| driver 事务粒度 | `full_run_preload_then_start` | driver 不按 Q tile/head 多次 start；core 内部遍历全 32 Q heads。 |
| DMA trigger 归属 | PYNQ DMA API 显式触发 | 写 `CSR_STREAM_LEN` 只配置 accelerator 侧长度检查，不启动 DMA IP。 |
| Q stream layout | `Q[q_head][s][d]` head-major full-run | 不支持 per-head Q tile stream 或 `[TILE_Q,4096]` full-head tile stream 作为主合同。 |
| K/V/Q preload | 软件在 start 前完成完整 K/V/Q stream preload | core `kv_load_start/q_load_start` 只触发片上 staging/cache 到 compute tile 的本地事务。 |
| start while busy | 置 sticky `error=1` 与 `ERR_BUSY_START`，不接受新事务 | driver 正常路径必须先读 `start_ready=1`。 |
| `soft_reset` | Phase 1 不作为必需 CSR | 若后续实现，需单独定义 DMA outstanding 策略并复审。 |

## 4. 上下游关系

```text
host_attention.py
    -> projected Q/K/V full-run arrays
attn_driver.py
    -> PYNQ allocate + DMA send/recv + MMIO CSR
AXI-Lite CSR + AXI DMA
    -> attn_top wrapper
attn_top wrapper
    -> AXIS sink/source + staging/cache wrappers + attn_core
attn_core
    -> local load/compute/write pulse commands
```

| 方向 | 模块 | 本模块依赖 | 对方依赖 |
| --- | --- | --- | --- |
| 上游 | `host_attention.py` | projected Q/K/V bf16 arrays | driver 接收 shape/layout 一致的数据。 |
| 上游 | `attn_driver.py` | CSR map、DMA channel、buffer shape | status/error/perf 可轮询。 |
| 中间 | `attn_axi_lite_slave` | AXI4-Lite write/read | 导出 start/config/status/stream/result config。 |
| 中间 | `attn_axi_stream_sink` | AXIS MM2S data | `stream_dest/stream_len`、mem ready/error。 |
| 中间 | `attn_axi_stream_source` | output bf16 stream | `result_len`、S2MM ready。 |
| 下游 | `attn_core` | start/config、local load/write done、compute done | load/write/compute pulse command。 |
| 下游 | staging/cache/compute wrappers | data stream、command payload | done/error/status。 |

## 5. 功能与对应模块

| 功能点 ID | 功能描述 | 对应单元 | 是否本模块实现 | 备注 |
| --- | --- | --- | --- | --- |
| F001 | Host 预处理生成 projected Q/K/V | `sw/host_attention.py` | 否 | 本设计只定义输入边界。 |
| F002 | 分配 DMA buffer 并复制 Q/K/V/O 数据 | `sw/attn_driver.py` | 是 | PS 写 DDR buffer 对 `attn_core` 不可见。 |
| F003 | 配置 stream destination/length | driver + AXI-Lite CSR | 是 | CSR 不得在 top 中绑常量。 |
| F004 | 启动 DDR->PL DMA stream | PYNQ DMA send channel | 是 | 由 DMA API 触发，不由 `attn_core` 触发。 |
| F005 | AXIS sink 拆包和路由 K/V/Q | `attn_axi_stream_sink` + top wrapper | 是 | 2x bf16 per 32-bit beat。 |
| F006 | 启动 attention compute | CSR `start` -> `attn_core.start` | 是 | 只在 `start_ready=1` 时接受。 |
| F007 | `attn_core` 调度片上 load/compute/write | `attn_core.sv` | 是 | core 只看片上 pulse/done，不启动 PYNQ DMA。 |
| F008 | 输出 O 经 AXIS source 写回 DDR | output path + source + DMA recv | 是 | `o_write_done` 必须真实闭合。 |
| F009 | 状态、错误和性能计数回读 | CSR status/perf | 是 | 用于软件超时和证据链。 |

## 6. 参数、变量与配置

### 6.1 参数

| 名称 | 来源 | 默认值 | 约束 | 说明 |
| --- | --- | ---: | --- | --- |
| `BF16_W` | `attn_pkg.sv` | 16 | 固定 | AXIS 32-bit beat 携带 2 个 bf16。 |
| `HEAD_DIM` | `attn_pkg.sv` | 128 | 与模型一致 | 每个 head 维度。 |
| `N_Q_HEADS` | `attn_pkg.sv` | 32 | 与模型一致 | Q/O full-run shape `[32, S, 128]`。 |
| `N_KV_HEADS` | `attn_pkg.sv` | 8 | 与模型一致 | K/V full-run shape `[8, S, 128]`。 |
| `TILE_Q` | `attn_pkg.sv` | 32 | >0 | core 内部 Q tile 粒度。 |
| `TILE_KV` | `attn_pkg.sv` | 64 | >0 | core 内部 KV tile 粒度。 |
| `CSR_ADDR_W` | `attn_pkg.sv` | from pkg | 4-byte aligned | AXI4-Lite CSR 地址宽度。 |

### 6.2 配置字段

| 字段 | 位宽 | 采样时刻 | 合法范围 | 非法处理 | 说明 |
| --- | ---: | --- | --- | --- | --- |
| `seq_len` | 16 or `SEQ_POS_W` | accepted start | `1..MAX_SEQ_LEN` | `error=1`, `ERR_BAD_CONFIG` | Phase 1 单序列 prefill 长度。 |
| `cfg_q_pos_base` | `SEQ_POS_W` | accepted start | no wrap | `error=1`, `ERR_BAD_CONFIG` | causal 绝对位置。 |
| `cfg_kv_pos_base` | `SEQ_POS_W` | accepted start | no wrap | `error=1`, `ERR_BAD_CONFIG` | causal 绝对位置。 |
| `cfg_causal` | 1 | accepted start | 0/1 | N/A | 必须传到 softmax/mask。 |
| `stream_dest` | enum | stream start | K/V/Q | `stream_error=1`, `ERR_BAD_DEST` | DDR->PL stream 路由。 |
| `stream_len` | 32 | stream start | bytes > 0 and aligned | `stream_error=1`, `ERR_STREAM_LEN` | DDR->PL stream 字节数。 |
| `result_len` | 32 | readback start | bytes > 0 and aligned | `error=1`, `ERR_RESULT_LEN` | PL->DDR result 字节数；错误码已在 `attn_pkg.sv` 冻结为 `8'h12`。 |

### 6.3 内部变量与计数器

| 名称 | 类型 | 位宽 | 复位值 | 更新条件 | 说明 |
| --- | --- | ---: | ---: | --- | --- |
| `stream_byte_cnt` | counter | 32 | 0 | AXIS beat accepted | sink/source byte count。 |
| `stream_dest_r` | register | enum | 0 | stream config accepted | 当前 stream destination。 |
| `stream_busy_r` | flag | 1 | 0 | transfer active | 防止 stream config 被覆盖。 |
| `q_wr_addr_r` | counter | derived | 0 | Q stream data accepted | Q staging 写地址。 |
| `k_wr_addr_r` | counter | derived | 0 | K stream data accepted | K staging/cache 写地址。 |
| `v_wr_addr_r` | counter | derived | 0 | V stream data accepted | V staging/cache 写地址。 |
| `status_r` | CSR shadow | 32 | 0 | core/wrapper status | start_ready/busy/done/error/perf readable。 |

## 7. 接口摘要

### 7.1 软件 API 摘要

| API/动作 | 输入 | 输出 | 说明 |
| --- | --- | --- | --- |
| `configure(seq_len, q_pos_base, kv_pos_base, causal)` | seq/position/causal | CSR writes | 配置计算参数。 |
| `preload_k(K)` | `[N_KV_HEADS, S, HEAD_DIM]` | DMA send | 写 `STREAM_TO_K_CACHE` 和 `k_bytes` 后发送。 |
| `preload_v(V)` | `[N_KV_HEADS, S, HEAD_DIM]` | DMA send | 写 `STREAM_TO_V_CACHE` 和 `v_bytes` 后发送。 |
| `preload_q(Q)` | `[N_Q_HEADS, S, HEAD_DIM]` | DMA send | 写 `STREAM_TO_Q_BUF` 和 `q_bytes` 后发送。 |
| `start()` | N/A | CSR start | 启动 full-run core transaction。 |
| `wait_done(timeout)` | timeout | status | 轮询 done/error。 |
| `readback_o()` | expected `o_bytes` | DMA recv | 读回 full-run O。 |

禁止 Phase 1 driver API 同时暴露 `load_q_tile(Q_tile)` 作为主路径；若保留 debug API，必须标注为 unit test/mock-only，不能作为系统签收路径。

### 7.2 最小 CSR map

CSR 字段和 sticky 语义以 `docs/spec/interfaces.md` 第 10.4 节为准。设计实现至少包含：

| CSR / field | Access | 复位值 | 语义 |
| --- | --- | ---: | --- |
| `CSR_CTRL.start` | W1P | 0 | start request；`start_ready=0` 时置 `ERR_BUSY_START`。 |
| `CSR_CTRL.clear_status` | W1P | 0 | 清 sticky done/error/stream_error/error_code，不中断事务。 |
| `CSR_STATUS.start_ready` | R | 1 | 可接受 start。 |
| `CSR_STATUS.busy/done/error/stream_error` | R | 0 | 软件轮询状态。 |
| `CSR_ERROR_CODE` | R | 0 | 错误分类。 |
| `CSR_SEQ_LEN` | R/W | 0 | 本次 prefill 长度。 |
| `CSR_Q_POS_BASE` | R/W | 0 | Q 绝对位置 base。 |
| `CSR_KV_POS_BASE` | R/W | 0 | K/V 绝对位置 base。 |
| `CSR_CFG.causal` | R/W | 1 | causal enable。 |
| `CSR_STREAM_DEST` | R/W | 0 | K/V/Q stream destination。 |
| `CSR_STREAM_LEN` | R/W | 0 | DDR->PL stream byte length；不触发 PYNQ DMA。 |
| `CSR_RESULT_LEN` | R/W | 0 | PL->DDR result byte length。 |
| `CSR_PERF_*` | R | 0 | cycles、MAC cycles、stall counters。 |

### 7.3 Top/core 连接摘要

| 信号 | 方向 | 位宽 | 复位值 | 握手/稳定性 | 说明 |
| --- | --- | ---: | ---: | --- | --- |
| `start` | CSR -> core | 1 | 0 | accepted by `start_ready` | compute start。 |
| `start_ready` | core/wrapper -> CSR | 1 | 1 | level | 防重复 start。 |
| `busy/done/error/error_code` | core/wrapper -> CSR | mixed | 0 | sticky where specified | 软件状态。 |
| `seq_len/q_pos_base/kv_pos_base/causal` | CSR -> core | mixed | 0/1 | stable during compute | compute config。 |
| `stream_dest/stream_len` | CSR -> sink | enum/32 | 0 | stable during stream | DDR->PL 路由和长度。 |
| `result_len` | CSR -> source | 32 | 0 | stable during result | PL->DDR 长度。 |
| `data_valid/data_out/dest_sel` | sink -> mem | 1/16/enum | 0 | AXIS-derived | K/V/Q 写入。 |
| `kv_load_start/q_load_start/o_write_start` | core -> local wrapper | 1 | 0 | pulse | 片上 local load/write command。 |
| `kv_load_done/q_load_done/o_write_done` | local wrapper -> core | 1 | 0 | done | 真实完成信号。 |

## 8. 数据格式

| 数据对象 | Shape / Tile | 类型 | Layout | 对齐 | 来源/去向 |
| --- | --- | --- | --- | --- | --- |
| Q full-run buffer | `[N_Q_HEADS, S, HEAD_DIM]` | bf16 | head-major | DMA aligned, 4B stream aligned | host -> DDR -> AXIS sink -> Q staging |
| K full-run buffer | `[N_KV_HEADS, S, HEAD_DIM]` | bf16 | head-major | DMA aligned, 4B stream aligned | host -> DDR -> K staging/cache |
| V full-run buffer | `[N_KV_HEADS, S, HEAD_DIM]` | bf16 | head-major | DMA aligned, 4B stream aligned | host -> DDR -> V staging/cache |
| O full-run buffer | `[N_Q_HEADS, S, HEAD_DIM]` | bf16 output | head-major | DMA aligned, 4B stream aligned | output path -> DDR -> host |
| AXIS beat | 2 bf16 elements | 32-bit | `{bf16_hi, bf16_lo}` | 4B | DMA stream |

统一长度公式：

```text
bytes_per_bf16 = BF16_W / 8 = 2
q_bytes = N_Q_HEADS  * seq_len * HEAD_DIM * bytes_per_bf16
k_bytes = N_KV_HEADS * seq_len * HEAD_DIM * bytes_per_bf16
v_bytes = N_KV_HEADS * seq_len * HEAD_DIM * bytes_per_bf16
o_bytes = N_Q_HEADS  * seq_len * HEAD_DIM * bytes_per_bf16
```

## 9. 逻辑规范

### 9.1 正常流程

1. Host 侧运行 RMSNorm/QKV projection/optional RoPE，得到 projected Q/K/V full-run arrays。
2. Driver 分配 DMA buffer，并把 Q/K/V bytes 复制到 DDR buffer。
3. Driver 配置并 DMA send K：`STREAM_TO_K_CACHE`, `k_bytes`。
4. Driver 配置并 DMA send V：`STREAM_TO_V_CACHE`, `v_bytes`。
5. Driver 配置并 DMA send Q：`STREAM_TO_Q_BUF`, `q_bytes`。
6. Driver 写 `seq_len/q_pos_base/kv_pos_base/causal`，读到 `start_ready=1` 后写 `CSR_CTRL.start`。
7. `attn_core` 锁存配置，按内部 FSM 遍历 all Q heads/Q tiles/KV tiles，通过 local pulse 驱动 staging/cache/compute/output。
8. Driver 写 `CSR_RESULT_LEN=o_bytes` 并启动 DMA recv，或按平台约定先启动 recv 再等待 source valid；两者顺序必须在 driver 中固定。
9. Driver 轮询 `done/error`，读取 perf，等待 DMA recv 完成后读回 O buffer。

### 9.2 控制规则

```text
software DDR copy != RTL control signal
DMA transfer       -> AXIS tvalid/tready/tlast
CSR write          -> accelerator config/status/control
attn_core command  -> on-chip local wrapper pulse/done
```

- bulk tensor data 只能通过 DMA/AXIS 或后续明确的 m_axi 数据路径，不通过 AXI4-Lite。
- CSR 配置在对应事务 active 期间必须保持稳定。
- `CSR_STREAM_LEN` 不触发 PYNQ DMA；DMA start 由 software DMA API 完成。
- stream length 与 `tlast` 不一致时，sink/source 必须置 sticky `stream_error`。
- `o_write_done`、`q_load_done`、`kv_load_done` 必须来自真实 wrapper 完成，不能常绑。
- `start_ready=0` 时写 start 置 `ERR_BUSY_START`，不接受新事务。

### 9.3 FSM

本设计包含四个层次的状态机：

| FSM | 状态 | 进入条件 | 退出条件 | 主要动作 |
| --- | --- | --- | --- | --- |
| Driver flow | `CFG -> SEND_K -> SEND_V -> SEND_Q -> START -> WAIT -> RECV_O` | API 调用 | done/error/timeout | 软件 full-run 事务编排。 |
| Stream sink | `IDLE -> RECV -> DONE/ERROR` | DMA send active | byte count/tlast | 拆包与路由 K/V/Q。 |
| Core FSM | 见 `docs/spec/interfaces.md` 第 9 节 | CSR start accepted | all loops done | 片上计算编排。 |
| Stream source | `IDLE -> COLLECT -> SEND -> DONE/ERROR` | output data valid | result_len/tlast | O 打包回 DDR。 |

## 10. Buffer / FIFO / RAM

| 名称 | 类型 | 深度 | 位宽 | 内容 | 满空/流控规则 |
| --- | --- | ---: | ---: | --- | --- |
| DMA input buffer | DDR coherent buffer | shape-dependent | 8-bit view | Q/K/V bytes | software allocates and fills before DMA send。 |
| DMA output buffer | DDR coherent buffer | shape-dependent | 8-bit view | O bytes | DMA recv completes before host reads。 |
| AXIS sink unpack buffer | register/toggle | 1 beat | 32 -> 16 | two bf16 per beat | respects `s_axis_tready`。 |
| K staging/cache | BRAM/URAM/external wrapper | per resource plan | `BF16_W` or row-wide | K full-run stream | write by sink, read by local load wrapper。 |
| V staging/cache | BRAM/URAM/external wrapper | per resource plan | `BF16_W` or row-wide | V full-run stream | write by sink, read by local load wrapper。 |
| Q staging | BRAM/URAM/external wrapper | per resource plan | `BF16_W` or row-wide | Q full-run stream | local `q_load_start` selects current head/tile。 |
| Q tile buffer | ping-pong SRAM/URAM | `2*TILE_Q*HEAD_DIM` | `BF16_W` | current Q head/tile | `q_load_done` only after valid tile present。 |
| Output buffer/source FIFO | SRAM/URAM/FIFO | tile/full-run dependent | `BF16_W` output | O stream | source consumes until `result_len`。 |

K/V/Q full-run staging 的资源风险必须在后续 mem/profiling 任务中闭环；若 target shape 放不下，需重新审核改为 tiled external-memory 路线。

## 11. 异常与边界

| 场景 | 触发条件 | 期望行为 | 检查方式 |
| --- | --- | --- | --- |
| start while busy | host writes start when `start_ready=0` | 不接受新事务；置 `ERR_BUSY_START` | CSR directed test。 |
| stream len mismatch | `tlast` before/after expected byte count | sticky `stream_error`，status/error_code 可读 | AXIS sink/source test。 |
| wrong stream dest | dest 非 K/V/Q | sticky `ERR_BAD_DEST`，不写任何 buffer | CSR/AXIS test。 |
| DMA timeout | software wait 超时 | driver 读取 status/perf/error 并记录日志 | driver smoke。 |
| output done missing | source/output 不产生 done | core 不得误置 done；test 应失败 | top smoke。 |
| reset during DMA | `rst_n=0` 且 DMA outstanding | Phase 1 driver 禁止作为正常路径；board-level 文档记录恢复步骤 | board-level reset test。 |
| reset during compute | `rst_n=0` | 清 core/wrapper busy；sticky status 按接口重置 | reset test。 |
| cache coherency | PS 写 buffer 后 DMA 读到旧数据 | driver 必须 flush/invalidate 或用 coherent allocate | board-level smoke。 |
| transaction granularity mismatch | driver per-tile start，core full-run loop | 禁止作为签收；接口评审失败 | interface review。 |

## 12. 验证入口

| 用例名 | 覆盖目标 | 输入/操作 | 通过条件 | 证据路径 |
| --- | --- | --- | --- | --- |
| `sw_hw_control_csr_smoke` | CSR map、sticky status、busy start | 写配置、start、busy start、clear_status | status/error_code 符合合同 | `runs/sw_hw_control/<date>_csr_smoke/` |
| `sw_hw_control_stream_len` | stream dest/len/tlast | K/V/Q 三类 stream，插入 len mismatch | 正确路由，错误置 sticky | `runs/sw_hw_control/<date>_stream_len/` |
| `sw_hw_control_full_run_preload` | full-run Q/K/V preload | `S=16/32`，发送 K/V/Q full-run buffer | byte count 和 staging 地址正确 | `runs/sw_hw_control/<date>_full_run_preload/` |
| `sw_hw_control_top_smoke` | top wrapper 闭环 | K/V/Q stream -> fake compute -> source -> readback | done/source_done/o_write_done 闭合 | `runs/sw_hw_control/<date>_top_smoke/` |
| `sw_hw_control_cache_coherency_note` | PYNQ buffer coherency | coherent allocate 或 flush/invalidate 路径 | driver 日志记录平台策略 | `runs/sw_hw_control/<date>_cache_coherency/` |

其他验证入口：

- software mock smoke：`attn_driver.py --check` 只能验证 API shape，不算硬件通过。
- AXIS sink unit：发送 K/V/Q 三类 stream，检查 `dest_sel`、写使能互斥、byte count、tlast error。
- AXIS source unit：给定 output bf16 stream，检查 2:1 打包、`m_axis_tlast`、`bytes_sent`。
- core/top integration：覆盖 `q_load_done/kv_load_done/o_write_done` 真实闭合，不能常绑。

## 13. 官方事实、工程假设、个人判断

| 类别 | 内容 |
| --- | --- |
| 官方/正式规格 | 第一阶段以 `docs/spec/` 为准，只做 projected Q/K/V attention core；AXI 协议不进入 `src/rtl/core/`。 |
| 队友资料结论 | LARA 采用 PYNQ driver、MMIO CSR、AXI DMA MM2S/S2MM、AXIS sink/source、`attn_core` FSM 的协同路线。 |
| 工程假设 | PYNQ 路线下 DMA IP 由 software DMA API 启动，CSR 负责 accelerator 侧配置和状态；Phase 1 采用 full-run preload 后 start。 |
| 个人判断 | full-run preload 能最快关闭 driver/core 事务粒度冲突；资源风险留给 mem/profiling 证据闭环，后续若改 tiled streaming 必须重新审核接口。 |

## 14. 待确认问题

| 编号 | 问题 | 负责人 | 关闭条件 |
| ---: | --- | --- | --- |
| 1 | K/V/Q full-run staging 在 target shape 下的资源承载方式。 | 架构/Profiling + mem | 有资源估算或 runs 证据，并决定 URAM/BRAM/external-memory 策略。 |
| 2 | 是否启用 `CSR_STREAM_SRC/RESULT_DST` 地址 CSR。 | 软件/系统集成 | PYNQ 与非 PYNQ 地址路径统一。 |
| 3 | `soft_reset` 是否作为 Phase 2 CSR。 | 接口/RTL | 若加入，定义 DMA outstanding 处理。 |
| 4 | 当前 LARA top 临时绑线整改顺序。 | RTL top | `cfg_dest/cfg_len/q_wr_en/o_write_done` 接入真实信号并通过 smoke。 |

## 15. 审核问题整改映射

| 审核问题 | 本次处理 |
| --- | --- |
| P1-1 driver 事务粒度未冻结 | 冻结为 full-run preload then single start；删除 `load_q_tile` 主路径。 |
| P1-2 K/V/Q preload 归属未冻结 | 冻结为软件显式 DMA preload，core pulse 只做片上 local load/write。 |
| P1-3 CSR 摘要缺字段 | 增加 position base、causal、start_ready、busy/error/error_code、stream_error、perf 字段。 |
| P1-4 Q buffer layout 未冻结 | 冻结为 `Q[q_head][s][d]` head-major full-run stream。 |
| P1-5 文档维护漂移 | 开头声明正式合同以 `interfaces.md` 第 10-13 节为准，本文只解释设计选择。 |
| P2-6 长度公式缺失 | 增加 Q/K/V/O byte length 公式。 |
| P2-7 验证入口未映射 | 增加 `sw_hw_control_*` 用例名、通过条件和 runs 路径。 |
| P2-8 reset/异常策略未冻结 | 冻结 busy start 为 `ERR_BUSY_START`；`soft_reset` 不作为 Phase 1 必需项。 |
## 16. 2026-07-11 测试结果整改记录

依据 `docs/result/test_plan_sw_hw_control_result_2026-07-11.md` 的 BLOCKED / PARTIAL PASS 结论，本轮对设计和实现作如下收敛：

| 测试发现 | 设计/实现处理 | 当前证据 |
| --- | --- | --- |
| F001：缺 P0 testbench/runner | 新增 CSR TB `src/hw/rtl/tb/tb_sw_hw_control_csr.sv`，覆盖 T001/T002；新增 sink TB `src/hw/rtl/tb/tb_sw_hw_control_sink.sv`，覆盖 T003/T004。 | `runs/sw_hw_control/2026-07-11_fix_execution/{csr_vvp.log,sink_vvp.log}` 均 PASS。 |
| F002：top 全量 Icarus compile 失败 | Phase 1 top 中 RoPE 保持 host-side/optional，不实例化 `rope_engine`；当前 top compile 进入 0 退出码。 | `runs/sw_hw_control/2026-07-11_fix_execution/top_compile.log`，仅剩既有 shortreal/Icarus 支持告警。 |
| F003：`ERR_RESULT_LEN` 未冻结 | 在 `src/hw/rtl/pkg/attn_pkg.sv` 增加 `ERR_RESULT_LEN = 8'h12`，driver mirrored constant 为 `0x12`。 | `attn_pkg.sv` / `attn_driver.py` 可 grep 到常量。 |
| F004：driver 缺可审计 mock trace | `MockMMIO`、`MockDMAChannel` 增加 trace；新增 `src/sw/tests/test_sw_hw_control_driver.py` 验证 configure -> clear -> K/V/Q preload -> result_len -> single start -> recv 顺序。 | `runs/sw_hw_control/2026-07-11_fix_execution/driver_unittest.log` PASS。 |

当前本地仿真 P0 控制链路已具备可执行入口并通过：T001/T002/T003/T004/T005/T006/T007/T008。T008 使用 compute stubs 和 forced local completions，只声明 control-path smoke，不声明真实 attention 数值正确；board-level PYNQ DMA/CSR 协同仍未执行。

备注：src/hw/rtl/tb/tb_sw_hw_control_compute_stubs.sv 仅用于 sw/hw control-path testbench，目的是绕开 Icarus 对真实 compute shortreal 系统函数的限制；不能作为 MAC/softmax/output_buffer 数值正确性证据。
