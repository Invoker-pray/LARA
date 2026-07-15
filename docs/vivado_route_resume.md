# Vivado 增量布线恢复说明

## 1. 背景

完整的 KV260 Vivado 构建包含 BD 生成、OOC 综合、顶层综合、优化、布局、物理优化、布线、时序报告和 bitstream 导出。对本项目而言，综合和布局耗时较长，而 `route_design` 完成后还需要生成正式时序/DRC 报告才能确认是否可以发布 bitstream。

如果构建在布线完成后、报告或导出阶段被中断，不需要重新执行前面的综合和布局。Vivado 会在实现目录保留 post-phys-opt checkpoint，可以从该 checkpoint 重新执行布线和后续签核。

本项目的恢复脚本是：

```text
hw/scripts/vivado_resume_route.tcl
```

脚本只适用于与 checkpoint 对应的同一份 RTL、约束、Vivado 版本和器件型号。当前目标器件是 `xck26-sfvc784-2LV-c`，时钟约束是 `83.333 MHz / 12.000 ns`。

它不是“断点续跑 Vivado 进程”，而是重新启动一个 Vivado batch 进程，载入上一次保存的物理设计数据库，再从 `route_design` 开始执行。因此，恢复过程不依赖旧进程仍然存在，也不会使用脚本启动后才修改的 RTL。

## 2. 快速使用

先确认没有另一个构建进程正在写入同一个工程：

```bash
pgrep -af 'vivado|task_worker|route_design'
```

然后从项目根目录执行：

```bash
env LD_LIBRARY_PATH=/home/jiao/xilinx/2025.2/Vivado/lib/lnx64.o/SuSE:/home/jiao/xilinx/2025.2/Vivado/lib/lnx64.o/Default:/home/jiao/xilinx/2025.2/Vivado/lib/lnx64.o \
  /home/jiao/xilinx/2025.2/Vivado/bin/vivado \
  -mode batch \
  -source hw/scripts/vivado_resume_route.tcl \
  -log vivado_proj/vivado_resume_route.log \
  -journal vivado_proj/vivado_resume_route.jou
```

成功标准不是“命令正常结束”或“生成了 `.bit`”，而是报告同时满足：

```text
WNS >= 0.0 ns
WHS >= 0.0 ns
DRC errors == 0
```

当前 v2.2 的恢复结果是 `WNS=+0.040 ns`、`WHS=+0.010 ns`、DRC error 为 0，对应 83.333 MHz 时钟约束。

## 3. 恢复输入和输出

脚本默认读取以下文件：

```text
vivado_proj/lara_attention.xpr
vivado_proj/lara_attention.runs/impl_1/attn_soc_wrapper_physopt.dcp
vivado_proj/lara_attention.gen/sources_1/bd/attn_soc/hw_handoff/attn_soc.hwh
hw/scripts/pre_bitstream.tcl
```

其中 `attn_soc_wrapper_physopt.dcp` 是布局完成、物理优化完成、尚未完成最终布线签核的检查点。脚本执行后生成：

```text
vivado_proj/reports/post_route_timing_summary.rpt
vivado_proj/reports/post_route_status.rpt
vivado_proj/reports/post_route_utilization.rpt
vivado_proj/reports/post_route_drc.rpt
vivado_proj/lara_attention.runs/impl_1/attn_soc_wrapper_routed.dcp
```

只有时序和 DRC 都通过时，才会继续生成：

```text
vivado_proj/deploy/lara_attention.bit
vivado_proj/deploy/lara_attention.hwh
vivado_proj/deploy/lara_attention.xsa
```

## 4. 执行方式

在项目根目录执行。Vivado 2025.2 的动态库路径需要包含安装目录下的兼容库：

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

不要在恢复脚本运行时启动 `hw/scripts/vivado_build.sh`。完整构建脚本会删除并重新创建 `vivado_proj`，可能破坏正在使用的恢复输入。

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

完整构建重新生成新的 `physopt.dcp` 后，只有在布线或导出阶段中断、且源码和约束没有再次变化时，才适合使用恢复脚本。

### deploy 中已经有旧文件

门禁失败发生在写 bitstream 之前，脚本不会主动清理旧 deploy 文件。因此失败后看到 `.bit/.hwh/.xsa` 并不代表本轮成功。以本轮日志中的 `ROUTE RESUME COMPLETE`、进程退出码和报告签核值为准；发布前再核对文件时间和 SHA-256。

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
