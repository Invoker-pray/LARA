# 测试结果报告：sw_hw_control 测试方案修订后执行

## 1. 基本信息

| 项目 | 内容 |
| --- | --- |
| 报告名称 | `sw_hw_control_plan_execution_2026-07-11` |
| 对象/模块 | `sw_hw_control` / Host-DMA-CSR-AXIS-top-core control path |
| 对应测试方案 | `docs/design/test_plan_sw_hw_control.md` |
| 审核依据 | `docs/review/test_plan_sw_hw_control_audit_2026-07-11.md` |
| 执行日期 | 2026-07-11 |
| 执行人 | Codex |
| 代码状态 | git `e2a9707`，工作区已有未提交变更；本报告不代表 clean tree 回归 |
| 结果目录 | `docs/result/`；compile 产物在 `runs/sw_hw_control/2026-07-11_plan_execution/` |
| 总结论 | BLOCKED / PARTIAL PASS |

## 2. 执行环境

| 项目 | 内容 |
| --- | --- |
| 平台 | Windows PowerShell，本地仿真/静态执行 |
| Python | Python 3.13.9 |
| RTL 工具 | Icarus Verilog 12.0 devel `s20150603-1539-g2693dd32b` |
| Bitstream/板卡 | NA，本轮未执行 PYNQ/KV260 board smoke |
| 随机种子 | X001 使用 driver 内置 zeros mock；X002 compile-only 无 seed |

## 3. 执行命令与结果

| ID | 命令 | 结果 | 关键输出/证据 |
| --- | --- | --- | --- |
| X001 | `python src\sw\attn_driver.py` | PASS | `attn_driver full-run mock self-test PASSED` |
| X002a | `iverilog -g2012 -I src\hw\rtl\pkg -o runs\sw_hw_control\2026-07-11_plan_execution\axi_lite_compile.vvp src\hw\rtl\pkg\attn_pkg.sv src\hw\rtl\axi\attn_axi_lite_slave.sv` | PASS | 生成 `axi_lite_compile.vvp`；仅有 `unique/unique0 qualities are ignored` 工具提示 |
| X002b | `iverilog -g2012 -I src\hw\rtl\pkg -o runs\sw_hw_control\2026-07-11_plan_execution\axi_sink_compile.vvp src\hw\rtl\pkg\attn_pkg.sv src\hw\rtl\axi\attn_axi_stream_sink.sv` | PASS | 生成 `axi_sink_compile.vvp` |
| X002c | `iverilog -g2012 -I src\hw\rtl\pkg -o runs\sw_hw_control\2026-07-11_plan_execution\axi_source_compile.vvp src\hw\rtl\pkg\attn_pkg.sv src\hw\rtl\axi\attn_axi_stream_source.sv` | PASS | 生成 `axi_source_compile.vvp` |
| X002d | `iverilog -g2012 -I src\hw\rtl\pkg -o runs\sw_hw_control\2026-07-11_plan_execution\attn_top_compile.vvp ... src\hw\rtl\attn_top.v` | FAIL | 12 elaboration errors，集中在 `rope_engine.sv` function output args、`bf16_mac.sv` `$bitstoshortreal/$shortrealtobits` 和 Icarus 对部分 SystemVerilog construct 支持不足 |

## 4. 用例结果

| ID | 名称 | 优先级 | 结果 | 说明 |
| --- | --- | --- | --- | --- |
| T001 | `sw_hw_control_csr_smoke` | P0 | BLOCKED | 缺 `src/hw/rtl/tb/tb_sw_hw_control_csr.sv` 或等价 runner，未执行功能检查。 |
| T002 | `sw_hw_control_busy_start` | P0 | BLOCKED | 缺 CSR TB case，未验证 `ERR_BUSY_START`。 |
| T003 | `sw_hw_control_stream_dest_route` | P0 | BLOCKED | 缺 sink/top route TB，未验证 K/V/Q 写使能互斥。 |
| T004 | `sw_hw_control_stream_len` | P0 | BLOCKED | 缺 stream len TB，未验证 `ERR_STREAM_LEN` / `ERR_STREAM_DEST`。 |
| T005 | `sw_hw_control_full_run_preload` | P0 | BLOCKED | 缺 preload integration TB，未验证 staging pattern。 |
| T006 | `sw_hw_control_single_start_full_run` | P0 | PARTIAL PASS | 当前 driver `_self_test` 通过；完整 pytest mock trace 尚未实现。 |
| T007 | `sw_hw_control_result_len_source` | P0 | BLOCKED | source module compile-only 通过，但缺 result_len/tlast TB。 |
| T008 | `sw_hw_control_top_control_smoke` | P0 | BLOCKED | 整套 top compile 失败，且缺 top smoke TB。 |
| T009-T017 | P1/P2 扩展项 | P1/P2 | BLOCKED | 需要后续 TB、pytest、board smoke 或 core 回归补齐。 |

## 5. 关键发现

| 编号 | 等级 | 现象 | 影响 | 关闭条件 |
| --- | --- | --- | --- | --- |
| F001 | P0 | 完整 P0 测试脚本/testbench 尚不存在。 | 不能执行 T001-T008，也不能签收控制链路。 | 增加 `src/hw/rtl/tb/tb_sw_hw_control_*.sv` 和 `src/sw/tests/test_sw_hw_control_driver.py`。 |
| F002 | P0 | `attn_top.v` 全量 Icarus compile 失败。 | T008 top smoke 无法进入仿真。 | 修复/隔离 `rope_engine.sv` function 参数、`bf16_mac.sv` real conversion，或提供支持这些 construct 的仿真路线。 |
| F003 | P1 | `ERR_RESULT_LEN` 尚未在 `attn_pkg.sv` 定义。 | T007 short/long result 只能用 scoreboard fail，不可用 CSR 错误码签收。 | 冻结 result length 错误码或在接口中明确替代 checker。 |
| F004 | P1 | driver 当前只有 `_self_test`，没有可审计 mock MMIO/DMA trace。 | T006 只能 partial pass，无法证明完整调用顺序。 | 新增 pytest，断言 configure/clear/preload K/V/Q/result_len/start/wait/recv 顺序。 |

## 6. 可声明范围

```text
本轮结论：BLOCKED / PARTIAL PASS
可声明范围：driver full-run mock self-test 通过；AXI-Lite CSR、AXIS sink、AXIS source 三个控制适配模块 compile-only 通过。
不可声明范围：P0 控制链路功能通过、top smoke 通过、真实 core 通过、attention 数值正确、板级 DMA/CSR 协同通过。
主要风险：缺 testbench/runner；top 全量 compile 失败；结果长度错误码未冻结。
下一步：优先实现 T001/T002 CSR TB、T003/T004 sink TB、T006 pytest mock trace，并修复/隔离 top compile blocker。
```
