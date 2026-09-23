# LARA 设计与验证坑位记录

> 本文件记录项目实际踩过、并已付出排查代价的坑。改架构参数、写新 TB、
> 改 CSR 或计数器之前先对照本清单，避免重蹈覆辙。
> 维护规则：每次因为"想当然"损失超过一小时的教训，都应补一条进来。

## 1. 架构参数变更必须全面清扫硬编码期望

**坑**：v2.6 把 `TILE_SPLIT_FACTOR` 从 2 改为 16（timing closure 需要），
RTL 本身正确（板上 bit-exact 验证），但一批 TB/脚本的期望没有跟着改，
导致完整回归 15 项长期红：

- softmax 周期上限 630（split=2 实测 ~626）→ 实测 722 才对；
- softmax A/B 脚本 grep `total=626`；
- attn_tile TB 的双相位激励（split=2 的 8+8 列窗口）不适用于 1 列/相位；
- phasea_overlap TB 的 20000 周期 round 预算；
- A/B 脚本的百分比改进断言（split=16 下 Phase-A 生产主导，softmax-overlap
  收益从 ≥15% 缩到 ~2%，streaming-PV 从 ≥10% 缩到 ~4.5%）。

**规则**：改任何 `attn_pkg` 里的架构参数（tile 尺寸、split、流水级数）
时，必须 `grep -rn` 全部 TB/脚本中的硬编码周期数、百分比、相位数，并
逐一重新校准或参数化。百分比断言优先改为非回归断言 + 实测值打印。

## 2. TB 服务循环必须与 driver 语义一致

**坑**：`tb_attn_top_real_request` 的 descriptor 模式服务循环只在
`kv_load_req && q_load_req` 同时 pending 时发批，head 切换产生的孤 Q
请求走了 legacy `send_stream` 路径——而 desc 模式下 sink 只在 descriptor
段活跃时拉高 `tready`，导致 FULL_REAL DESC 模式 5ms 超时死锁。
真实 driver 无此问题（`_transfer` 在 desc 模式下走单段批）。

**规则**：给 transport 模式写 TB 服务逻辑时，逐行对照 `sw/attn_driver.py`
的实际发送路径（legacy 单发 / descriptor 批 / inband 预打包），不要凭
"请求出现了就发数据"的直觉写。

## 3. 行为级与综合级模型的可见性契约不同

**坑**：`attn_tile` 行为级分支 `block_out` 显示的是采样前的累加器状态
（寄存行为模型），综合分支显示的是本拍活跃窗口的新值，且
`block_acc_bits` 的提交滞后一拍、clear 后 `acc_base` 有意零保持一拍
（防止 split0 清除未提交时 split1 采到旧值）。按同一套期望写两分支的
比对必然错（曾 80 errors）。

**规则**：模块 TB 要先从 RTL 推导每个观察信号在两个模型下各自的可见
时序（画边沿时间线），再写期望；`ifndef SYNTHESIS` 分支的语义差异要在
TB 注释里显式写明。

## 4. 调度器形态变化会让"等待型"检查点永远不触发

**坑**：`tb_attn_top` 家族曾在 `PA_WAIT_P && held_valid` 处检查 softmax
上下文重载。split=16 后流水 softmax（~722 cycles/block）远快于 Phase-A
生产（2048 cycles/block），生产者永远不用等 softmax，该状态不出现，
检查点静默失效（表现为 "did not observe"，不是数值错误）。

**规则**："did not observe" 类失败优先怀疑检查点时序前提已过时，用
git worktree 在干净基线复现来区分 pre-existing 与新回归；检查点应挂在
事件的确定性发生处（如 `sm_state_load`——上下文被采样的那一拍），
而不是某个可能消失的中间状态。

## 5. Q bank 的 ready 位与 sticky done 生命周期

**坑**（历史上板踩过，代码注释已留档，此处汇总）：

- head/group 边界同 bank 重载时，writeback 完成后必须清 `q_bank_ready`，
  否则 ST_Q_INIT 看到陈旧 ready 直接跳过重载（输出错数据）。
- `o_write_done_sticky` 必须在下一个 head 的 `mac_start` 清除，否则
  obuf bank 选择滞留在 writeback bank，L=1 出现交替全零 head。
- 任何 bank 完成信号（ready/done）都必须伴随 tag（group/head/tile），
  只有"ready 且 tag 匹配"才可消费——延迟/乱序填充会 otherwise 欺骗
  消费端（v3.1.0 已实现 Q 侧 tag 保护）。

**规则**：新增任何 buffer 完成握手时，同步设计 tag + 清除时机 + sticky
生命周期，并在 TB 里包含 head/group 边界与同 bank 重载场景。

## 6. 观测计数器的口径必须写进文档

**坑**：`buffer_wait_cycles` 统计的是 Q fill outstanding 的全部周期，
包含与计算重叠的部分——把它当纯 stall 报告会得出错误结论。
`transport_stall_cycles` 才是 K/V DMA 等待份额（≈stall_cycles 的 K/V 部分）。

**规则**：每个新增性能计数器在 `attn_pkg`/design doc 里写清"计的是
什么的周期、包含哪些重叠"，driver 字段命名（`*_wait` vs `*_stall`）
与口径一致；板测报告分层引用。

## 7. CLI/脚本默认行为不要用递归实现

**坑**：`python_godel/attention_golden.py` 的"无参数默认跑 self-test"
通过递归 `main()` 实现，而每次递归重新解析 argv，flag 永不生效 → 无参数
运行必然 `RecursionError`（v3.4.0 修复）。

**规则**：默认值在解析参数后立即应用到 args 对象上，控制流线性走完，
不用递归表达"回到开头"。

## 8. iverilog 对 sized decimal literal 拼接的宽度 bug

**坑**：iverilog（-g2012）把 `{18'd0, ...}` 中的 `18'd0` 按 16 位处理，
导致整个拼接右移、字段错位（`CSR_PREFETCH_STATUS` 读回 0x85 而非
0x205）。最小复现：`w = {18'd0, 8'hAB, 6'b0};` 得 0x2AC0。VCS/Verilator
不受影响，因此该 bug 只在 iverilog 快速门禁（tb_sw_hw_control_csr 等）
暴露。

**规则**：状态字拼接优先用显式移位/`32'()` 扩展写法，避免非 2 的幂
宽度的 sized decimal 零填充参与拼接；iverilog 结果与 VCS 不一致时先
怀疑工具差异（最小用例隔离），再怀疑 RTL。

## 9. 请求可见性与 host 服务模型必须联合设计（协议死锁）

**坑**（v3.5 K/V ownership v1 踩过两次）：

1. **释放条件挂在中间里程碑上**：ownership 释放（`kv_reads_done`）最初只检查
   "最后 head + 最后 KV tile"，漏了"最后 Q tile"——L=128 每 head 有 4 个
   tile，tile 0 排空就放行重填，早发的下一组 K/V 直接覆盖 tile 1/2/3
   还要读的数据。L=1 单 tile 全过，多 tile 才暴露（board case 首错在最后
   head 的第二个 tile 起始处）。**修复：加 `final_q_tile_active`。**

2. **门控数据流而非请求可见性 = 死锁**：早发请求立即对 host 可见 +
   sink 在 ownership 未释放时压低 `tready` 的组合，在单线程 KV 优先的
   host（TB 服务循环和 Python driver 都是）上形成环：host 阻塞在 K/V
   发送→最后 head 剩余 tile 的 Q 请求无人服务→最后一个 tile 永不排空→
   ownership 永不释放。L=1 因无后续 Q 请求而侥幸通过。
   **修复：请求在 RTL 内保留（`kv_load_req = pending && 可重填`），
   bank 能合法重填时才对 host 可见；host 永远不会在错误时刻开始发数据。**
   tready 门控降级为安全网。

3. **请求可见性必须覆盖整个服务窗口，而不只是发起窗口**：可见性条件
   最初只写 `IDLE || (ACTIVE && reads_done)`，漏了 `FILLING`——K 段数据
   开始流动后请求掉 0，而 in-band 预打包流的**每个段头消费都要求请求为
   高**（`inband_request_ready`），V 段头从此不被消费、填充永不完成，
   group 0 即死锁（`+INBAND +KV_PREFETCH`，零输出）。legacy/desc 不受
   影响是因为 host 看到一次请求就连发 K+V，不依赖填充期的请求电平。
   **修复：`kv_req_visible = IDLE || FILLING || (ACTIVE && reads_done)`。**

**规则**：任何"早发请求 + 资源忙时背压"的协议，必须回答两个问题：
(a) host 在等待期间还能服务别的请求吗——若 host 单线程且优先级固定，
门控请求可见性而非数据流；(b) **每一种 transport 在请求的哪个电平窗口
内消费它**——in-band 预打包流在填充中途还要消费后续段头，可见性窗口
必须横跨整个服务过程。ownership 释放条件必须锚定"最后一个消费者完成"
（所有 tile/head 维度取齐），而不是任一里程碑信号。

## 10. 上板问题必须先在仿真复现

（流程规矩，源自 handle.md，重申）板上出现错误时：先在 VCS 用相同
case 数据稳定复现，再对 RTL 做"手术刀"式修改；禁止未过 python golden +
Verilator + VCS 三层门禁就改板级结论。Python golden 无参数入口为
`attention_golden.py --test-all`（或裸跑 self-test）。
