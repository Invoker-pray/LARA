# 功能测试方案：控制单元及软硬件协同

> 状态：审核后修订版 / 有条件可执行。本文根据 `docs/review/test_plan_sw_hw_control_audit_2026-07-11.md` 修订。正式接口合同以 `docs/spec/interfaces.md` 第 10-13 节为准；当前可执行 CSR、stream dest 和错误码以 `src/hw/rtl/pkg/attn_pkg.sv` 为实现源。

## 1. 验证对象

| 项目 | 内容 |
| --- | --- |
| 对象 | `sw_hw_control` / Host-DMA-CSR-AXIS-top-core control path |
| RTL 路径 | `src/hw/rtl/axi/attn_axi_lite_slave.sv`、`src/hw/rtl/axi/attn_axi_stream_sink.sv`、`src/hw/rtl/axi/attn_axi_stream_source.sv`、`src/hw/rtl/attn_top.v`、`src/hw/rtl/core/attn_core.sv` |
| 软件路径 | `src/sw/attn_driver.py`、`src/sw/host_attention.py`、后续 `src/sw/tests/` |
| 审核依据 | `docs/review/test_plan_sw_hw_control_audit_2026-07-11.md` |
| 验证负责人 | Golden/验证 agent + RTL/软件负责人 |
| 状态 | 执行中：T001-T008 本地控制路径入口已通过；T008 为 compute-stub control smoke，板级/真实数值仍未签收 |

## 2. 验证范围与边界

覆盖：

- AXI4-Lite CSR map、读写语义、sticky status、`clear_status` 和 busy start 行为。
- Phase 1 `full_run_preload_then_start`：软件完整 DMA preload K/V/Q，再一次 `CSR_CTRL.start` 启动 core。
- `CSR_STREAM_DEST` / `CSR_STREAM_LEN` 到 AXIS sink 的路由、长度和 `tlast` 检查。
- `CSR_RESULT_LEN` 到 AXIS source 的输出长度和 `m_axis_tlast` 检查。
- top wrapper 中 CSR、AXIS sink/source、K/V/Q staging、`attn_core` pulse/done 的连接闭环。
- driver API shape/layout、byte length 公式、状态轮询、错误上报、timeout 和 mock MMIO/DMA trace。
- PYNQ buffer cache coherency 策略记录，不把 Python mock 当硬件通过证据。

暂不覆盖：

- bf16 MAC、softmax、RoPE、RMSNorm、QKV projection 的数值正确性完整证明。
- Vivado block design 地址分配、AXI DMA IP 参数、板级时钟/复位约束的最终签收。
- full attention block 或 Phase 2 core-triggered external DMA。
- 资源、频率、性能最终达标；本文只定义 profiling 入口和报告归档要求。

边界说明：

- 本文准出只代表 **sw/hw control path** 准出，不代表 attention 数值正确性、真实 `attn_core` 全闭环或板级 DMA 签收。
- `T008` 若使用 fake/reduced compute，只能声明 control-path smoke；真实 core 风险由 `T015-T017` 或 `docs/spec/verification.md` 中的 core 回归关闭。
- 当前仓库尚无 `run_tb_sw_hw_control_*.ps1`、`tb_sw_hw_control_*.sv` 和 board smoke runner；这些是 P0/P1 回归准入 blocker。

## 3. 参考模型、输入与目录

| 类型 | 路径 | 说明 |
| --- | --- | --- |
| DUT | `src/hw/rtl/axi/*.sv`、`src/hw/rtl/attn_top.v`、`src/hw/rtl/core/*.sv` | 控制单元、AXIS 适配和 top/core 协同路径。 |
| Software DUT | `src/sw/attn_driver.py` | PYNQ/MMIO/DMA driver，主模式为 full-run preload。 |
| Golden | `src/sw/host_attention.py`、后续 `src/sw/tests/golden_*` | 控制测试主要使用 shape、byte count、状态期望；数值检查另行归属。 |
| Vectors | `src/sw/tests/vectors/sw_hw_control/` | deterministic vectors：`S=1/16/32/33/64/65/96`，head-major bf16 `uint16` layout。 |
| RTL testbench | `src/hw/rtl/tb/tb_sw_hw_control_*.sv` | CSR、AXIS sink/source、top smoke、backpressure/reset 分层实现。 |
| 软件测试 | `src/sw/tests/test_sw_hw_control_*.py` | driver mock、byte formula、flow trace、board smoke wrapper。 |
| Logs | `runs/sw_hw_control/{date}_{case}/` | 保存命令、seed、工具版本、stdout/stderr、波形和 `manifest.json`。 |

## 4. 当前错误码冻结与 blocker

当前可执行实现源 `attn_pkg.sv` 中的错误码为：

| 错误码 | 值 | 用途 |
| --- | ---: | --- |
| `ERR_NONE` | `8'h00` | 无错误 |
| `ERR_BAD_CFG` | `8'h01` | 非法配置：`seq_len`、position overflow 等 |
| `ERR_BUSY_START` | `8'h02` | `start_ready=0` 时写 `CSR_CTRL.start` |
| `ERR_STREAM_LEN` | `8'h10` | stream/result 长度或 `tlast` 不匹配 |
| `ERR_STREAM_DEST` | `8'h11` | `CSR_STREAM_DEST` 非 K/V/Q |

接口文档仍提到 `ERR_BAD_CONFIG`、`ERR_BAD_DEST`、`ERR_RESULT_LEN`。本测试方案执行时先以 `attn_pkg.sv` 命名为准：

- `ERR_BAD_CONFIG` 等价映射到 `ERR_BAD_CFG`。
- `ERR_BAD_DEST` 等价映射到 `ERR_STREAM_DEST`。
- `ERR_RESULT_LEN` 已在 `attn_pkg.sv` 冻结为 `8'h12`，driver mirrored constant 为 `0x12`；当前 T007 单元测试先覆盖 source `result_len/tlast/stall` 行为。

## 5. 测试层级

| 层级 | 目标 | 准出标准 |
| --- | --- | --- |
| unit-csr | 验证 AXI4-Lite CSR 行为和错误码 | T001/T002 PASS；busy start 不产生 accepted start。 |
| unit-axis | 验证 sink/source 的 bf16 拆包/打包、dest、len、tlast | T003/T004/T007 PASS；len/dest/result_len 行为已有单元级入口。 |
| sw-driver | 验证 driver shape、byte formula、mock MMIO/DMA 编排 | T006 PASS；不出现 per-tile/per-head start 主路径。 |
| integration-top | 验证 top wrapper 互连和 local done 闭合 | T005/T008 PASS；T008 使用 compute stubs/forced local completion，仅签收 control path。 |
| core-risk | 关闭 fake compute 掩盖的真实 core 风险 | T015-T017 PASS 或交叉引用 core 回归 PASS。 |
| board-smoke | 在 PYNQ/KV260 或等价平台验证 DMA/CSR 真实协同 | T012 PASS 或按 waiver 模板记录 blocker。 |
| profiling | 记录 cycles、MAC cycles、stream byte count 和 timeout | 报告归档到 `runs/`，不作论文数据除非实验完整。 |

## 6. 场景清单

| ID | 优先级 | 名称 | 类型 | 测试目的 | 期望来源 | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| T001 | P0 | `sw_hw_control_csr_smoke` | smoke/protocol | CSR map、config readback、accepted start、sticky done/error、clear_status | `interfaces.md` 10.4、`attn_pkg.sv` | pass: `2026-07-11_fix_execution` |
| T002 | P0 | `sw_hw_control_busy_start` | boundary/protocol | `start_ready=0` 时 start 不接受新事务并置 `ERR_BUSY_START` | `interfaces.md` 10.4、`attn_pkg.sv` | pass: `2026-07-11_fix_execution` |
| T003 | P0 | `sw_hw_control_stream_dest_route` | function | K/V/Q stream 按 `dest_sel` 路由，写使能互斥 | `interfaces.md` 10.2/11.2 | pass: `2026-07-11_fix_execution` |
| T004 | P0 | `sw_hw_control_stream_len` | boundary/protocol | `CSR_STREAM_LEN` 与 `tlast` 一致性检查，非法 dest 唯一归到 `ERR_STREAM_DEST` | `interfaces.md` 10.5/11.2、`attn_pkg.sv` | pass: `2026-07-11_fix_execution` |
| T005 | P0 | `sw_hw_control_full_run_preload` | integration | full-run K/V/Q head-major preload byte count 和 staging 地址递增 | byte formula + layout spec | pass: `2026-07-11_fix_execution` |
| T006 | P0 | `sw_hw_control_single_start_full_run` | sw-driver | driver 按 configure/clear/preload K/V/Q/result_len/start/wait/recv 顺序执行，一次 full-run start | `design_sw_hw_control.md` | pass: unittest trace `2026-07-11_fix_execution` |
| T007 | P0 | `sw_hw_control_result_len_source` | protocol | source 按 `CSR_RESULT_LEN=o_bytes` 产生 `m_axis_tlast`；stall 下保持 payload 稳定 | `interfaces.md` 10.2/10.3 | pass: `2026-07-11_fix_execution` |
| T008 | P0 | `sw_hw_control_top_control_smoke` | integration | K/V/Q stream -> top staging -> CSR start -> core loop -> CSR done 控制闭环 | `verification.md` sw/hw 用例 | pass: compute-stub smoke `2026-07-11_fix_execution` |
| T009 | P1 | `sw_hw_control_illegal_config` | boundary | `seq_len=0/>MAX`、position overflow 进入 `ERR_BAD_CFG`，不发下游 command | core config rules | blocked: TB 待实现 |
| T010 | P1 | `sw_hw_control_backpressure` | protocol | AXIS input/output ready stall 下 payload 稳定，byte count 正确 | AXI stream protocol | blocked: TB 待实现 |
| T011 | P1 | `sw_hw_control_reset_mid_transaction` | boundary | stream/compute/output 中 reset 后状态回初值 | `interfaces.md` reset 语义 | blocked: TB 待实现 |
| T012 | P1 | `sw_hw_control_cache_coherency_note` | board-smoke | PYNQ buffer flush/invalidate/coherent allocate 策略可追溯 | driver/platform note | blocked/waiver |
| T013 | P2 | `sw_hw_control_perf_counter_smoke` | profiling | cycles/mac_cycles 可读、accepted start 清零、done 后保持 | CSR/perf spec | blocked: TB 待实现 |
| T014 | P1 | `sw_hw_control_boundary_lengths` | random/boundary | `S=1/2/15/16/31/32/33/63/64/65/96` 与非零 position base | byte formula + partial tile rules | blocked: vector/TB 待实现 |
| T015 | P1 | `sw_hw_control_mac_start_closure` | core-risk | 真实 core `mac_start -> mac_done` 两相均闭合 | `verification.md` | cross-ref/core blocked |
| T016 | P1 | `sw_hw_control_active_q_rows_full_tile` | core-risk | `active_q_rows=32` 不被 5-bit 截断为 0 | `interfaces.md` partial tile rules | cross-ref/core blocked |
| T017 | P1 | `sw_hw_control_causal_toggle` | core-risk | `cfg_causal` 从 CSR 传到 softmax/mask | `interfaces.md` causal mask rules | cross-ref/core blocked |
| X001 | exec | `current_driver_mock` | current | 当前可执行软件 mock self-test | driver asserts | executable |
| X002 | exec | `current_rtl_compile` | current | 当前 RTL compile-only 基线 | tool compile | executable |

## 7. 单测试场景定义

### 7.1 T001 `sw_hw_control_csr_smoke`

| 项目 | 内容 |
| --- | --- |
| 优先级 | P0 |
| 被测模块 | `attn_axi_lite_slave.sv` |
| Checker | CSR scoreboard + start pulse assertion |
| 日志 | `runs/sw_hw_control/{date}_csr_smoke/manifest.json` |

输入构造：`seq_len=16`、`q_pos_base=0`、`kv_pos_base=0`、`causal=1`；mock `start_ready=1 -> done=1`；perf counters 非零。

期望行为：写入配置后读回一致；写 `CSR_CTRL.start` 产生单周期 `start`；accepted start 清 sticky status；`done` 后 `CSR_STATUS.done=1` sticky；`clear_status` 清 sticky 但不产生 start。

待实现运行方式：

```powershell
iverilog -g2012 -I src/hw/rtl/pkg -o runs/sw_hw_control/{date}_csr_smoke/tb.vvp src/hw/rtl/pkg/attn_pkg.sv src/hw/rtl/axi/attn_axi_lite_slave.sv src/hw/rtl/tb/tb_sw_hw_control_csr.sv
vvp runs/sw_hw_control/{date}_csr_smoke/tb.vvp
```

通过标准：checker PASS、无 X 传播、manifest 记录命令/工具/seed/结果。

### 7.2 T002 `sw_hw_control_busy_start`

| 项目 | 内容 |
| --- | --- |
| 优先级 | P0 |
| 被测模块 | `attn_axi_lite_slave.sv` |
| Checker | start handshake assertion + CSR error scoreboard |
| 日志 | `runs/sw_hw_control/{date}_busy_start/manifest.json` |

输入构造：`busy=1`、`start_ready=0` 时写 `CSR_CTRL.start=1`。

期望行为：不产生 `start` pulse；当前事务配置不被覆盖；`CSR_STATUS.error=1` sticky；`CSR_ERROR_CODE=ERR_BUSY_START`；`clear_status` 可清错误但不影响进行中的 `busy`。

通过标准：assertion PASS、CSR scoreboard PASS、失败时保留复现命令和波形。

### 7.3 T003 `sw_hw_control_stream_dest_route`

| 项目 | 内容 |
| --- | --- |
| 优先级 | P0 |
| 被测模块 | `attn_axi_stream_sink.sv` + top route wrapper |
| Checker | route scoreboard + mutual-exclusion assertion |
| 日志 | `runs/sw_hw_control/{date}_dest_route/manifest.json` |

输入构造：32-bit AXIS beat，连续 valid，无 stall；`dest=0/1/2`、`len=16`。

期望行为：`dest=STREAM_TO_K_CACHE` 只产生 `k_wr_en`；`dest=STREAM_TO_V_CACHE` 只产生 `v_wr_en`；`dest=STREAM_TO_Q_BUF` 只产生 `q_wr_en`；同周期 K/V/Q 写使能最多一个为 1；每个 stream transaction 地址计数从 0 开始单调递增。

通过标准：route scoreboard PASS；无混写、漏写、重复写。

### 7.4 T004 `sw_hw_control_stream_len`

| 项目 | 内容 |
| --- | --- |
| 优先级 | P0 |
| 被测模块 | `attn_axi_stream_sink.sv`、top sink route |
| Checker | byte scoreboard + dest checker |
| 日志 | `runs/sw_hw_control/{date}_stream_len/manifest.json` |

输入构造：exact len、early tlast、late/no tlast、`dest=3`；`len=4/8/16`。

期望行为：exact len 时 `done=1` 且无 overflow/underflow；early tlast 置 `ERR_STREAM_LEN`；late/no tlast 置 `ERR_STREAM_LEN`；wrong dest 不写 K/V/Q staging，CSR 汇总后 `stream_error=1`、`ERR_STREAM_DEST`。

通过标准：每个子场景 checker PASS；非法 dest 错误码不得泛化为 `ERR_STREAM_LEN`。

### 7.5 T005 `sw_hw_control_full_run_preload`

| 项目 | 内容 |
| --- | --- |
| 优先级 | P0 |
| 被测模块 | driver + AXIS sink + top staging route |
| Checker | byte formula checker + staging scoreboard |
| 日志 | `runs/sw_hw_control/{date}_full_run_preload/manifest.json` |

输入构造：Q `[32,S,128]`，K/V `[8,S,128]`，`S=16/32`，head-major deterministic pattern；按 K/V/Q 顺序 preload。

期望行为：`q_bytes=32*S*128*2`，`k_bytes=v_bytes=8*S*128*2`；K/V/Q 写使能互斥；staging 地址单调递增；无丢 beat、重复 beat、半字顺序颠倒；`CSR_STREAM_LEN` 只影响 checker，不触发 DMA。

通过标准：byte formula 与 staging scoreboard PASS；日志标明 `control-path preload only`。

### 7.6 T006 `sw_hw_control_single_start_full_run`

| 项目 | 内容 |
| --- | --- |
| 优先级 | P0 |
| 被测模块 | `src/sw/attn_driver.py` |
| Checker | Python unittest/pytest 或 `_self_test` + mock trace |
| 日志 | `runs/sw_hw_control/{date}_driver_mock/manifest.json` |

输入构造：Q `[32,16,128]`，K/V `[8,16,128]`，dtype `uint16`，position base 0，causal 1。

期望 driver flow：`configure` -> `clear_status` -> preload K -> preload V -> preload Q -> write `CSR_RESULT_LEN` -> read `start_ready` -> single `CSR_CTRL.start` -> `wait_done` -> DMA recv O。完整 pytest 必须输出 mock MMIO/DMA trace，证明没有 per-tile/per-head start。

当前可执行命令：

```powershell
python src/sw/attn_driver.py
```

完整准入命令：

```powershell
python -m pytest src/sw/tests/test_sw_hw_control_driver.py
```

通过标准：mock self-test PASS；完整测试还必须断言完整 driver flow。

### 7.7 T007 `sw_hw_control_result_len_source`

| 项目 | 内容 |
| --- | --- |
| 优先级 | P0 |
| 被测模块 | `attn_axi_stream_source.sv` |
| Checker | source byte/tlast scoreboard + AXIS stable assertion |
| 日志 | `runs/sw_hw_control/{date}_source/manifest.json` |

输入构造：exact/short/long output bf16 stream；ready always-ready + random stall seed 2；`result_len=o_bytes`。

期望行为：exact 时最后一个 accepted beat 上 `m_axis_tlast=1`；stall 时 `m_axis_tdata/m_axis_tlast` 稳定；odd final bf16 使用 padding beat 输出。`ERR_RESULT_LEN` 已冻结，short/long 错误的 CSR 汇总留到 source/top 集成测试。

通过标准：source scoreboard PASS。

### 7.8 T008 `sw_hw_control_top_control_smoke`

| 项目 | 内容 |
| --- | --- |
| 优先级 | P0 |
| 被测模块 | `attn_top.v` |
| Checker | top scoreboard + static constant check |
| 日志 | `runs/sw_hw_control/{date}_top_smoke/manifest.json` |

输入构造：`S=16` full-run K/V/Q stream；fake/reduced/real compute；output ready always-ready + stall seed 3。

期望行为：`stream_dest/stream_len/result_len/cfg_causal/position base` 不在 top 中绑常量；`kv_load_done/q_load_done/o_write_done` 来自 wrapper/source 状态；`done=1 && error=0` 后 DMA recv 看到 `o_bytes` 长度输出；fake compute 日志必须标注 `control-path smoke only`。

通过标准：top scoreboard PASS；static constant check PASS；fake/real compute 边界写入 manifest。

### 7.9 T009 `sw_hw_control_illegal_config`

输入构造：`seq_len=0`、`seq_len=MAX_SEQ_LEN+1`、`q_pos_base+seq_len>MAX_SEQ_LEN`、`kv_pos_base+seq_len>MAX_SEQ_LEN`。

期望行为：`error=1` sticky，`error_code=ERR_BAD_CFG`；不产生 `kv_load_start/q_load_start/o_write_start/mac_start/softmax_start`；status 保持到 clear、reset 或下一次 accepted start。

通过标准：非法配置子场景全 PASS。

### 7.10 T010 `sw_hw_control_backpressure`

输入构造：stall seeds `42/43/44`；input valid random bubble；output ready random stall；最长 stall 至少 16 cycles。

期望行为：sink 侧 `s_axis_tvalid && !s_axis_tready` 时 payload/tlast 稳定；source 侧 `m_axis_tvalid && !m_axis_tready` 时 payload/tlast 稳定；accepted byte count 不重复、不丢失；final `done` 与 `stream_len/result_len` 对齐。

通过标准：三个 seed 均 PASS。

### 7.11 T011 `sw_hw_control_reset_mid_transaction`

输入构造：reset 插入 `RECV_K`、`RECV_Q`、`COMPUTE`、`SEND_O` 四个阶段；DMA outstanding 只在 RTL 层模拟，不宣称 PYNQ 行为。

期望行为：`rst_n=0` 后 start/done/error/stream_error/internal busy 清零；sink/source byte counter 和 wr addr 回初值；reset 后可重新执行一次正常 T001/T003/T007 子流程。

通过标准：reset 子场景全 PASS；若真实 DMA outstanding 未定义，必须写 waiver。

### 7.12 T012 `sw_hw_control_cache_coherency_note`

输入构造：使用 `pynq.allocate()` 生成 Q/K/V/O buffer；若平台 buffer 非 coherent，driver 必须显式 flush before send、invalidate after recv，或记录 PYNQ allocate 的 coherency 保证；使用 `S=16` magic pattern 检查 PL 侧 byte count 与 host pattern。

通过标准：记录平台、PYNQ 版本、buffer coherency 策略、bitstream/hash、命令和结果。没有板卡、bitstream 或 DMA IP 时，用 waiver 记录 blocker，不允许把 `HAS_PYNQ=False` mock 当板级通过证据。

### 7.13 T014 `sw_hw_control_boundary_lengths`

输入构造：`S=1/2/15/16/31/32/33/63/64/65/96`；`q_pos_base/kv_pos_base=0/7/31` 合法组合；另设 position overflow 非法组合。

期望行为：byte formula 对所有合法 `S` exact；`S=33/65/96` 覆盖 partial Q/KV tile；非零 position base 参与 causal mask 位置语义；overflow 组合进入 `ERR_BAD_CFG`。

通过标准：所有合法组合 PASS；非法组合 PASS；若由 core 回归承担，manifest 中写交叉引用路径。

## 8. Checker 与通过标准

| 检查项 | Checker | 规则 |
| --- | --- | --- |
| CSR map | AXI-Lite scoreboard | 每个 CSR 地址读写字段与 `attn_pkg.sv` / `interfaces.md` 一致。 |
| start handshake | assertion | `start` 只在 `start_ready=1` accepted；busy start 设置 `ERR_BUSY_START` 且不重启事务。 |
| sticky status | CSR scoreboard | `done/error/stream_error/error_code` sticky 到 clear、reset 或下一次 accepted start。 |
| byte length | scoreboard | Q/K/V/O byte formulas exact match；`stream_len/result_len` 4B aligned。 |
| AXIS sink protocol | assertion | `tvalid && !tready` 时 payload/tlast 稳定；accepted beat 计数正确。 |
| AXIS source protocol | assertion | `m_axis_tvalid && !m_axis_tready` 时 data/tlast 稳定；last beat 与 `result_len` 对齐。 |
| routing | mutual-exclusion assertion | K/V/Q 写使能同周期最多一个为 1；非法 dest 不写 staging 并置 `ERR_STREAM_DEST`。 |
| top constants | static check | 不允许 `cfg_dest(2'd0)`、`cfg_len(32'd0)`、`cfg_q_pos_base(16'd0)`、`wr_en(1'b0)` 等旧绑线回归。 |
| driver API | pytest/mock trace | 主路径只 full-run preload + single start；形状不符抛错；byte_counts exact。 |
| numerical output | golden scoreboard | 只有在完整 compute path 可用时检查；control smoke 可只检查长度和 pattern。 |
| performance | CSR readback/report | accepted start 清零 counters；done 后 counters 保持到 clear/start。 |

P0 控制链路准出标准：

- T001-T008 全部 PASS。
- 无未归因 X 传播到有效输出或 CSR status。
- 无协议 assertion fail。
- 所有日志、seed、工具版本、波形路径归档到 `runs/sw_hw_control/`。
- `manifest.json` 对 fake compute、mock、board、real-core 范围做明确标注。
- 若 T008 使用 fake compute，结论必须限定为“控制链路通过”，不能声称 attention 数值通过或真实 core 通过。

## 9. 回归矩阵

| ID | 名称 | 优先级 | 类型 | Checker | Seed | 命令 | 状态 | 日志 | 备注 |
| --- | --- | --- | --- | --- | ---: | --- | --- | --- | --- |
| T001 | csr_smoke | P0 | smoke | CSR scoreboard | 0 | `src/hw/rtl/tb/tb_sw_hw_control_csr.sv` | pass | `runs/sw_hw_control/2026-07-11_fix_execution/` | 覆盖 CSR smoke。 |
| T002 | busy_start | P0 | boundary | assertion | 0 | `src/hw/rtl/tb/tb_sw_hw_control_csr.sv` | pass | `runs/sw_hw_control/2026-07-11_fix_execution/` | 已并入 T001 TB。 |
| T003 | stream_dest_route | P0 | function | route scoreboard | 0 | `src/hw/rtl/tb/tb_sw_hw_control_sink.sv` | pass | `runs/sw_hw_control/2026-07-11_fix_execution/` | 检查 K/V/Q dest pass-through。 |
| T004 | stream_len | P0 | boundary | byte scoreboard | 1 | `src/hw/rtl/tb/tb_sw_hw_control_sink.sv` | pass | `runs/sw_hw_control/2026-07-11_fix_execution/` | 覆盖 exact/underflow/overflow/bad dest。 |
| T005 | full_run_preload | P0 | integration | staging scoreboard | 1 | `src/hw/rtl/tb/tb_sw_hw_control_preload.sv` | pass | `runs/sw_hw_control/2026-07-11_fix_execution/` | S=1 full-run K/V/Q preload。 |
| T006 | single_start_full_run | P0 | sw-driver | unittest trace | 0 | `python -m unittest src.sw.tests.test_sw_hw_control_driver` | pass | `runs/sw_hw_control/2026-07-11_fix_execution/` | mock 证明软件调用顺序，不算硬件通过。 |
| T007 | result_len_source | P0 | protocol | source scoreboard | 2 | `src/hw/rtl/tb/tb_sw_hw_control_source.sv` | pass | `runs/sw_hw_control/2026-07-11_fix_execution/` | 覆盖 pack/tlast/stall/odd flush。 |
| T008 | top_control_smoke | P0 | integration | top scoreboard | 3 | `src/hw/rtl/tb/tb_sw_hw_control_top_smoke.sv` | pass | `runs/sw_hw_control/2026-07-11_fix_execution/` | compute stubs/forced done，control-path only。 |
| T009 | illegal_config | P1 | boundary | assertion | 0 | 待实现：core/top TB | blocked | `runs/sw_hw_control/{date}_illegal_config/` | 错误码 `ERR_BAD_CFG`。 |
| T010 | backpressure | P1 | protocol | assertion | 42/43/44 | 待实现：axis TB | blocked | `runs/sw_hw_control/{date}_backpressure/` | 至少 3 seeds。 |
| T011 | reset_mid_transaction | P1 | boundary | assertion | 0 | 待实现：top/reset TB | blocked | `runs/sw_hw_control/{date}_reset/` | DMA outstanding 只做 RTL reset。 |
| T012 | cache_coherency_note | P1 | board | log review | 0 | 待实现：`python src/sw/tests/board_smoke.py` | blocked/waived | `runs/sw_hw_control/{date}_cache_coherency/` | 需板卡/bitstream。 |
| T013 | perf_counter_smoke | P2 | profiling | report parser | 0 | 待实现：CSR perf case | blocked | `runs/sw_hw_control/{date}_perf/` | 不作论文数据。 |
| T014 | boundary_lengths | P1 | boundary | scoreboard | 100 | 待实现：preload/core boundary case | blocked | `runs/sw_hw_control/{date}_boundary_lengths/` | 含 `S=65/96`。 |
| T015 | mac_start_closure | P1 | core-risk | core assertion | 0 | 待实现或交叉引用 core TB | blocked | `runs/sw_hw_control/{date}_mac_start/` | 补偿 T008 fake 风险。 |
| T016 | active_q_rows_full_tile | P1 | core-risk | core assertion | 0 | 待实现或交叉引用 core TB | blocked | `runs/sw_hw_control/{date}_active_q_rows/` | 防止 5-bit 截断。 |
| T017 | causal_toggle | P1 | core-risk | mask checker | 0 | 待实现或交叉引用 core TB | blocked | `runs/sw_hw_control/{date}_causal_toggle/` | 不由 fake smoke 签收。 |
| X001 | current_driver_mock | exec | current | asserts | 0 | `python src/sw/attn_driver.py` | executable | `docs/result/` | 本轮执行项。 |
| X002 | current_rtl_compile | exec | current | iverilog | NA | `iverilog -g2012 ...` | executable | `docs/result/` | 非功能 PASS。 |

## 10. 边界、异常与 waiver

| ID | 场景 | 触发条件 | 期望行为 | 归属 | 备注 |
| --- | --- | --- | --- | --- | --- |
| B001 | busy start | `start_ready=0` 写 start | `ERR_BUSY_START` sticky，不产生 accepted start | T002 | P0。 |
| B002 | illegal config | `seq_len=0`、`seq_len>MAX_SEQ_LEN`、position overflow | `ERR_BAD_CFG`，不得发出 local command | T009 | P1。 |
| B003 | early tlast | `tlast` before `stream_len` | `stream_error=1`，`ERR_STREAM_LEN` | T004 | P0。 |
| B004 | late tlast / overrun | 超过 `stream_len` 仍继续收 beat | overflow/stream_error sticky，`ERR_STREAM_LEN` | T004 | P0。 |
| B005 | wrong dest | `stream_dest` 非 K/V/Q | 不写 staging，`ERR_STREAM_DEST` | T004 | P0。 |
| B006 | output short/long | source output 与 `result_len` 不一致 | T007 已覆盖 exact/stall/odd flush；short/long error CSR 汇总留到 source/top 集成 | T007 | P0。 |
| B007 | AXIS backpressure | input/output ready 长 stall | payload stable，计数不重复不丢失 | T010 | P1。 |
| B008 | reset mid stream | sink/source active 时 reset | CSR/status/wr addr 回复位态 | T011 | P1。 |
| B009 | cache coherency | PS 写 buffer 后 DMA 读旧数据风险 | driver/platform 日志说明 flush/invalidate/coherent | T012 | P1 board。 |

Board-smoke waiver 字段：`blocker`、`影响范围`、`替代证据`、`关闭条件`。没有板卡、bitstream 或 DMA IP 时只能记录 waiver，不能声明板级 DMA/CSR 协同通过。

## 11. Evidence manifest schema

每个 `runs/sw_hw_control/{date}_{case}/manifest.json` 至少包含：

```json
{
  "case_id": "T001",
  "case_name": "csr_smoke",
  "result": "PASS|FAIL|BLOCKED|WAIVED",
  "scope": "rtl-sim|python-mock|board-smoke|static|compile-only",
  "claim": "control-path only",
  "cwd": "D:/projects/competition",
  "command": "<exact command>",
  "git": {"commit": "<hash or unknown>", "dirty": true},
  "tools": {"python": "<version or NA>", "iverilog": "<version or NA>", "vivado": "<version or NA>"},
  "seed": "<seed or NA>",
  "rtl_pkg": "src/hw/rtl/pkg/attn_pkg.sv",
  "artifacts": {"stdout": "<path>", "stderr": "<path>", "wave": "<path or NA>", "summary": "<path or NA>"},
  "notes": "<fake compute/mock/waiver explanation>"
}
```

## 12. 性能与资源记录

| ID | 指标 | 目标 | 实测 | 来源报告 | 判定 |
| --- | --- | ---: | ---: | --- | --- |
| P001 | CSR accepted start latency | 1-2 cycles from AXI write response to `start` pulse，具体以实现记录 | TBD | `runs/sw_hw_control/{date}_csr_smoke/` | blocked |
| P002 | sink sustained throughput | no-stall 时每 AXIS beat 接收 2 bf16 | TBD | `runs/sw_hw_control/{date}_stream_len/` | blocked |
| P003 | source result byte count | exactly `o_bytes` | TBD | `runs/sw_hw_control/{date}_source/` | blocked |
| P004 | cycles/mac_cycles CSR | 可读、start 清零、done 保持 | TBD | `runs/sw_hw_control/{date}_perf/` | blocked |
| P005 | staging resource estimate | Q/K/V full-run staging 是否能承载目标 shape | TBD | `runs/reports/{date}_resource/` | P1 risk |

资源风险说明：full-run staging 资源承载不阻塞控制链路 P0 mock/smoke，但必须作为 P1 风险跟踪；未有综合/资源报告前，不得宣称 target shape 可落地。

## 13. 准入与准出

准入：

- `docs/spec/interfaces.md` 第 10-13 节已冻结当前 Host/DMA/CSR/AXIS 合同。
- `docs/design/design_sw_hw_control.md` 已明确 `full_run_preload_then_start`、DMA trigger 归属、Q/K/V/O layout 和异常策略。
- `src/hw/rtl/pkg/attn_pkg.sv` 中 CSR 地址、stream dest enum、错误码可被 testbench 引用。
- RTL TB 放 `src/hw/rtl/tb/`；软件/driver tests 放 `src/sw/tests/`。
- 本地 P0 控制路径 T001-T008 已有 testbench/runner 并通过；板级 DMA/CSR 和真实 compute 数值仍需单独签收。

准出：

- P0 用例 T001-T008 全部 PASS，失败项有归因和关闭计划。
- CSR、AXIS、top 三层均有至少一个可复现实验命令和日志路径。
- `runs/sw_hw_control/{date}_{case}/` 中包含命令、seed、工具版本、关键 stdout/stderr、`manifest.json`；有波形时保存 `.vcd` 或工具原生波形。
- board-smoke 若暂不可跑，必须标为 P1 blocker/waiver，不能宣称板级 DMA 通过。
- 若 top smoke 使用 fake compute，只能签收控制链路；attention 数值正确性等待 core/golden 回归。
- T015-T017 或等价 core 回归必须关闭 fake compute 可能遮蔽的 `mac_start`、`active_q_rows=32` 和 `cfg_causal` 风险。

## 14. 失败跟踪模板

| ID | 用例 | 现象 | 复现命令 | 日志/波形 | 负责人 | 状态 | 关闭条件 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| F001 | `case_id` | `failure_summary` | `repro_command` | `log_or_wave_path` | `owner` | open | `close_criteria` |

## 15. Agent 分工与执行顺序

| Agent 角色 | 负责内容 | 产物 |
| --- | --- | --- |
| 验证/Profiling | 维护本文、回归矩阵、runs manifest、结果报告 | `docs/design/test_plan_sw_hw_control.md`、`docs/result/`、`runs/sw_hw_control/` |
| 架构/接口 | 审核测试是否覆盖 `interfaces.md` 合同；冻结错误码增强项 | 审核记录或接口 patch |
| RTL 实现 | 实现 testbench、assertion、top wrapper hook | `src/hw/rtl/tb/`、脚本 |
| Golden/模型 | 生成 deterministic Q/K/V pattern 和必要 golden O | `src/sw/tests/vectors/`、golden helpers |
| 软件/driver | 实现 pytest mock/board smoke、PYNQ cache coherency 记录 | `src/sw/tests/`、board smoke log |
| 审核 | 对测试方案和后续 testbench 做准出审查 | `docs/review/*_audit_*.md` |

建议执行顺序：

1. 先跑当前可执行 X001/X002，确认 driver mock 和 RTL compile 基线。
2. 已完成 T001/T002 CSR smoke 与 busy start。
3. 已完成 T003/T004 AXIS sink route/len。
4. 已完成 T006 unittest driver mock full-run API。
5. 已完成 T007 source result len。
6. 已完成 T005 full-run preload integration。
7. 已完成 T008 top control smoke。
8. 实现 T009-T017 扩展边界、board、profiling 和 core-risk closure。

## 16. 审核关注点

- 测试是否明确区分“控制链路通过”“Python mock 通过”“compile-only 通过”“fake compute smoke”“真实 core 通过”和“attention 数值通过”。
- 是否仍存在 per-tile Q start、CSR 触发 DMA、top 常量绑线等被审核否决的旧语义。
- P0 是否覆盖 CSR、AXIS sink、AXIS source、driver、top integration 五个层级。
- 每个失败项是否有复现命令、日志路径和关闭条件。
- 任何板级结论是否有 `runs/` 证据，而不是来自 mock 或肉眼波形观察。
