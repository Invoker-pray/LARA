# Vivado 增量布线恢复说明

> 当前状态（2026-08-02）：当前 develop 的 v2.5 P4 streaming/fused-PV
> 已由 matching clean build 的 Explore route 签收 WNS `+0.021 ns` /
> WHS `+0.010 ns`；accepted routed DCP 位于
> `checkpoint/v2.5-p4-architecture-dse/candidate1-streaming-pv/explore-route/`。
> 该 screening 没有生成 `.bit/.hwh/.xsa`；板测前应运行
> `hw/scripts/export_p4_explore_deploy.sh`。默认 route 的 WNS `-0.110 ns`
> 不属于 signoff。任何后续 RTL 修改都必须重新生成 matching physopt
> checkpoint 后才能使用恢复脚本。

## 1. 背景

完整的 KV260 Vivado 构建包含 BD 生成、OOC 综合、顶层综合、优化、布局、物理优化、布线、时序报告和 bitstream 导出。对本项目而言，综合和布局耗时较长，而 `route_design` 完成后还需要生成正式时序/DRC 报告才能确认是否可以发布 bitstream。

如果构建在布线完成后、报告或导出阶段被中断，不需要重新执行前面的综合和布局。Vivado 会在实现目录保留 post-phys-opt checkpoint，可以从该 checkpoint 重新执行布线和后续签核。

历史恢复脚本是：

```text
hw/scripts/vivado_resume_route.tcl
```

该脚本以及 `vivado_continue_impl.tcl` 不属于当前 P4 板测流程。当前 accepted
P4 routed DCP 已经完成 Explore route；板测只需要运行
`hw/scripts/export_p4_explore_deploy.sh` 导出部署文件。只有未来产生了与当前
RTL 完全匹配、尚未布线的 physopt checkpoint，才可以单独评估历史恢复脚本。

脚本只适用于与 checkpoint 对应的同一份 RTL、约束、Vivado 版本和器件型号。当前目标器件是 `xck26-sfvc784-2LV-c`，时钟约束是 `83.333 MHz / 12.000 ns`。

它不是“断点续跑 Vivado 进程”，而是重新启动一个 Vivado batch 进程，载入上一次保存的物理设计数据库，再从 `route_design` 开始执行。因此，恢复过程不依赖旧进程仍然存在，也不会使用脚本启动后才修改的 RTL。

## 2. 快速使用

先确认没有另一个构建进程正在写入同一个工程：

```bash
pgrep -af 'vivado|task_worker|route_design'
```

当前 P4 板测从 accepted routed DCP 导出部署文件：

```bash
bash hw/scripts/export_p4_explore_deploy.sh
sha256sum -c vivado_proj/p4-explore-deploy/SHA256SUMS
```

成功标准不是“命令正常结束”或“生成了 `.bit`”，而是报告同时满足：

```text
WNS >= 0.0 ns
WHS >= 0.0 ns
DRC errors == 0
```

当前 v2.5 P4 accepted Explore 结果是 `WNS=+0.021 ns`、`WHS=+0.010 ns`、
DRC Error severity 为 0，对应 83.333 MHz 时钟约束。P4 default route 的
`WNS=-0.110 ns` 已被拒绝，不应发布其 bitstream。

## 3. 恢复输入和输出

历史恢复脚本默认读取以下文件：

```text
vivado_proj/lara_attention.xpr
vivado_proj/lara_attention.runs/impl_1/attn_soc_wrapper_physopt.dcp
vivado_proj/lara_attention.gen/sources_1/bd/attn_soc/hw_handoff/attn_soc.hwh
hw/scripts/pre_bitstream.tcl
```

其中 `attn_soc_wrapper_physopt.dcp` 是布局完成、物理优化完成、尚未完成最终布线
签核的历史检查点。它不是当前 P4 accepted routed DCP，不能与 P4 源码混用。
历史脚本执行后生成：

```text
vivado_proj/reports/post_route_timing_summary.rpt
vivado_proj/reports/post_route_status.rpt
vivado_proj/reports/post_route_utilization.rpt
vivado_proj/reports/post_route_drc.rpt
vivado_proj/lara_attention.runs/impl_1/attn_soc_wrapper_routed.dcp
```

只有历史恢复的时序和 DRC 都通过时，才会继续生成：

```text
vivado_proj/deploy/lara_attention.bit
vivado_proj/deploy/lara_attention.hwh
vivado_proj/deploy/lara_attention.xsa
```

## 4. 执行方式

以下命令仅用于未来确有匹配 physopt checkpoint 的历史恢复场景；当前 P4 不要
执行它。Vivado 2025.2 的动态库路径需要包含安装目录下的兼容库：

```bash
env LD_LIBRARY_PATH=/home/jiao/xilinx/2025.2/Vivado/lib/lnx64.o/SuSE:/home/jiao/xilinx/2025.2/Vivado/lib/lnx64.o/Default:/home/jiao/xilinx/2025.2/Vivado/lib/lnx64.o \
  /home/jiao/xilinx/2025.2/Vivado/bin/vivado \
  -mode batch \
  -source hw/scripts/vivado_resume_route.tcl \
  -log vivado_proj/vivado_resume_route.log \
  -journal vivado_proj/vivado_resume_route.jou
```

也可以将命令放入 `nohup` 后台运行，但需要保存日志并确认只有一个 Vivado 构建在运行：

```bash
pgrep -af 'vivado|task_worker|route_design'
tail -f vivado_proj/vivado_resume_route.log
```

不要在恢复脚本运行时启动 `hw/scripts/vivado_build.sh`。完整构建使用独立的
`vivado_proj/build-<UTC timestamp>/` 输出目录，不会删除旧的 `vivado_proj/`，
但仍可能占用大量 CPU、内存和 Vivado license。

## 5. 脚本设计

### 5.1 固定参数

脚本开头集中定义了工程名、目录和布线策略：

| 参数 | 当前值 | 作用 |
|---|---|---|
| `PROJ_NAME` | `lara_attention` | Vivado 工程名 |
| `OUT_DIR` | `vivado_proj` | 工程和生成内容的根目录 |
| `RUN_DIR` | `...runs/impl_1` | 实现 run 的 checkpoint 目录 |
| `REPORT_DIR` | `vivado_proj/reports` | 签核报告目录 |
| `DEPLOY_DIR` | `vivado_proj/deploy` | 可部署文件目录 |
| `ROUTE_DIRECTIVE` | `Explore` | `route_design` 搜索策略 |

这些路径都是相对项目根目录解析的，所以不能在 `hw/scripts/` 目录内直接运行同一条命令。`set_param general.maxThreads 1` 用于限制 Vivado 并行线程，降低本机内存压力并保持本次恢复环境稳定；它会牺牲一部分运行速度，但不改变 RTL 功能。

### 5.2 输入检查

脚本在启动布线前检查 `.xpr` 和 `physopt.dcp`，缺少任何一个都会立即报错。HWH 在通过时序和 DRC 门禁、准备导出时检查，因为失败构建不需要生成硬件交接文件。

这里没有自动校验 checkpoint 与工作区源码的哈希。checkpoint 已经封装了当时的综合网表、约束、布局和物理优化结果；在生成 checkpoint 后对 `.sv`、`.v`、XDC 或 BD Tcl 做的修改，不会进入恢复结果。存在此类修改时必须重新执行完整构建。

## 6. 脚本执行流程

### 6.1 打开工程和检查点

脚本首先检查工程和 `physopt.dcp` 是否存在，然后执行：

```tcl
open_project vivado_proj/lara_attention.xpr
open_checkpoint vivado_proj/lara_attention.runs/impl_1/attn_soc_wrapper_physopt.dcp
```

这一步不会重新综合，也不会重新布局。恢复使用的网表、摆放结果、时序约束和物理数据库都来自 checkpoint。

### 6.2 重新布线

```tcl
set ROUTE_DIRECTIVE "Explore"
route_design -directive $ROUTE_DIRECTIVE
write_checkpoint -force .../attn_soc_wrapper_routed.dcp
```

脚本默认使用 `Explore` 布线 directive。对于只差几 ps 的设计，Explore 会增加全局 rip-up/reroute 搜索，通常比默认 directive 更容易找到满足 setup 的布线方案，但耗时也更长。布线阶段可能持续几十分钟。中间日志中的 WNS 不是最终签核值，只有 `report_timing_summary` 生成的 routed timing summary 才用于发布判断。

### 6.3 生成签核报告

脚本生成四类报告：

- `post_route_timing_summary.rpt`：setup、hold、时钟和失败端点。
- `post_route_status.rpt`：未布通、部分布线和 routed net 状态。
- `post_route_utilization.rpt`：LUT、寄存器、BRAM、URAM、DSP 等资源。
- `post_route_drc.rpt`：实现后的 DRC 检查。

脚本随后读取最差路径的 slack：

```tcl
set routed_wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set routed_whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
```

发布条件是：

```text
WNS >= 0.0 ns
WHS >= 0.0 ns
DRC errors == 0
```

任一条件失败时，脚本以退出码 `2` 结束，并明确阻止 bitstream 生成。这样可以避免把未收敛的 bitstream 误放入部署目录。

### 6.4 导出部署文件

时序和 DRC 通过后，脚本执行 `pre_bitstream.tcl`，写出 bitstream，并复制 BD 生成的 HWH，最后调用：

```tcl
write_hw_platform -fixed -include_bit -force .../lara_attention.xsa
```

因此 `.bit`、`.hwh` 和 `.xsa` 是同一份 routed design 的产物，不应混用不同构建轮次的文件。

脚本使用 `-force` 覆盖 routed checkpoint、报告和 deploy 下的同名文件。需要保留上一轮结果时，应在启动恢复前将其复制到版本化的 `checkpoint/vX.Y/` 目录。不要仅按修改时间推断三个部署文件属于同一轮构建。

## 7. 如何判断结果

成功时，日志末尾会出现类似内容：

```text
INFO: Routed signoff: WNS=0.xxx ns, WHS=0.xxx ns, DRC errors=0
ROUTE RESUME COMPLETE
```

随后检查：

```bash
rg -n 'WNS|WHS|Timing constraints are not met|DRC errors|Unrouted|Partially Routed' \
  vivado_proj/reports/post_route_timing_summary.rpt \
  vivado_proj/reports/post_route_status.rpt \
  vivado_proj/reports/post_route_drc.rpt

ls -lh vivado_proj/deploy/lara_attention.bit \
       vivado_proj/deploy/lara_attention.hwh \
       vivado_proj/deploy/lara_attention.xsa
```

Vivado 正常完成时进程退出码为 0；WNS、WHS 或 DRC 门禁失败时脚本主动以退出码 2 结束；输入缺失、Tcl 命令失败或 Vivado 内部错误也会返回非零退出码。自动化脚本应同时检查退出码和报告内容，不应只检查文件是否存在，因为 deploy 目录可能残留上一轮文件。

失败时重点查看：

```text
vivado_proj/vivado_resume_route.log
vivado_proj/reports/post_route_timing_summary.rpt
vivado_proj/reports/post_route_status.rpt
vivado_proj/reports/post_route_drc.rpt
```

如果 WNS 仍为负数，读取报告中的前 10 条 setup 路径后再决定是继续 RTL 流水化、增加局部寄存器，还是尝试物理优化。不要使用 false path 或 multicycle path 来掩盖真实数据路径。

## 8. 失败恢复和安全操作

### 当前 RTL 的安全完整构建

只要修改过 RTL、XDC、BD Tcl 或 Vivado 版本，就不能复用旧 DCP。当前安全
构建命令会使用新的输出目录、默认 `Explore` route，并在通过 routed signoff
之前禁止生成部署文件：

```bash
LARA_BUILD_TAG=20260804-current \
LARA_ROUTE_DIRECTIVE=Explore \
bash hw/scripts/vivado_build.sh
```

输出位于：

```text
vivado_proj/build-20260804-current/
```

目录中会保留 `build_metadata.txt`、Vivado log/journal、post-synth、
placed、physopt、routed checkpoints、signoff reports、deploy artifacts 和
`SHA256SUMS`。如果目录已存在，脚本会直接拒绝运行，不覆盖任何证据。

建议先进行只综合前置检查：

```bash
LARA_BUILD_TAG=20260804-synth \
LARA_STOP_AFTER_SYNTH=1 \
bash hw/scripts/vivado_build.sh
```

综合成功并通过 Python/Verilator/VCS 后，再启动完整 route。不要把只综合目录
中的 DCP 与其他构建轮次的 place/route DCP 混用。

### checkpoint 不存在

如果出现：

```text
Post-phys-opt checkpoint not found
```

说明前一次构建没有完成到 `phys_opt_design`，只能执行完整构建：

```bash
bash hw/scripts/vivado_build.sh
```

### 时序门禁失败

此时 routed checkpoint 和报告仍会保留，部署目录不会发布新的 bitstream。可以直接根据报告修改 RTL，然后重新执行完整构建；不能把旧 bitstream 重命名为新版本。

### 中止长时间构建

优先在当前终端发送 `Ctrl-C`，等待 Vivado 输出 `Interrupt received` 和 `Exiting Vivado`。确认没有残留进程：

```bash
pgrep -af 'vivado|task_worker|route_design'
```

不要直接删除 `vivado_proj`，因为其中可能包含可继续使用的 `placed.dcp` 或 `physopt.dcp`。

### 重新执行恢复脚本

恢复脚本从 `physopt.dcp` 开始，每次都会重新布线。若上一次恢复已经生成 `attn_soc_wrapper_routed.dcp`，后续可以将脚本改为从 routed checkpoint 直接生成报告和部署文件；当前脚本默认从 physopt checkpoint 开始，以保证布线数据库和报告状态一致。

### 修改 RTL 或约束后

不要直接重跑恢复脚本来验证修改，因为它仍会读取旧网表。应执行：

```bash
bash hw/scripts/vivado_build.sh
```

完整构建现在会在时间戳目录中重新生成新的 `physopt.dcp`；只有在布线或导出阶段
中断、且源码和约束没有再次变化时，才适合使用恢复脚本。

### deploy 中已经有旧文件

新构建使用独立目录，因此失败不会污染旧 deploy。仍然必须同时检查本轮退出码、
日志中的 routed signoff、WNS/WHS、unrouted nets、DRC 和本轮 `SHA256SUMS`；
不能仅依据某个目录中存在 `.bit` 判断成功。

## 9. 与完整构建的区别

| 项目 | 完整构建 `vivado_build.sh` | 恢复构建 `vivado_resume_route.tcl` |
|---|---|---|
| BD 生成 | 是 | 否，复用现有工程 |
| OOC 综合 | 是 | 否 |
| 顶层综合 | 是 | 否 |
| opt/place/phys_opt | 是 | 否，复用 `physopt.dcp` |
| route_design | 是 | 是 |
| routed timing/DRC | 是 | 是 |
| bit/HWH/XSA | 通过门禁后生成 | 通过门禁后生成 |
| 典型耗时 | 约 1 小时以上 | 约 30–40 分钟 |

恢复流程的核心目的，是在不改变时序约束和发布门禁的前提下，避免重复消耗已经完成的综合和布局时间。

## 10. 推荐操作清单

1. 确认当前 RTL、XDC、BD 脚本与生成 `physopt.dcp` 时一致。
2. 确认没有其他 Vivado 进程使用 `vivado_proj`。
3. 备份需要保留的上一轮 deploy 文件和报告。
4. 从项目根目录启动恢复命令，并保存 `.log` 和 `.jou`。
5. 监控日志，等待 Vivado 正常退出，不以中间 WNS 判断最终结果。
6. 检查退出码、WNS、WHS、DRC 和 route status。
7. 核对 `.bit/.hwh/.xsa` 均由本轮生成。
8. 将通过签核的三个文件归档到新的 `checkpoint/vX.Y/`，并记录时钟频率、slack 和 SHA-256。

## 11. v2.5 P0 是否需要重新实现

2026-07-26 的 P0 只新增 `attn_core` causal/cycle testbench、VCS 运行脚本，并修正
`sw/benchmark.py` 与文档；没有修改综合 RTL、CSR、XDC 或 BD。因而不应仅为 P0 重跑
Vivado，也不应把旧 DCP 当作新 RTL 证据。当前硬件签核是 v2.5 P4 candidate 1
的 matching clean build：default route WNS `-0.110 ns`，Explore WNS `+0.021 ns`、
WHS `+0.010 ns`、TNS/THS `0`、144158/144158 fully routed、DRC Error severity `0`。
P4 accepted screening 只有 routed DCP；若 RTL、约束或 BD 改变，必须重新执行完整
clean synthesis/place/route 流程。

## 12. v2.5 P1 matching clean-build 结果

P1 修改了综合 RTL，因此重新运行 `bash hw/scripts/vivado_build.sh`，先清除并重建
`vivado_proj/`，没有复用 Phase 2 DCP。默认 route 的早期估计一度为 WNS `-0.201 ns`，
router 内的 post-route physical synthesis 最终恢复到正式 signoff WNS `+0.003 ns`、
WHS `0.000 ns`、TNS/THS `0`。144612/144612 routable nets fully routed，DRC errors `0`，
因此本阶段默认 route 已满足发布门禁，不需要用 Explore 覆盖结果。

匹配的 `.bit/.hwh/.xsa` 和 post-route timing/route/utilization/DRC 报告保存在被忽略的
`checkpoint/v2.5-softmax-p-pipe/`，`SHA256SUMS` 已逐项校验。P2 已按要求重新执行 matching
clean build；其结果见下一节，不能用本节 P1 的 checkpoint 代替。

## 13. v2.5 P2 matching clean-build 结果

P2 修改了 `attn_top` 与 `softmax_engine` 的综合控制路径，因此从空 `vivado_proj/` 重新运行
`bash hw/scripts/vivado_build.sh`，没有使用 P1 incremental checkpoint。默认 route 在
rip-up/reroute 后完全布通，中间 post-router 估计为 WNS `-0.251 ns`；不要把这个中间值
误判为最终失败。同一 `route_design` 的 router physical synthesis 继续优化既有
MAC→output-buffer 路径，最终正式报告为 WNS `+0.001 ns`、TNS `0`、WHS `+0.010 ns`、
THS `0`，因此无需另跑 Explore。

route status 为 144472/144472 routable nets fully routed、routing errors `0`，DRC errors
`0`。最差 setup path data delay 为 11.590 ns，其中 route 7.557 ns（65.2%）。资源为
95356 LUT、56938 FF、50 BRAM、48 URAM、165 DSP。

`checkpoint/v2.5-phasea-softmax-overlap/` 保存本轮 bit/HWH/XSA、post-synth/post-route
报告、`attn_soc_wrapper_physopt.dcp`、`attn_soc_wrapper_routed.dcp` 和实现日志；根目录
`SHA256SUMS` 已逐项通过。P3 若修改 scratch/P-store RTL，必须再次 clean build，不能复用
本节 DCP 证明其时序或资源。

## 14. v2.5 P3 scratch/P-store DSE

P3 三个候选均使用独立参数开关和同一套 Python/Verilator/VCS 测试。Step 1
`P_INPLACE=1, P_OUTPUT_DIRECT=0` 的 clean synthesis 已保存到
`checkpoint/v2.5-p3-softmax-scratch-dse/step1-p-inplace-registered/`，其
`PAUSE_MANIFEST.md` 和 `SHA256SUMS` 已校验。该变体 softmax FF 为 `25182`，
高于 P2 基线，未进入 implementation。

Step 2 direct-output 的 matching post-route 为 WNS `-1.245 ns`、TNS
`-882.633 ns`；Step 3 score-inplace 的 Explore route 为 WNS `-0.121 ns`、
TNS `-8.624 ns`，CLB 使用率 `99.17%`。二者都 fully routed，但 setup 未通过，
没有生成可发布 bitstream。P3 不得使用 P2 DCP 或旧 route 报告冒充 accepted
实现；P3 的失败候选不能改变默认，当前源码默认是 P4 streaming/fused-PV。
后续 route 必须从匹配当前 RTL 的 clean build 开始。

## 15. v2.5 P4 candidate 1 accepted via Explore

P4 candidate 1 的 matching clean build 使用 `LARA_STREAMING_PV_ENABLE`。默认
route 已完全布线，但 setup 未通过：WNS `-0.110 ns`、TNS `-4.889 ns`、WHS
`+0.010 ns`、THS `0`。因此没有把默认 route 当作 signoff。

从同一轮 matching `attn_soc_wrapper_physopt.dcp` 执行
`route_design -directive Explore` 后，正式报告为 WNS `+0.021 ns`、TNS `0`、
WHS `+0.010 ns`、THS `0`；144158/144158 routable nets fully routed，routing
errors `0`，DRC Error severity `0`。Explore post-route 资源为 95479 LUT、
56940 FF、50 BRAM、48 URAM、165 DSP。最差 setup path 是 MAC product register
到 output-buffer read data，data delay 11.804 ns，其中 logic 3.971 ns、route
7.833 ns。

周期证据为 32x32 `4345 -> 3209`、32x64 `8429 -> 5809`，均超过 10% 主循环
收益门限；partial A/B 输出 bit-exact。该候选已接受并设为默认，定义
`LARA_STREAMING_PV_ROLLBACK` 可恢复 P2 调度。归档路径：
`checkpoint/v2.5-p4-architecture-dse/candidate1-streaming-pv/`。

注意：Explore screening 只归档 routed DCP 和报告，没有生成或声称
`.bit/.hwh/.xsa`。后续若要发布部署产物，必须从当前默认源码重新执行 clean
Vivado 门禁，并在 matching route 成功后再生成。

## 16. 2026-08-06 split-16 v4 降频候选

本节是当前候选的操作记录，不替代前述 v2.5 P4 的 83.333 MHz 历史签核数据。
当天的 synthesis-only 对比如下：

| 指标 | v4 acc-base | v5 commit-cone |
|---|---:|---:|
| LUT | 77,763 | 78,923 |
| FF | 85,966 | 85,888 |
| BRAM / URAM / DSP | 50 / 48 / 56 | 50 / 48 / 56 |
| WNS | -0.593 ns | -0.815 ns |
| TNS | -58.653 ns | -250.053 ns |
| setup failing endpoints | 203 | 1,209 |

v4 除少量 FF 外全面优于 v5，当前 `hw/rtl` 已回退到 v4。两版源码和原始
综合证据保存在 `checkpoint/20260806-split16-v4-v5-rtl/`。这些数字是
post-synth 结果，不是 post-route signoff，也没有对应 bitstream。

### 16.1 KV260 可实现频率

通过 Vivado 2025.2 对 KV260 PS PL0 配置的实际解析得到：

| Vivado 请求值 | PL0 实际值 | 约束周期 |
|---:|---:|---:|
| 83.333 MHz | 83.332497 MHz | 12.000 ns |
| 80.000 / 78.125 / 76.923 MHz | 76.922310 MHz | 13.000 ns |
| 75.000 / 72.000 MHz | 71.427856 MHz | 14.000 ns |

因此实际最接近 75 MHz 的频点是 `76.922310 MHz`。当前
`hw/scripts/vivado_build.tcl` 使用请求值 `76.923`；若其 post-route 失败，启用
紧邻注释中的 `FCLK_MHZ 72.000` fallback，得到实际 `71.427856 MHz`。同时必须
将 `sw/attn_driver.py` 和 `sw/benchmark.py` 切换到各自紧邻的 `71.427856`
fallback，避免 profile 和性能换算仍按旧频率计算。

按 v4 的 12 ns post-synth WNS 线性估算，13 ns 对应约 `+0.407 ns`，14 ns 对应
约 `+1.407 ns`。这只是频率选择依据；布局、布线、clock skew 和物理优化会改变
最终结果，不能把估算值作为签核结果。

### 16.2 Clean build 命令

76.922310 MHz：

```bash
cd /home/jiao/git/LARA
LARA_BUILD_TAG=20260806T_v4_76p922MHz \
LARA_ROUTE_DIRECTIVE=Explore \
bash hw/scripts/vivado_build.sh
```

切换三处 fallback 后构建 71.427856 MHz：

```bash
cd /home/jiao/git/LARA
LARA_BUILD_TAG=20260806T_v4_71p428MHz \
LARA_ROUTE_DIRECTIVE=Explore \
bash hw/scripts/vivado_build.sh
```

仅改变时钟约束也必须 clean build，不能从 76 MHz 的 placed/routed DCP 冒充
71 MHz 的 matching result。不同 `LARA_BUILD_TAG` 会保留两个候选的独立证据。

### 16.3 最终验收

```bash
cd /home/jiao/git/LARA/vivado_proj/build-<对应构建标签>
sha256sum -c SHA256SUMS
rg -n -A12 \
  'Design Timing Summary|Clock Summary|WNS\(ns\)|All user specified timing constraints' \
  reports/post_route_timing_summary.rpt
```

只有同时满足以下条件才能发布 bitstream：

```text
WNS >= 0 ns, TNS = 0
WHS >= 0 ns, THS = 0
fully routed, routing errors = 0
DRC Error severity violations = 0
.bit/.hwh/.xsa 来自同一构建且 SHA256SUMS 通过
```

VCS 是周期级功能仿真，不使用 Vivado 的 13/14 ns 时钟约束。若 RTL 没有变化，
76 MHz 切换到 71 MHz 不要求重跑 VCS；需要形成一套完整归档证据时，可以重跑
`docs/kv260_board_validation.md` 第 0.5 节中的两个 board-case matrix。

### 16.4 76.922310 MHz 最终结果

`build-20260806T_v4_76p922MHz` 的 clean Explore implementation 已完成，但未通过
发布门禁，因此没有生成 bitstream。最终结果为：

```text
post-synth: WNS=+0.402 ns, TNS=0
post-route: WNS=-0.191 ns, TNS=-39.719 ns, setup failing endpoints=535
post-route: WHS=+0.006 ns, THS=0
route:      138592/138592 routable nets fully routed, routing errors=0
DRC:        Error severity violations=0
```

最差 setup path 从 `u_mac/pe_prod_r_reg[12][0][29]` 到
`u_mac/block_out_capture_reg[12][4][17]`，data path delay 为 `12.888 ns`，其中
logic `5.065 ns`、route `7.823 ns`。这表明失败原因是 MAC FP32 累加/捕获锥的
真实 setup 延迟，不是 hold、DRC、资源超限或未布线。

当前配置已切换到请求值 `72.000 MHz`，即实际 `71.427856 MHz`。若物理实现近似
保持不变，14 ns 周期相对本轮 13 ns 周期增加约 1 ns，理论 WNS 约为
`+0.809 ns`；仍必须通过新的 matching clean post-route 报告确认。

为验证该估算，已打开 76.922310 MHz 的同一份 routed DCP，在不保存 DCP 的情况
下将 `clk_pl_0` 临时重约束为 14.000 ns 并重新运行 timing analysis。结果为
WNS `+0.809 ns`、TNS `0`、setup failing endpoints `0`、WHS `+0.006 ns`。
这说明原 TNS `-39.719 ns` 是 535 个小 setup 违例的累计值，不代表需要增加
39.719 ns 周期。该 retiming 结果只证明现有物理布局在 14 ns 下可以通过；正式
发布仍要求 71.427856 MHz 配置自身的 clean synthesis/place/route 和 matching
bitstream 全部通过门禁。

### 16.5 71.427856 MHz 最终签核结果

`build-20260806T_v4_71p428MHz` 已完成 matching clean synthesis、Explore
place/route 和部署导出，最终通过发布门禁：

```text
post-synth: WNS=+1.397 ns, TNS=0
post-route: WNS=+0.171 ns, TNS=0
post-route: WHS=+0.010 ns, THS=0
route:      138565/138565 routable nets fully routed, routing errors=0
DRC:        Error severity violations=0
```

最终最差 setup path 已从 76 MHz 构建的 MAC 累加锥转移到 softmax：从
`u_softmax/sm_row_idx_reg[2]_rep__11` 到
`u_softmax/sm_corr_shift_pipe_reg[23]`，data path delay 为 `13.496 ns`，其中
logic `5.629 ns`、route `7.867 ns`。新一轮物理实现的 WNS 比旧 routed DCP 的
14 ns 临时重约束结果少 `0.638 ns`，但仍以 `+0.171 ns` 完成正式签核。

post-route 资源为 77116 LUT、85103 FF、50 BRAM tile、48 URAM 和 56 DSP，均未
超限。以下 matching 部署文件已生成：

```text
vivado_proj/build-20260806T_v4_71p428MHz/deploy/lara_attention.bit
vivado_proj/build-20260806T_v4_71p428MHz/deploy/lara_attention.hwh
vivado_proj/build-20260806T_v4_71p428MHz/deploy/lara_attention.xsa
```

构建目录 `SHA256SUMS` 中的三件套和四份 post-route 报告已全部校验通过。后续
上板必须整套复制，不能与 76 MHz 或 P4 构建的 HWH/XSA 混用。
