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

## 11. PYNQ 3.0.1 的 HWH 元数据缓存与 IRQ parser 兼容性

**坑**：v3.6.0 上板后，RTL 已将 `accel/irq` 接到 `pl_ps_irq0`，HWH 中也
明确包含 `accel/irq`，但 `Interrupt("accel/irq")` 报：
`No Pin of name accel/irq found`。问题分成了三个相互叠加的 PYNQ 兼容点：

1. PYNQ 3.0.1 的 metadata cache 只用 `.bit` 内容的 SHA-1 命中，未绑定
   `.hwh/.xsa` 元数据来源、parser 版本或本地补丁版本。同一 `.bit` 曾经经由
   错误的 sibling `.xsa` 路径解析后，旧 `_current_metadata.pkl` 会继续被复用。
   这不是文件名弱哈希；实际函数是对 `.bit` 内容计算 SHA-1。
2. 即使 HWH 优先分支补丁生效，无缓存路径仍调用
   `RuntimeMetadataParser(Metadata(input=<file>.hwh))`。对本项目 HWH，
   `RuntimeMetadataParser.interrupt_pins` 为空，而传统 `HWH` parser 能正确得到
   `accel/irq` 和 `raw_irq=121`。UG1085 的 `PL_PS_Group0` 映射确认 IRQ 121
   属于 `pl_ps_irq0` bit 0。
3. 传统 `_HWHUltrascale` parser 没有新 parser 使用的
   `refresh_hierarchy_dict()` 和 `systemgraph` 属性。只替换 parser 类型还会
   依次触发这两个 AttributeError。

**稳定定位过程**：同一份 `lara_attention.hwh` 上，板上诊断结果为：

```text
legacy HWH parser: accel/irq, raw_irq=121
RuntimeMetadataParser: interrupt_pins={}
```

清除 `global_pl_state.json` 与 `_current_metadata.pkl` 后，将 `.bit + .hwh`
路径切换到传统 parser，并补齐兼容字段：

```python
if not partial and hasattr(parser, "refresh_hierarchy_dict"):
    parser.refresh_hierarchy_dict()
if not hasattr(parser, "systemgraph"):
    parser.systemgraph = None
```

随后 `parser.interrupt_pins`、`Overlay.interrupt_pins` 和 `PL.interrupt_pins`
均包含 `accel/irq`，且 `raw_irq=121`。最终 `LARA_REQUEST_MODE=irq` 的
KV260 L1 smoke test 通过，证明 metadata、PYNQ Interrupt、Linux IRQ 路径和
RTL 顶层 IRQ 已连通。

**规则**：

- PYNQ 3.0.1 的 `.bit/.hwh/.xsa` 部署必须优先使用 HWH；不要只清 cache 而
  保留 `RuntimeMetadataParser`。
- 离线安装脚本必须在干净安装后自动完成 HWH 优先、传统 HWH parser、条件
  hierarchy refresh 和 `systemgraph=None` 四项处理。
- 每次更换 `.bit/.hwh/.xsa` 或 PYNQ parser 补丁后，先清理两个全局 cache，
  再用新 Python 进程检查 `accel/irq` 与 `raw_irq=121`，最后才运行 IRQ
  smoke test。
- `No Pin of name ...` 属于 PYNQ metadata 层；`Could not find UIO device ...`
  才进入 Linux UIO/GIC 注册层；不要把这两类错误混为 RTL IRQ 错误。

## 12. 性能矩阵必须先固定比较层级和控制模式

**坑**：同一 bitstream 的 `poll`、`irq`、descriptor 和 prefetch 不是同一
层级的变量。若把 PL transaction、host-to-host E2E、CPU wall time 和
`core_active` 混成一个“加速比”，会把控制路径变化误报成 RTL 算力提升。
2026-09-25 的 KV260 结果明确显示：

- `poll + descriptor + prefetch off` 相对 v2.6 的 q31/kv7 可比 10 个 case，
  PL transaction 几何平均约改善 10.5%，host E2E 约改善 9.5%；
- 修复 UIO 权限、UIO re-arm 和真实 PYNQ 解释器后，同一 bitstream 的
  `irq + descriptor + prefetch off` 相对 poll 仍反而变慢约 2.00%（PL）和
  5.96%（E2E）；因此 IRQ 功能修复不等于性能收益，poll 仍是当前性能默认路径；
- `irq + descriptor + prefetch descriptor` 相对 IRQ/off 变慢约 1.69%（PL）和
  1.57%（E2E），当前不能写成 prefetch 收益；
- 旧的约 32% 数据来自 IRQ 未真实唤醒时的 timeout + CSR fallback，只能作为
  环境故障诊断证据，不能与真实 IRQ A/B 混合为性能结论。

**规则**：性能报告必须至少分成四层：

1. PL counter-derived transaction time；
2. `total - stall` 的 controller/core-active time；
3. driver host-to-host attention time；
4. 独立 CPU baseline wall time。

每次 A/B 只改变一个变量，固定 bitstream、case hash、clock、CPU affinity、
warmup/repeats 和 buffer/Overlay 计时边界。`buffer_wait` 是可重叠等待观测，
不能直接当作纯 stall；CPU baseline 也不能扩展成完整 Transformer latency。

## 13. PYNQ IRQ 能工作不等于 IRQ 已经带来性能收益

**坑**：IRQ smoke 通过只能证明 RTL → HWH → PYNQ → Linux UIO 的功能链路
连通。当前 driver 每次无请求时通过 asyncio event loop 等待 level IRQ，板上
矩阵显示它比 20 us polling 更慢，尤其在 L=1/16 的请求固定开销占主导场景。

**规则**：IRQ 优化必须单独记录每次 IRQ wait、IRQ service、request-service
和 DMA 时间；在优化完成前保留 poll 回退，并把 `auto` 的实际解析模式写入
profile。候选方向应先评估阻塞 UIO fd、DONE/request 中断合并或减少每请求一次
event-loop 调度，再决定是否让 IRQ 成为性能默认路径。

## 14. v3.6.1 IRQ 修订：不要在同步 request loop 中反复驱动 asyncio

**诊断**：PYNQ 3.0.1 的 `Interrupt.wait()` 通过 `asyncio.Event` 和 UIO
`add_reader()` 工作。v3.6.0 driver 每个 PL request 都调用
`run_until_complete(asyncio.wait_for(...))`，因此 IRQ 只替换了 20 us polling，
没有减少 DMA、CSR 或 Python request-service 工作。若当前 event loop 已经运行，
旧代码还会切换到新 loop，而 UIO reader 仍在旧 loop 上，可能把正常 IRQ 退化成
2 ms timeout + CSR fallback。

**v3.6.1 修复**：profile 增加 `irq_wait_count`、`irq_wakeup_count`、
`irq_timeout_count`、`irq_csr_fallback_count`、`irq_wait_total_ms`、
`irq_wait_max_ms`、`irq_service_gap_ms` 和 `irq_coalesced_requests`。默认 IRQ
路径使用 direct blocking UIO fd；`LARA_IRQ_WAIT_MODE=async` 仅保留为旧路径
对照。`hybrid` 模式先做 `LARA_IRQ_SPIN_US` 短窗口 CSR polling，再进入
blocking UIO。

**level IRQ 规则**：UIO `read(2)` 后必须保持 IRQ disabled，直到本次 request 的
DMA service 完成；下一次进入 wait 前再 write(2) re-arm。level request 在 DMA
期间保持有效，过早 re-arm 会形成 interrupt storm 或重复 wakeup。

**验证规则**：任何新 IRQ 实现必须先运行
`+IRQ_PROTOCOL +IRQ_LATENCY_CYCLES=0/100` 的 VCS A/B，并确认 latency 增加只
增加 `buffer_wait/transport_stall`、不改变 `core_active` 和 bit-exact 输出，
再进行 KV260 实测。VCS license 不可用时只能记录为 blocked，不能写成 PASS。
## 15. v3.6.1 板上 IRQ profile PASS 不等于 IRQ 真正唤醒

v3.6.1 新 bitstream 的 q31/kv7 与 q3/kv3 全序列长度功能矩阵均通过，且
profile 的 bitstream SHA256 与新构建一致。但是 profile 同时显示：

```text
request_mode=irq
irq_wait_mode=hybrid
irq_wakeup_count=0
irq_timeout_count=irq_wait_count
irq_csr_fallback_count=irq_wait_count
```

这表示 request 在 timeout 后通过 CSR fallback 被发现和服务，不能把功能 PASS
解释为 IRQ 性能已经生效。当前板上还观察到 `/dev/uio4` 为 `root:root`、
`0600`，sysfs 节点为 `name=fabric`、`event=5`、`uio_pdrv_genirq`；这使
普通 `ubuntu` 用户无法直接打开设备成为首要排查方向，但在确认
`pynq.interrupt.get_uio_irq(raw_irq=121)` 的实际路径前，不能把根因写死为权限。

后续检查顺序固定为：

1. 记录 `raw_irq=121`、DTBO `fabric` 节点、`/dev/uio*`、sysfs event 和设备权限；
2. 在用户态确认 PYNQ 返回的 UIO 路径，并用最小 request 检查 read 是否阻塞/唤醒；
3. 若为权限问题，优先修复 DTBO/udev 的持久权限规则（当前离线安装器使用
   `SUBSYSTEM=="uio", ATTR{name}=="fabric", GROUP="video", MODE="0660"`），
   不能把手工 `chmod` 当最终方案；
4. 修复后要求 `irq_wakeup_count>0`、timeout 不再占主导，再进行 poll/IRQ 性能 A/B；
5. 在此之前保留 poll 作为正式性能基线，不修改 RTL 以掩盖 host/UIO 环境问题。

UIO fd 的新实例也必须显式 `write(1)` re-arm。不要假设上一次进程退出后
`uio_pdrv_genirq` 仍处于 enabled 状态；否则 `/proc/interrupts` 可能继续增加，
但当前 fd 的 `poll/read` 不会唤醒，最终表现为 timeout/CSR fallback。

此外，driver 的 IRQ capability 检查必须与 overlay IP 命名兼容。当前构建的
PYNQ overlay 可能暴露 `attn_accel_0` 而不是 `accel`；初始化 DMA/MMIO 时已经
支持两个名称，`_prepare_irq()` 也必须使用同样的 capability 判定，否则显式
`LARA_REQUEST_MODE=irq` 会在 UIO 已可用时提前报“requires real hardware”。

## 16. "IRQ 一定降低 CPU 占用"是未验证预期——必须用进程 CPU 时间证伪

2026-10-04 用 `/usr/bin/time -v` 对 poll/IRQ/busy-poll/spin 七组同参数
测量：所有组 user+sys CPU 时间在 ±1% 内相同。根因是本项目 poll 路径
本来就用 20 µs `time.sleep` 让出 CPU，与 IRQ 的 UIO 阻塞等待一样不消耗
CPU；busy-poll（sleep=0）也只多 ~1%。因此"IRQ 是低 CPU 占用模式"在本
driver 形态下不成立——**IRQ 的可量化优势只有调度行为**（自愿上下文切换
-58.6%、显式 polling sleep 21,350→0），且代价是 E2E 慢 5–8%。

**规则**：宣称任何"降低 CPU 占用"前，必须直接测进程 CPU 时间
（`/usr/bin/time -v` 或 perf stat），不能用"唤醒次数变少"或"不再忙轮询"
推断；先检查对照的 poll 实现本身是否忙轮询——sleep-poll 与 IRQ 的 CPU
时间天然相同。性能最优的请求等待方式要以实测几何平均为准（本轮实测
busy poll 最快，PL_TX -4.57%）。

## 17. host-bound 循环的优化必须先定性瓶颈，PL 侧指标改善不等于 E2E 改善

2026-10-04 Q-arena 实验：把每请求 ~230 µs 的 numpy 转换/拷贝/flush 从请求
循环挪到 START 之前的 CMA 预装载。PL 侧目标全部达成（q_dma_setup -52%、
PL transaction geo -9.31%），但 host E2E 反而 +4.24%。根因：L1 的请求循环
是 host-bound（service 17.4 ms ≈ PL_TX 17.6 ms），挪动计算位置不减少 host
总工作量，还新增一次 arena 拷贝；PL 等待的缩短被 host 串行时间吞掉。

**规则**：优化请求服务路径前，先比较 host service 时间与 PL transaction
时间——若 host ≥ PL，唯一有效的方向是减少 host↔PL 往返次数或 host 总工作
量（如 in-band 单传输把 40 次往返折成 1 次，E2E -14.55%），而不是把 host
工作在时间轴上重新安排。PL 侧计数器（stall/buffer_wait/q_dma_setup）的
改善只有在 PL-bound 场景才转化为 E2E。

## 18. 半成品编辑会静默改变默认行为——功能测试不查性能

v3.6.2 的 staging 门控编辑分两步执行，第二步断言失败导致第一步的调用点
替换**整体未写盘**，但 env 解析部分已写入——结果 `_q_staging_enabled`
有值却无人消费，staging 在所有非 in-band 事务上无条件执行。功能全绿
（bit-exact、45 单测），只有板上 `driver_setup_ms` 0.2→12.4 ms 暴露了它。

**规则**：(1) 多段 python 编辑脚本必须单事务化（先全部 assert 再统一
写盘），或写盘后立即 grep 验证每个门控点真实存在；(2) 新增开关必须配
"默认 off 时不产生副作用"的回归单测（本例补了 `_q_arena_staged` 两态
断言）；(3) profile 里的 setup 类计时段（driver_setup_ms 等)每次板测
A/B 都要扫一眼基线漂移。

## 19. 验收门 plusarg 必须真正激活过一次才算覆盖

v3.1 时代给 loop_control TB 加的 `+HEAD_GROUP_PREFETCH` 门控检查，直到
v3.7 实现该功能才第一次带 plusarg 运行——首版实现静默失败（`kv_tile_last`
在 NORMALIZE/WRITE_O 未赋值，预取条件恒 0），而默认模式跑全回归 28/28
全绿。**规则**：给 TB 加 plusarg 门控的同时，必须在同一提交里用该 plusarg
实际跑一次并记录 PASS；CI 若只跑默认模式，门控检查等于不存在。同时，
验收条件要与被验行为严格对应（head 预取检查要求 last Q tile，防止
tile 预取在非最后 tile 触发时冒充通过）。
