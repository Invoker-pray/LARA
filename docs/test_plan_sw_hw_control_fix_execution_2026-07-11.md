# 测试结果报告：sw_hw_control 反馈整改后复执行

## 1. 基本信息

| 项目 | 内容 |
| --- | --- |
| 报告名称 | `sw_hw_control_fix_execution_2026-07-11` |
| 输入报告 | `docs/result/test_plan_sw_hw_control_result_2026-07-11.md` |
| 对象/模块 | `sw_hw_control` / Host-DMA-CSR-AXIS-top-core control path |
| 执行日期 | 2026-07-11 |
| 执行人 | Codex |
| 结果目录 | `runs/sw_hw_control/2026-07-11_fix_execution/` |
| 总结论 | PASS for local control-path P0 / 非板级、非数值签收 |

## 2. 本轮整改内容

| 原发现 | 本轮处理 |
| --- | --- |
| F001 缺 P0 testbench/runner | 新增 CSR、sink、source、preload、top smoke TB，并新增 driver unittest。 |
| F002 top compile blocker | 当前 `attn_top.v` 已隔离 Phase 1 不使用的 `rope_engine` 实例；top compile 返回 0。 |
| F003 缺 `ERR_RESULT_LEN` | 新增 `ERR_RESULT_LEN = 8'h12`，driver mirrored constant 为 `0x12`。 |
| F004 driver 缺 trace | `MockMMIO` / `MockDMAChannel` 增加 trace；新增 `src/sw/tests/test_sw_hw_control_driver.py`。 |

## 3. 执行命令与结果

| ID | 命令 | 结果 | 证据 |
| --- | --- | --- | --- |
| R001 | `python -m unittest src.sw.tests.test_sw_hw_control_driver` | PASS | `driver_unittest.log` |
| R002 | `iverilog ... tb_sw_hw_control_csr.sv` + `vvp` | PASS | `csr_compile.log`、`csr_vvp.log` |
| R003 | `iverilog ... tb_sw_hw_control_sink.sv` + `vvp` | PASS | `sink_compile.log`、`sink_vvp.log` |
| R004 | `iverilog ... tb_sw_hw_control_source.sv` + `vvp` | PASS | `source_compile.log`、`source_vvp.log` |
| R005 | `iverilog ... tb_sw_hw_control_preload.sv` + `vvp` | PASS | `preload_compile.log`、`preload_vvp.log` |
| R006 | `iverilog ... tb_sw_hw_control_top_smoke.sv` + `vvp` | PASS | `top_smoke_compile.log`、`top_smoke_vvp.log` |
| R007 | `iverilog -g2012 -tnull -s attn_top ...` | PASS with warnings | `top_compile.log` |

`manifest.json` 中所有退出码为 0。

## 4. 用例状态更新

| ID | 名称 | 原结果 | 本轮结果 | 说明 |
| --- | --- | --- | --- | --- |
| T001 | `sw_hw_control_csr_smoke` | BLOCKED | PASS | CSR config/readback、accepted start、sticky done/stream_error、clear_status。 |
| T002 | `sw_hw_control_busy_start` | BLOCKED | PASS | busy start 不产生新 start，错误码为 `ERR_BUSY_START`。 |
| T003 | `sw_hw_control_stream_dest_route` | BLOCKED | PASS | K/V/Q dest pass-through 和 bf16 low/high 顺序。 |
| T004 | `sw_hw_control_stream_len` | BLOCKED | PASS | exact、early tlast、missing tlast、bad dest 均覆盖。 |
| T005 | `sw_hw_control_full_run_preload` | BLOCKED | PASS | S=1 full-run K/V/Q preload，写使能互斥，byte count 匹配。 |
| T006 | `sw_hw_control_single_start_full_run` | PARTIAL PASS | PASS for mock trace | 证明 driver 只执行一次 full-run start；仍不代表硬件通过。 |
| T007 | `sw_hw_control_result_len_source` | BLOCKED | PASS | source pack/tlast/stall/odd flush 已覆盖。 |
| T008 | `sw_hw_control_top_control_smoke` | BLOCKED | PASS for control path | 使用 compute stubs 和 forced local completions；验证 preload -> start -> core loop -> CSR done。 |
| T008 compile gate | `attn_top` compile | FAIL | PASS compile-only | 真实 compute 文件仍有 Icarus shortreal warning，不影响 control-path stub smoke。 |

## 5. 仍未关闭项

| 编号 | 等级 | 事项 | 下一步 |
| --- | --- | --- | --- |
| O001 | P1 | Board-level PYNQ DMA/CSR smoke 未执行 | 等 bitstream/platform ready 后执行并归档。 |
| O002 | P1 | T008 使用 compute stubs/forced local completion | 真实 compute 数值正确性由 core/MAC/softmax/output 回归关闭。 |
| O003 | P1 | top compile 仍有既有 `shortreal`/Icarus warning | 后续计算模块综合/仿真路线单独处理。 |

## 6. 可声明范围

```text
本轮结论：PASS for local control-path P0
可声明范围：T001-T008 本地控制路径测试均有可执行入口并通过；top 当前 compile gate 返回 0；ERR_RESULT_LEN 已冻结。
不可声明范围：板级 DMA/CSR 协同通过、真实 compute 数值正确、attention 端到端数值正确、PYNQ cache coherency 实测通过。
```