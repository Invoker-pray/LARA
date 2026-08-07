# KV260 上板与板上验证指南

本指南当前的正式上板版本是 2026-08-06 split-16 v4 acc-base，KV260 PL0 实际
频率 `71.427856 MHz`。宿主机负责 RMSNorm、QKV projection 和可选 RoPE，PL
负责 exact-BF16 GQA attention。当前硬件使用 16x16 物理 MAC、8 个 KV cache
bank、32 行 Q tile，单次事务最大序列长度为 512。

正式部署三件套来自
`vivado_proj/build-20260806T_v4_71p428MHz/deploy/`。该构建 post-route WNS
`+0.171 ns`、TNS `0`、WHS `+0.010 ns`、THS `0`，fully routed、routing error
和 DRC Error 均为 0。后文保留的 P4 DCP 和旧 `board_cases_v2.6` 操作仅用于历史
追溯；不能把它们的 `.bit/.hwh/.xsa` 或旧 expected output 混入当前正式板测。

## 当前正式上板、性能测试与演示

### A. 官网规则与本项目测试口径

截至 2026-08-06，FPT 2026 [Design Competition 官方页面](https://fpt2026.uark.edu/fpt26-design-competition/)
对 Track B 的明确要求是 Llama3-8B 或参数一致模型、BF16 attention accelerator，
评价维度为 performance、hardware architecture optimizations 和 scalability。
[官方提交指南仓库](https://github.com/FPT26/Design-Competition-Submission-Guidelines)
中的 Track B DOCX 只进一步要求 Vivado/Vitis 2025.2、提交可复现源码/工程/测试材料，
以及最长 5 分钟的目标平台演示视频。

官方材料没有规定固定 baseline、输入尺寸、重复次数、统一频率、性能公式或 CPU/FPGA
时钟比较方法。因此 `sw/board_performance.py` 使用以下可复现口径：

- workload：q3/kv3 与 q31/kv7，各覆盖 L1/L16/L32/L64/L128、causal/noncausal，
  共 20 个 case；脚本强制检查矩阵完整并自动排除 L512。
- correctness：FPGA 输出必须与每个 NPZ 的 current-RTL `expected_o` raw BF16
  bit-exact；普通 NumPy softmax 只用于性能 baseline 和误差统计，不替代 RTL oracle。
- FPGA 主指标：RTL `pl_total_cycles / 71.427856 MHz`，这是 start 到 done 的 PL
  transaction 时间，包含 core 等待外部 DMA/memory 的周期。
- FPGA 辅助指标：驱动 `attention_total_ms`，即 PS 内存中的 Q/K/V 到 PS 内存中的 O，
  包含打包、DMA 和 request service 的 host-to-host 时间。
- baseline：同一块 KV260 的 Cortex-A53 用 NumPy FP32 matmul、稳定 softmax 完成相同
  BF16 输入的 32Q/8KV、GQA 4:1 attention，全程不调用 PL 阵列。
- CPU 主指标：`perf_counter_ns` 的真实 wall time。CPU 与 PL 属于不同 DVFS/clock
  domain，不能直接比较原始周期；PL 用自身周期/PL Hz，CPU 用真实 elapsed time，最后
  比较两者的秒数。脚本同时归档 CPU governor/current frequency 和温度快照。
- 辅助同频归一化：若需要比较每 MHz 架构效率，可在 CPU 频率稳定时计算
  `CPU_linear_at_PL_ms = CPU_wall_ms * CPU_MHz / PL_MHz`，再以
  `CPU_linear_at_PL_ms / FPGA_ms` 得到线性同频比。当前实测频率对应
  `1333.333 / 71.427857 = 18.6668`。该结果必须标注为 hypothetical linear
  frequency normalization；CPU/NEON、cache、DRAM 和 DVFS 不会保证随频率严格线性，
  因而它不能替代真实 wall-time，也不能写成实际同频板测结果。
- 默认 1 次 warmup、5 次正式测量，报告 min/median/p95/max；speedup 使用 median。
  `LARA_CPU_THREADS=1` 为默认单线程 baseline，也可显式设为 4 并在结果中留痕。

### B. 生成唯一的 SD 卡 payload

在工作站项目根目录执行。第二个参数必须是不存在或为空的新目录，打包脚本会防止
旧文件混入：

```bash
cd /home/jiao/git/LARA
bash sw/package_kv260_board.sh \
  vivado_proj/build-20260806T_v4_71p428MHz \
  board_payload_v4_71p428MHz \
  /home/jiao/Downloads/kv260-pynq-offline/sd-bundle
```

payload 内包含：

```text
lara_attention.bit
lara_attention.hwh
lara_attention.xsa
attn_driver.py
clear_pynq_cache.py
board_test.py
board_matrix.py
board_performance.py
run_board_full_validation.py
board_cases_rtl_contract_v2.6_fixed/       # 正式 q3/kv3
board_cases_rtl_contract_v2.6_q31_kv7/     # 正式 q31/kv7
offline/                                   # PYNQ runtime、ARM64 wheels、dtbo、安装器
kv260_board_validation.md
LARA_SHA256SUMS
```

PYNQ 运行时实际加载 `.bit` 和同名 `.hwh`；`.xsa` 也一并保存以证明硬件交付物来自
同一构建。三件套哈希应分别为：

```text
e59bb3310899e4170ca965f8b5d7702e971e5fc9238bdeae359041403c943470  lara_attention.bit
9718f0ed111ba552e86f2cd9571759cab61bab8ab7bedc68237d5922e148fef2  lara_attention.hwh
c7630c61d833f5290c7afa81e28dc8d132439bbe5ec44004037deb5b49d9dfae  lara_attention.xsa
```

### C. 更新 SD 卡文件

板卡能通过网络访问时，推荐不拔卡，直接将整个新 payload 同步到一个新目录：

```bash
ssh ubuntu@<KV260_IP> 'mkdir -p /home/ubuntu/lara-v4-71p428'
scp -r board_payload_v4_71p428MHz/. \
  ubuntu@<KV260_IP>:/home/ubuntu/lara-v4-71p428/
ssh ubuntu@<KV260_IP> \
  'cd /home/ubuntu/lara-v4-71p428 && sha256sum -c LARA_SHA256SUMS'
```

保留旧目录而创建 `lara-v4-71p428`，可以在文件复制失败时回退，且不会把旧 `.hwh`
与新 `.bit` 混用。

若必须拔下 SD 卡并在工作站直接写 rootfs，先用 `lsblk -f` 识别该卡的 Linux rootfs
分区。下面的 `<ROOTFS_MOUNT>` 是桌面自动挂载点，例如
`/run/media/$USER/rootfs`；不要把这些文件只放到 FAT boot 分区：

```bash
lsblk -f
sudo mkdir -p <ROOTFS_MOUNT>/home/ubuntu/lara-v4-71p428
sudo cp -a board_payload_v4_71p428MHz/. \
  <ROOTFS_MOUNT>/home/ubuntu/lara-v4-71p428/
sudo chown -R 1000:1000 <ROOTFS_MOUNT>/home/ubuntu/lara-v4-71p428
sync
sudo umount <ROOTFS_MOUNT>
```

必须根据 `lsblk -f` 确认设备和挂载点再执行 `umount`，不能照抄一个未知的
`/dev/sdX`。重新插回 KV260 后，所有操作都在 `/home/ubuntu/lara-v4-71p428`。

### D. 上电后的初始化与功能测试

连接电源、以太网或串口，启动完成后 SSH 登录。每次重新上电都执行：

```bash
ssh ubuntu@<KV260_IP>
cd /home/ubuntu/lara-v4-71p428
sha256sum -c LARA_SHA256SUMS

sudo -i
source /etc/profile.d/pynq_venv.sh
cd /home/ubuntu/lara-v4-71p428

python3 clear_pynq_cache.py \
  --bitstream ./lara_attention.bit
```

`clear_pynq_cache.py` 现在是综合板测初始化入口：它验证 NumPy/PYNQ、清理陈旧 PL
metadata、插入 DTBO、运行 `xbutil examine` 并严格检查 KV260 ready、校验部署三件套，
同时生成 `board_environment.txt`、`board_environment.json` 和
`deployed_hardware_sha256.txt`。只有输出 `overall_status: PASS` 才继续零输入 smoke
和两套正式 bit-exact 矩阵：

```bash
python3 board_test.py \
  --bitstream ./lara_attention.bit \
  --seq-len 1 \
  --profile-json smoke_l1.json

python3 board_matrix.py \
  --bitstream ./lara_attention.bit \
  --cases ./board_cases_rtl_contract_v2.6_fixed \
  --output-dir ./board_results_q3kv3 \
  --lengths 1 16 32 64 128

python3 board_matrix.py \
  --bitstream ./lara_attention.bit \
  --cases ./board_cases_rtl_contract_v2.6_q31_kv7 \
  --output-dir ./board_results_q31kv7 \
  --lengths 1 16 32 64 128
```

两条命令通过 `--lengths` 各筛选 10 个 case，终端应分别报告 `10/10 PASS`。
q3/kv3 和 q31/kv7 目录都包含 L512 causal/noncausal；q3/kv3 目录还保留一个历史
q0/kv0 L512 causal case。此处不会运行它们。旧
`board_cases_v2.6` 除 L1 外的 expected 不匹配当前 RTL，不能用它的 FAIL 结论替代
正式 `..._fixed` q3/kv3 结果。

### E. 自动性能测试

仍在上述 root/PYNQ shell 中执行。脚本在每个 case 前重新加载 Overlay，依次运行
两套 20 个 case；每个 case 默认预热 1 次、正式运行 5 次：

驱动默认只在没有新请求可服务时休眠 `20 us`。完成一个新的 K/V/Q DMA 请求后会
立即重新轮询；如果 RTL 的请求位尚未撤销，驱动会识别相同 `CSR_LOAD_REQ`，避免
重复提交同一 DMA。可用 `LARA_REQUEST_POLL_SLEEP_US` 调整空闲轮询间隔：`0` 表示
完全忙轮询，建议板测 A/B 使用 `10`、`20` 或 `50`。profile 中的
`request_poll_sleep_us`、`request_poll_sleeps` 和 `request_duplicate_polls` 会记录
实际配置和轮询行为。旧驱动每轮固定休眠 `500 us`，不能与新结果混为同一软件版本。

```bash
LARA_CPU_THREADS=1 \
LARA_REQUEST_POLL_SLEEP_US=20 \
python3 board_performance.py \
  --bitstream ./lara_attention.bit \
  --case-set q3kv3=./board_cases_rtl_contract_v2.6_fixed \
  --case-set q31kv7=./board_cases_rtl_contract_v2.6_q31_kv7 \
  --warmup 1 \
  --repeats 5 \
  --cpu-core 3 \
  --cpu-clock-mhz 1333.333 \
  --output-dir ./board_performance_results
```

`--cpu-clock-mhz` 用于估算 CPU cycles 和每周期效率；只有 CPU governor/frequency
在测量前后稳定时才能使用。JSON/CSV 会额外记录 `cpu_ops_per_cycle`、
`pl_transaction_ops_per_cycle`、`pl_active_ops_per_cycle`、
`pl_transaction_efficiency_over_cpu` 和 `pl_active_efficiency_over_cpu`。其中 PL active
每周期效率是主要架构指标；真实 host-to-host E2E 继续使用 wall-time，不做伪同频换算。

板上 attention 默认无超时限制，长 case 不会在 5 分钟时被脚本终止。需要快速收集
代表性证据时，运行一键脚本的 `--quick-q31kv7` 模式，只测 q31/kv7 L1 causal 和
L128 causal 两个 case：

```bash
python3 run_board_full_validation.py \
  --quick-q31kv7 \
  --bitstream ./lara_attention.bit \
  --output-dir ./board_quick_q31kv7_L1_L128 \
  --cpu-threads 1 \
  --cpu-clock-mhz 1333.333 \
  --warmup 1 \
  --repeats 5
```

该模式仍同时保存 bit-exact 功能结果、FPGA profile、CPU baseline、CSV、JSON 和日志，
最终应为 `2/2 PASS`。确实卡死时用 `Ctrl+C`，已有结果会保留。

先检查用例是否齐全而不加载 FPGA：

```bash
python3 board_performance.py \
  --case-set q3kv3=./board_cases_rtl_contract_v2.6_fixed \
  --case-set q31kv7=./board_cases_rtl_contract_v2.6_q31_kv7 \
  --list-only
```

需要与四核 NumPy baseline 对比时，应作为另一轮独立实验，不能覆盖单线程结果：

```bash
LARA_CPU_THREADS=4 python3 board_performance.py \
  --bitstream ./lara_attention.bit \
  --output-dir ./board_performance_results_cpu4
```

输出 `performance.json` 保存全部 samples、profile、hash、数值误差、环境与方法；
`performance.csv` 是论文和视频可直接引用的汇总。只有终端最后显示
`bit-exact matrix: 20/20 PASS` 才能把性能数字作为有效结果。建议将两个结果目录复制
回工作站归档：

当前 v4 bitstream 的 performance CSR 在 core 返回 IDLE 后可能已经清零，表现为
`cycles/mac_cycles/stall_cycles` 全为 0。软件会将 `pl_counter_valid=false`，不计算
PL-cycle time/GOPS/speedup，同时继续报告有效的 FPGA host-to-host wall time、CPU
baseline wall time 和端到端 speedup。0 cycles 不能解释为零延迟。

当前 RTL 源码已将 counter 改为“下一次 accepted start 时清零、DONE 后在 IDLE
保持”，VCS 已覆盖完成后延迟读取和下一事务清零。该修复不追溯修改已经生成的 v4
bitstream；必须用修复后的 RTL 重新完成 Vivado 构建并生成 `.bit/.hwh/.xsa`，板上
才能得到非零 counter。新脚本把性能拆分为：PL transaction、PL external stall、
PL controller-active excluding stalls、PL MAC-active、host-to-host E2E 和 CPU kernel。

计数器专项回归同时覆盖 core 生命周期和顶层 AXI-Lite CSR 延迟读取：

```bash
SNPSLMD_LICENSE_FILE=27000@127.0.0.1 \
LM_LICENSE_FILE=27000@127.0.0.1 \
bash VV/scripts/run_tb_perf_counter_retention.sh
```

日志必须同时包含 `ALL ATTN_CORE CAUSAL SKIP CHECKS PASSED`、非零的
`PERF_CSR_AFTER_DONE`、`BOARD CASE PASS` 和
`ALL PERFORMANCE COUNTER RETENTION CHECKS PASSED`。

功能矩阵按数值长度顺序运行（L1 到 L128），且每个 case 都重新加载 Overlay，避免
前一个事务的 PL 内部状态影响下一个独立的正确性用例。性能脚本默认在每个 FPGA
warmup 和正式 sample 前都重新加载 Overlay，并分别输出 `FPGA MEASURE START/DONE`
和 `CPU BASELINE START/DONE`；Overlay 加载及 PYNQ buffer 分配发生在计时区间外。
只有诊断重复事务状态机时才使用 `--reuse-overlay-within-case`。一键脚本被 Ctrl-C
中断时会依次向整个子进程组发送 INT/TERM/KILL 并 wait 回收，避免残留进程继续访问
DMA 或 PL；不需要在每个 case 前删除 PYNQ metadata cache。

KV260 启动镜像的 IOPLL 频率可能与 Vivado HWH 生成时的 PLL 假设不同。PYNQ
`Overlay.download()` 只应用 HWH 中的 FCLK 分频值，可能把设计时的 71.427856 MHz
实际配置成约 107.14 MHz。驱动因此会在每次 Overlay 下载后显式执行
`Clocks.fclk0_mhz = 71.427856`，回读实际频率并要求误差不超过 0.05 MHz；profile
和性能脚本均使用该回读值换算周期。不能只根据 HWH 的 `FREQ_HZ` 假定板上频率。

当前硬件 `MAX_SEQ_LEN=512`，不能运行 L2048。最大长度扩展测试可使用 q31/kv7
L512 causal 模式；绝对位置 base 仍为 16-bit，不受 512 的 tensor 长度上限约束：

```bash
python3 run_board_full_validation.py \
  --extended-q31kv7-l512 \
  --bitstream ./lara_attention.bit \
  --output-dir ./board_extended_q31kv7_L512 \
  --cpu-threads 1 \
  --cpu-core 3 \
  --warmup 0 \
  --repeats 1
```

```bash
exit
exit
scp -r ubuntu@<KV260_IP>:/home/ubuntu/lara-v4-71p428/board_results_q3kv3 .
scp -r ubuntu@<KV260_IP>:/home/ubuntu/lara-v4-71p428/board_results_q31kv7 .
scp -r ubuntu@<KV260_IP>:/home/ubuntu/lara-v4-71p428/board_performance_results .
```

### F. 最长 5 分钟演示视频

官方要求的是提交一段最长 5 分钟、能证明项目在目标平台运行并有清楚说明的视频，
并非要求上板操作持续 5 分钟。推荐视频结构：

1. 约 20 秒：镜头展示 KV260、SD 卡和连接，说明平台与 71.427856 MHz。
2. 约 30 秒：终端运行 `sha256sum -c`、`xbutil examine`，展示 bitstream 身份和
   `Ready: Yes`。
3. 约 90 秒：现场各运行一个 q3/kv3、q31/kv7 的 L128 bit-exact case，并展示事先
   完整运行得到的两个 `summary.json`。若全矩阵能在视频时间内完成，也可直接运行；
   不要为了录屏中途终止正式结果。
4. 约 90 秒：展示完整正式 benchmark 的 `performance.csv`/`performance.json`，解释
   PL cycle time、host-to-host time、CPU baseline 和 speedup。可以另跑 `--repeats 1`
   作为现场流程演示，但论文和视频中的正式数字必须来自默认 5 repeats 的归档。
5. 约 60 秒：展示架构图和 post-route WNS/TNS、资源，说明 BF16、GQA 4:1、
   16x16 MAC 与可扩展边界。

可以先用手机拍到板卡和屏幕，再切换电脑录屏显示 SSH/串口终端；官网没有规定串口、
SSH、单镜头或剪辑方式。只拍插卡和上电不能证明 accelerator 已正确运行。

## 0. 快速操作流程

下面是一次完整验证的最短流程。主机端命令在项目根目录执行，板上命令在
`/home/ubuntu/lara` 执行。

### 0.1 生成主机与 VCS 共用的 NPZ

默认生成 L1/L16/L32/L64/L128 的 causal 和 noncausal 用例：

```bash
cd ~/git/LARA
python3 sw/generate_board_cases.py \
  --output-dir board_cases_v2.6 \
  --lengths 1 16 32 64 128 \
  --include-noncausal \
  --q-pos-base 3 \
  --kv-pos-base 3 \
  --seed 2602
```

生成器保存 raw BF16 `uint16` 输入和 `expected_o`，并把位置参数写入每个
NPZ 的 metadata。重新执行时不会删除其他长度的已有 case；不同位置参数应使用
不同输出目录，避免把多套同名 case 混在一起。

例如生成 Q/KV 绝对位置不同的测试集：

```bash
python3 sw/generate_board_cases.py \
  --output-dir board_cases_pos_q32_kv0 \
  --lengths 1 16 32 64 128 \
  --include-noncausal \
  --q-pos-base 32 \
  --kv-pos-base 0 \
  --seed 3600
```

生成 L512 时建议单独追加到同一个目录。当前位置范围按 16-bit 绝对位置检查，
因此 q3/kv3 和 q31/kv7 的 L512 都是合法输入：

```bash
python3 sw/generate_board_cases.py \
  --output-dir board_cases_rtl_contract_v2.6_fixed \
  --lengths 512 \
  --include-noncausal \
  --q-pos-base 3 \
  --kv-pos-base 3 \
  --seed 2612 \
  --backend vectorized

python3 sw/generate_board_cases.py \
  --output-dir board_cases_rtl_contract_v2.6_q31_kv7 \
  --lengths 512 \
  --include-noncausal \
  --q-pos-base 31 \
  --kv-pos-base 7 \
  --seed 2612 \
  --backend vectorized \
  --resume
```

`--backend vectorized` 仍按 RTL contract 的 BF16 乘法、FP32 累加、LUT
插值和舍入顺序生成期望值；它不是普通 GPU 矩阵乘法。需要最慢的逐元素参考时
可使用 `--backend scalar`。

生成器会按 `完成数/总数` 输出当前 case、单 case 耗时和累计耗时；中断后
使用 `--resume` 可以继续未完成的 case。

生成器命令行参数速查：

| 参数 | 默认值 | 作用 |
|---|---|---|
| `--output-dir` | `board_cases_v2.6` | NPZ 输出目录 |
| `--lengths` | `1 16 32 64 128 512` | 要生成的序列长度列表 |
| `--include-noncausal` | 关闭 | 同时生成 causal 和 noncausal |
| `--q-pos-base` | `0` | Q 绝对位置基址 |
| `--kv-pos-base` | `0` | K/V 绝对位置基址 |
| `--seed` | `2602` | 首个长度的随机种子；后续 case 自动递增 |
| `--model` | `rtl` | 使用 RTL contract 期望值；`python` 为普通 Python 模型 |
| `--backend` | `auto` | `auto` 等价于 `vectorized`；也可选严格但较慢的 `scalar` |
| `--resume` | 关闭 | 跳过 metadata、shape、seed 均匹配的完整 NPZ |

`--model=rtl --backend=vectorized` 是当前推荐组合；它保持 RTL 的 BF16
乘法、FP32 累加、LUT 插值和舍入顺序。`--backend=scalar` 主要用于调试，
不建议用它生成大长度全量 case。

### 0.2 在主机上运行 VCS board-case 回归

脚本默认使用本机 `lmg` 的 `27000@127.0.0.1` license 服务：

```bash
cd ~/git/LARA
SNPSLMD_LICENSE_FILE=27000@127.0.0.1 \
LM_LICENSE_FILE=27000@127.0.0.1 \
CLEAN_SIM_CACHE=1 \
bash VV/scripts/run_tb_attn_top_board_matrix.sh
```

默认回归结果应为 `10/10 PASS`。脚本会自动扫描 case 目录中的全部
`case_*.npz` 文件，并从每个 NPZ metadata 读取长度、causal 和位置参数。
`CLEAN_SIM_CACHE=1` 会先删除本脚本专用的
VCS 仿真目录、临时 case 目录和日志，避免中断运行留下的旧 `simv` 或 PASS
标记污染结果。license 服务位于另一台主机时，可把两个 license 变量改为例如
`27000@archlinux`。

回归脚本的常用配置参数：

| 参数 | 默认值 | 作用 |
|---|---|---|
| `CASE_ROOT` | `board_cases_rtl_contract_v2.6_fixed` | NPZ 用例目录；也可作为第一个位置参数传入 |
| `BOARD_CASE_LENGTHS` | 空 | 长度过滤；为空或 `all` 时运行目录中全部 case |
| 第二个位置参数 | 无 | 等价于设置 `BOARD_CASE_LENGTHS`，例如 `"1 16 32 64 128"` |
| `CASE_DIR_ROOT` | `/tmp/lara_board_matrix_vcs` | 每个 case 的 hex staging 目录 |
| `LOG_DIR` | `/tmp/lara_board_matrix_logs` | 每个 case 的 VCS 编译/运行日志目录 |
| `LOCK_DIR` | `/tmp/lara_board_matrix.lock` | 回归单实例锁，防止多个任务互相清理共享目录 |
| `CLEAN_SIM_CACHE` | `1` | 启动前清理 VCS/cache/staging/log；设为 `0` 可保留缓存，但必须确认没有旧结果污染 |
| `VCS_HEARTBEAT_SEC` | `10` | case 运行期间 Bash elapsed 心跳间隔，单位为秒 |
| `SNPSLMD_LICENSE_FILE` | `27000@127.0.0.1` | Synopsys license 服务地址 |
| `LM_LICENSE_FILE` | `27000@127.0.0.1` | 通用 FlexLM license 服务地址 |

例如将 VCS 心跳改为 20 秒，并只运行 L1-L128：

```bash
SNPSLMD_LICENSE_FILE=27000@127.0.0.1 \
LM_LICENSE_FILE=27000@127.0.0.1 \
CLEAN_SIM_CACHE=1 \
VCS_HEARTBEAT_SEC=20 \
bash VV/scripts/run_tb_attn_top_board_matrix.sh \
  board_cases_rtl_contract_v2.6_q31_kv7 \
  "1 16 32 64 128"
```

指定另一套位置 case 目录，自动运行目录中的全部用例：

```bash
SNPSLMD_LICENSE_FILE=27000@127.0.0.1 \
LM_LICENSE_FILE=27000@127.0.0.1 \
CLEAN_SIM_CACHE=1 \
bash VV/scripts/run_tb_attn_top_board_matrix.sh \
  board_cases_pos_q32_kv0
```

只运行一个 case：

```bash
CASE_PATH=board_cases_pos_q32_kv0/case_L16_q32_kv0_causal.npz \
CASE_DIR=/tmp/lara_case_q32_kv0_l16 \
BOARD_CASE_TEST_SEQ=16 \
BOARD_CASE_CAUSAL=1 \
bash VV/scripts/run_tb_attn_top_board_case.sh
```

脚本会优先从 NPZ metadata 读取 `q_pos_base` 和 `kv_pos_base`。确实需要覆盖
metadata 时，再显式设置 `BOARD_CASE_Q_POS_BASE` 和
`BOARD_CASE_KV_POS_BASE`。仿真日志位于 `/tmp/lara_board_matrix_logs/`。

### 0.3 复制 bitstream、驱动和 case 到 SD 卡

`.bit`、`.hwh`、`.xsa` 必须来自同一轮构建。联网时可用：

```bash
scp lara_attention.bit lara_attention.hwh lara_attention.xsa \
  ubuntu@<kv260-ip>:/home/ubuntu/lara/
scp sw/attn_driver.py sw/board_test.py sw/board_matrix.py \
  ubuntu@<kv260-ip>:/home/ubuntu/lara/
scp -r board_cases_v2.6 \
  ubuntu@<kv260-ip>:/home/ubuntu/lara/
```

直接更新 SD 卡时，将同样的文件复制到
`/home/ubuntu/lara/`；不要只替换 `.bit` 而保留旧 `.hwh/.xsa`，也不要把
不同构建的文件混用。复制后在板上先执行：

```bash
cd /home/ubuntu/lara
sha256sum -c LARA_SHA256SUMS
```

### 0.4 SD 卡启动后的板上测试

每次重启后先进入 PYNQ 环境、插入 device-tree overlay 并确认 XRT device ready：

```bash
sudo -i
source /etc/profile.d/pynq_venv.sh
python3 -c 'import pynq; print(pynq.__file__)'
python3 /usr/local/share/pynq-venv/pynq-dts/insert_dtbo.py
xbutil examine
cd /home/ubuntu/lara
```

`xbutil examine` 的 `Device Ready` 应为 `Yes`。`insert_dtbo.py` 出现 IRQ
warning 时，不能单独据此判定失败；以 device ready、Overlay 加载和后续测试
结果为准。

先运行零输入 smoke：

```bash
python3 board_test.py \
  --bitstream ./lara_attention.bit \
  --seq-len 1 \
  --profile-json smoke_l1.json
```

再运行一个 raw-BF16 bit-exact case：

```bash
python3 board_test.py \
  --bitstream ./lara_attention.bit \
  --seq-len 1 \
  --npz ./board_cases_v2.6/case_L1_q3_kv3_causal.npz \
  --expected-npz ./board_cases_v2.6/case_L1_q3_kv3_causal.npz \
  --q-pos-base 3 \
  --kv-pos-base 3 \
  --causal \
  --profile-json exact_L1.json
```

noncausal case 使用 `--non-causal`：

```bash
python3 board_test.py \
  --bitstream ./lara_attention.bit \
  --npz ./board_cases_v2.6/case_L16_q3_kv3_noncausal.npz \
  --expected-npz ./board_cases_v2.6/case_L16_q3_kv3_noncausal.npz \
  --seq-len 16 \
  --q-pos-base 3 \
  --kv-pos-base 3 \
  --non-causal \
  --profile-json exact_L16_noncausal.json
```

最后运行整个目录的板上矩阵：

```bash
python3 board_matrix.py \
  --bitstream ./lara_attention.bit \
  --cases ./board_cases_v2.6 \
  --output-dir ./board_results_v2.6
```

只有 `summary.json` 中所有 case 都是 `PASS`，并且实际输出、profile、
`manifest.json` 和输入归档均已保存，才算板上矩阵通过。

### 0.5 split-16 v4 的 76/71 MHz 构建与回归

2026-08-06 的当前 split-16 候选已从 v5 commit-cone 回退到 v4 acc-base
实现。v4/v5 RTL、综合网表、DCP 和报告保存在
`checkpoint/20260806-split16-v4-v5-rtl/`。`76.923 MHz` 请求在 KV260 上实际
生成 `76.922310 MHz`，但最终 route 为 WNS `-0.191 ns`、TNS
`-39.719 ns`，因此没有生成 bitstream。当前默认已切换为请求 `72.000 MHz`，
实际 `71.427856 MHz`，时钟周期约 `14.000 ns`。对应 clean Explore build 已
通过 post-route 签核：WNS `+0.171 ns`、TNS `0`、WHS `+0.010 ns`、THS `0`，
fully routed、routing errors 和 DRC errors 均为 `0`。

K26 PL0 使用整数分频，不能精确生成 75 MHz。76.922310 MHz 已确认不收敛，
当前三处 active 设置为：

```text
hw/scripts/vivado_build.tcl: FCLK_MHZ 72.000
sw/attn_driver.py:           PL_CLOCK_MHZ 71.427856
sw/benchmark.py:             FREQ_MHZ 71.427856
```

Vivado Tcl 使用请求值，软件 profile 和 benchmark 必须使用实际频率；三处配置
必须成对切换。76.922310 MHz 旧值在相邻注释中保留用于结果追溯。

仅修改 PL 时钟时，VCS 周期级功能仿真结果不会变化，因此不强制重跑 VCS。需要
重新留存回归证据时，依次运行，不能并行复用同一个仿真缓存：

```bash
cd /home/jiao/git/LARA

SNPSLMD_LICENSE_FILE=27000@127.0.0.1 \
LM_LICENSE_FILE=27000@127.0.0.1 \
CLEAN_SIM_CACHE=1 \
VCS_HEARTBEAT_SEC=20 \
bash VV/scripts/run_tb_attn_top_board_matrix.sh \
  board_cases_rtl_contract_v2.6_q31_kv7 \
  "1 16 32 64 128"

SNPSLMD_LICENSE_FILE=27000@127.0.0.1 \
LM_LICENSE_FILE=27000@127.0.0.1 \
CLEAN_SIM_CACHE=1 \
VCS_HEARTBEAT_SEC=20 \
bash VV/scripts/run_tb_attn_top_board_matrix.sh \
  board_cases_rtl_contract_v2.6_fixed \
  "1 16 32 64 128"
```

`board_cases_v2.6` 中 L1-L128 的输入为 q3/kv3，但其 expected output 是旧版本；
除 L1 外，它与当前 VCS 通过的 `board_cases_rtl_contract_v2.6_fixed` 不同。该目录
另外包含两个 q0/kv0 的 L512 case。若需要原样复现旧目录，可运行：

```bash
SNPSLMD_LICENSE_FILE=27000@127.0.0.1 \
LM_LICENSE_FILE=27000@127.0.0.1 \
CLEAN_SIM_CACHE=1 \
VCS_HEARTBEAT_SEC=20 \
bash VV/scripts/run_tb_attn_top_board_matrix.sh \
  board_cases_v2.6 \
  "1 16 32 64 128"
```

76.922310 MHz 完整构建：

```bash
cd /home/jiao/git/LARA
LARA_BUILD_TAG=20260806T_v4_76p922MHz \
LARA_ROUTE_DIRECTIVE=Explore \
bash hw/scripts/vivado_build.sh
```

切换三处 fallback 后，71.427856 MHz 完整构建使用独立目录：

```bash
cd /home/jiao/git/LARA
LARA_BUILD_TAG=20260806T_v4_71p428MHz \
LARA_ROUTE_DIRECTIVE=Explore \
bash hw/scripts/vivado_build.sh
```

新 bitstream 上板时必须同时替换同一构建目录中的 `.bit/.hwh/.xsa`，并同步当前
`attn_driver.py`。板上运行两套目录：

```bash
cd /home/ubuntu/lara

python3 board_matrix.py \
  --bitstream ./lara_attention.bit \
  --cases ./board_cases_rtl_contract_v2.6_q31_kv7 \
  --output-dir ./board_results_q31_kv7 \
  --timeout-ms 300000

python3 board_matrix.py \
  --bitstream ./lara_attention.bit \
  --cases ./board_cases_v2.6 \
  --output-dir ./board_results_v2p6 \
  --timeout-ms 300000
```

正式 q3/kv3 bit-exact 板测应将第二条命令的 cases 改为
`board_cases_rtl_contract_v2.6_fixed`。

## 1. 交付物

从 accepted P4 routed DCP 导出后，部署目录包含：

```text
vivado_proj/p4-explore-deploy/lara_attention.bit
vivado_proj/p4-explore-deploy/lara_attention.hwh
vivado_proj/p4-explore-deploy/lara_attention.xsa
vivado_proj/p4-explore-deploy/reports/post_route_timing_summary.rpt
vivado_proj/p4-explore-deploy/reports/post_route_status.rpt
vivado_proj/p4-explore-deploy/reports/post_route_utilization.rpt
vivado_proj/p4-explore-deploy/reports/post_route_drc.rpt
```

导出脚本还会在同一目录生成 `SHA256SUMS`。`.bit`、`.hwh` 与 `.xsa` 必须来自
同一份 routed DCP 并保持同名，否则 PYNQ Overlay 可能加载错误的硬件元数据。
当前脚本不会自动复制软件文件；上板时应把 `sw/board_test.py`、`sw/attn_driver.py`
和本指南一并复制。

## 2. 构建与打包

当前 P4 板测首先执行以下导出命令。它只打开 accepted routed DCP、重生成签核报告
并导出部署文件，不重新综合、布局或布线：

```bash
bash hw/scripts/export_p4_explore_deploy.sh
sha256sum -c vivado_proj/p4-explore-deploy/SHA256SUMS
```

导出门禁必须满足 WNS/WHS 非负、routing 完成且 DRC Error 为 0。当前 P4
Explore 证据的 WNS 为 `+0.021 ns`、WHS 为 `+0.010 ns`、144158/144158 nets
fully routed、DRC Error severity 为 `0`。导出后仍应以
`p4-explore-deploy/reports/` 中本轮报告为准。

如果修改了 RTL、XDC、BD 或构建脚本，不能继续使用这个 DCP，必须从 clean
Vivado build 重新生成 matching synthesis/place/phys_opt/route 结果：

```bash
bash hw/scripts/vivado_build.sh
```

该完整流程使用 Vivado 2025.2、KV260 `xck26-sfvc784-2LV-c` 和 83.333 MHz
PL 时钟；只有本轮 timing/DRC 门禁通过的结果才能作为新的部署来源。不要用会
重置 `impl_1` 的 `vivado_continue_impl.tcl`，也不要用要求旧
`physopt.dcp` 的恢复脚本替代当前 P4 导出流程。

如果已有 routed implementation，只需重新生成签核报告，可执行：

```bash
vivado -mode batch -source hw/scripts/vivado_report_signoff.tcl
```

已有部署文件的哈希检查：

```bash
cd vivado_proj/p4-explore-deploy
sha256sum -c SHA256SUMS
```

当前 P4 accepted Explore 结果为 post-route WNS `+0.021 ns`、WHS `+0.010 ns`、
TNS/THS `0`、144158/144158 routable nets fully routed、routing errors `0`、
DRC Error severity `0`；对应 routed DCP 和报告位于
`checkpoint/v2.5-p4-architecture-dse/candidate1-streaming-pv/`。本轮 default
route 的 WNS `-0.110 ns` 已拒绝，不能从它发布 bitstream。当前尚未完成
KV260 实板验证；导出后的部署文件必须以
`vivado_proj/p4-explore-deploy/` 本轮报告和哈希为准。

## 3. KV260 启动前检查

按照 AMD UG1089/DS986，先确认以下硬件条件：

1. KV260 使用与当前镜像匹配的 microSD 卡，启动模式设置为从 SD 启动。
2. 使用稳定电源和散热，连接 USB-UART；串口通常为 `115200 8N1`，以实际镜像
   启动输出为准。
3. 通过 Ethernet 将板卡接入与主机可达的网络，记录板卡 IP；不要在未知 IP
   时反复加载 overlay。
4. 板卡完成启动后确认 PL 时钟、内存和 PYNQ/运行时环境可用：

```bash
uname -a
cat /etc/os-release
python3 -c 'import pynq; print(pynq.__file__)'
ip -br addr
```

如果 `pynq` 不存在，先使用项目目标镜像或安装与镜像匹配的 PYNQ 运行时；不要
假设任意 Kria Linux 镜像都能运行 `Overlay`。记录板卡型号、镜像版本、
PYNQ 版本、Vivado 版本、PL 频率和温度，作为每次板测的环境元数据。

## 4. 离线 PYNQ 环境与 SD 卡部署

本项目使用精简的 PYNQ runtime，不运行原始 `Kria-PYNQ/install.sh`。原始脚本会
联网安装 Debian、Jupyter、DPU 和 Composable Pipeline 组件，不适合当前没有
网线或希望保持最小环境的 KV260 镜像。

### 4.1 宿主机准备离线资源

在宿主机项目根目录执行：

```bash
cd ~/git/LARA
bash sw/prepare_kv260_pynq_offline.sh \
  ~/Downloads/kv260-pynq-runtime-20260806
```

脚本接受一个可选的宿主机输出根目录参数：

```bash
bash sw/prepare_kv260_pynq_offline.sh /path/to/kv260-pynq-offline
```

无论使用默认目录还是自定义目录，脚本都会在该目录下生成完整的
`sd-bundle/`。例如：

```text
/path/to/kv260-pynq-offline/sd-bundle/
```

因此，`prepare_kv260_pynq_offline.sh` 的参数是“生成资源的宿主机目录”，不是
SD 卡挂载点，也不是板上 PYNQ 虚拟环境目录。输出目录可以位于其他磁盘或挂载
目录，但当前用户必须具有写权限，并且目录所在文件系统需要容纳约 300 MB
资源。默认输出目录为：

```text
~/Downloads/kv260-pynq-offline/sd-bundle/
```

脚本会自动完成以下工作：

1. 执行 `git clone --recurse-submodules --branch main` 获取 `Kria-PYNQ`；
2. 使用 `wget` 下载并校验 `pynq-3.0.1.tar.gz` 和
   `pynq-v3.0-binaries.tar.gz`；
3. 编译 `pynq.dtbo`；
4. 下载 Python 3.10/aarch64 wheel，包括 PYNQ 核心依赖和 IPython；
5. 复制板上自动离线安装脚本；
6. 生成并验证 `OFFLINE_SHA256SUMS`。

该目录只包含 PYNQ runtime 离线安装资源，不绑定任何一版 LARA RTL。应再通过
`sw/package_kv260_board.sh` 将它与当前签核 build、正式 case 和测试脚本组成统一
payload。runtime bundle 通常约 220 MB；为解压和文件
系统开销，建议 SD 卡第二分区至少预留 300 MB。宿主机需要
`git`、`wget`、`python3-pip`、`tar`、`sha256sum`；若没有 `dtc`，脚本会尝试
使用 Docker 编译 device-tree overlay。脚本不会读取或修改 `~/.zshrc`，不会
修改 Synopsys license 环境，也不会执行 `git add/commit/push`。

生成完成后，在宿主机先验证 bundle：

```bash
cd /path/to/kv260-pynq-offline/sd-bundle
sha256sum -c OFFLINE_SHA256SUMS
```

### 4.2 不联网复制到 SD 卡

确认 SD 卡设备后，只挂载第二个 ext4 分区。不要向 `system-boot` 分区复制，
也不要修改 QSPI：

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS
sudo mkdir -p /mnt/kv260
sudo mount /dev/sdb2 /mnt/kv260
sudo mkdir -p /mnt/kv260/home/ubuntu/kv260-pynq-offline
sudo cp -a /path/to/kv260-pynq-offline/sd-bundle/. \
  /mnt/kv260/home/ubuntu/kv260-pynq-offline/
sync
sudo umount /mnt/kv260
```

其中 `/path/to/kv260-pynq-offline/sd-bundle` 替换为实际生成的 bundle 目录，
例如 `~/Downloads/kv260-pynq-offline/sd-bundle`。复制的是 `sd-bundle` 的内容，
不是再嵌套一层 `sd-bundle` 目录；板上最终应直接看到 `src/`、`wheels/`、
`Kria-PYNQ/`、`scripts/` 和 `OFFLINE_SHA256SUMS`。

如果设备名不是 `/dev/sdb2`，以 `lsblk` 实际结果替换。SD 卡第二分区至少应有
约 300 MB 可用空间。

### 4.3 KV260 离线安装

板卡启动后执行：

```bash
cd /home/ubuntu/kv260-pynq-offline
sha256sum -c OFFLINE_SHA256SUMS
sudo bash scripts/kv260_pynq_offline_install.sh "$PWD"
source /etc/profile.d/pynq_venv.sh
python3 -c 'import pynq; print(pynq.__file__)'
```

`kv260_pynq_offline_install.sh` 的第一个参数是 bundle 根目录，可以指定任意
板上可读的路径：

```bash
sudo bash /home/ubuntu/kv260-pynq-offline/scripts/kv260_pynq_offline_install.sh \
  /home/ubuntu/kv260-pynq-offline
```

该目录必须直接包含以下结构：

```text
/home/ubuntu/kv260-pynq-offline/
├── src/
├── wheels/
├── Kria-PYNQ/dts/
└── scripts/kv260_pynq_offline_install.sh
```

建议始终显式传入 `"$PWD"`。如果省略第一个参数，脚本默认把自身所在的
`scripts/` 目录当作 bundle 根目录；对于本指南的标准 `sd-bundle` 布局，这会
找不到同级的 `src/` 和 `wheels/`。安装脚本的 bundle 参数不会改变板上的安装
目标：默认 PYNQ 虚拟环境仍为 `/usr/local/share/pynq-venv`，默认 notebook
目录仍为 `/home/ubuntu/jupyter_notebooks`。

如确实需要修改安装目标，可以通过环境变量指定：

```bash
sudo PYNQ_VENV=/opt/pynq-venv \
  PYNQ_JUPYTER_NOTEBOOKS=/opt/pynq-notebooks \
  bash /home/ubuntu/kv260-pynq-offline/scripts/kv260_pynq_offline_install.sh \
  /home/ubuntu/kv260-pynq-offline
```

预期最后一条命令输出 PYNQ 包路径，且安装器输出：

```text
PYNQ import PASS: ...
PYNQ Overlay/allocate imports PASS
```

该离线安装器使用 bundled `virtualenv`，不要求板上安装
`python3.10-venv`；同时安装 PYNQ 3.0.1 所需的 ARM64 NumPy/CFFI、metadata、
utils 和 IPython 依赖。`pydantic` 固定为 1.10.13，避免 PYNQ 3.0.1 被新版本
Pydantic 2 破坏。

### 4.4 插入 PYNQ device-tree overlay

每次重新启动后，在第一次使用 XRT/PYNQ 前插入 overlay：

```bash
sudo -i
source /etc/profile.d/pynq_venv.sh
python3 /usr/local/share/pynq-venv/pynq-dts/insert_dtbo.py
xbutil examine
```

如果 `insert_dtbo.py` 报 configfs 不存在，先检查：

```bash
mount | grep configfs || sudo mount -t configfs configfs /sys/kernel/config
```

不要执行 `xmutil bootfw_update`；当前 Ubuntu 22.04/QSPI 启动状态正常时，PYNQ
runtime 安装不需要修改 QSPI。

## 5. 电脑网口、静态地址与网桥/NAT

有网线时，推荐使用主机的 Wi-Fi/有线上行接口做 NAT，让 KV260 通过主机联网。
没有网线时，本节全部跳过，直接使用上一节的 SD 卡离线流程。

### 5.1 串口连接和接口识别

宿主机先查看 USB 串口和网口：

```bash
ls -l /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || true
ip -br addr
```

常见串口连接方式：

```bash
sudo minicom -D /dev/ttyUSB1 -b 115200
```

KV260 串口参数为 `115200 8N1`。如果设备不是 `ttyUSB1`，使用实际枚举出来的
节点。Minicom 退出通常使用 `Ctrl-A`、`X`。

假设：

```text
主机连接 KV260 的网口：enpYYY
主机上网的接口：wlpXXX 或 ethXXX
主机静态地址：192.168.2.1/24
KV260 静态地址：192.168.2.100/24
```

实际接口名必须以 `ip -br addr` 为准。

### 5.2 主机配置静态网口和 NAT

以下配置是临时配置，重启后会丢失：

```bash
sudo ip addr flush dev enpYYY
sudo ip addr add 192.168.2.1/24 dev enpYYY
sudo ip link set enpYYY up

sudo sysctl -w net.ipv4.ip_forward=1
sudo iptables -t nat -A POSTROUTING -o wlpXXX -j MASQUERADE
sudo iptables -A FORWARD -i enpYYY -o wlpXXX -j ACCEPT
sudo iptables -A FORWARD -i wlpXXX -o enpYYY \
  -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
```

把 `enpYYY` 替换成接 KV260 的网口，把 `wlpXXX` 替换成主机实际的上行接口。
如果只是需要主机和板卡互通，可以只执行静态地址配置和前三条命令，不启用 NAT。

### 5.3 KV260 配置静态地址

在 KV260 串口中确认接口名：

```bash
ip -br addr
```

常见接口名是 `eth0`，但应以实际输出为准：

```bash
sudo ip addr flush dev eth0
sudo ip addr add 192.168.2.100/24 dev eth0
sudo ip link set eth0 up
sudo ip route replace default via 192.168.2.1
echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf
```

验证：

```bash
ping -c 2 192.168.2.1
ping -c 2 8.8.8.8
```

第一个失败说明静态链路或接口名错误；第一个成功、第二个失败说明主机
转发/NAT未配置。NetworkManager 管理的系统若需要持久化，可改用：

```bash
sudo nmcli con add type ethernet ifname eth0 con-name kv260-static \
  ipv4.method manual ipv4.addresses 192.168.2.100/24 \
  ipv4.gateway 192.168.2.1 ipv4.dns 8.8.8.8
sudo nmcli con up kv260-static
```

### 5.4 有网线时的 SSH/SCP 备用路径

网络验证通过后可使用：

```bash
ssh ubuntu@192.168.2.100
scp -r ~/Downloads/kv260-pynq-offline/sd-bundle/. \
  ubuntu@192.168.2.100:/home/ubuntu/kv260-pynq-offline/
```

如果出现 `REMOTE HOST IDENTIFICATION HAS CHANGED`，确认 IP 确实属于当前
KV260 后，再删除对应旧记录：

```bash
ssh-keygen -R 192.168.2.100
```

离线 SD 卡路径优先级高于 SCP；两种方式不要同时覆盖同一个正在使用的
`pynq-venv`。

## 6. 拷贝到板卡

将导出目录和软件验证文件拷贝到 KV260，例如：

```bash
scp -r vivado_proj/p4-explore-deploy root@<kv260-ip>:/home/root/lara_attention/
ssh root@<kv260-ip> 'mkdir -p /home/root/lara_attention/sw'
scp sw/board_test.py sw/attn_driver.py sw/generate_board_cases.py sw/board_matrix.py \
  root@<kv260-ip>:/home/root/lara_attention/sw/
scp docs/kv260_board_validation.md \
  root@<kv260-ip>:/home/root/lara_attention/
ssh root@<kv260-ip>
cd /home/root/lara_attention/p4-explore-deploy
sha256sum -c SHA256SUMS
```

加载 overlay 的方式取决于镜像。若镜像提供 `xmutil`，先确认没有 DMA/旧
overlay 正在使用，再加载与文件同名的应用：

```bash
xmutil listapps
xmutil unloadapp 2>/dev/null || true
xmutil loadapp /home/root/lara_attention/p4-explore-deploy/lara_attention
```

如果该镜像的 `xmutil loadapp` 只接受已安装的 firmware 应用名，应按该镜像的
`xmutil` 帮助或已有应用安装流程部署，不要把路径参数当成通用语法。PYNQ
环境可直接从 `.bit` 路径创建 `Overlay`，对应 `.hwh` 必须放在同一目录：

```bash
cd /home/root/lara_attention/p4-explore-deploy
python3 -c 'from pynq import Overlay; Overlay("./lara_attention.bit"); print("overlay load PASS")'
```

不要在 DMA 尚未停止时覆盖当前 overlay，也不要在 PL reset 期间启动 DMA。

## 7. 数据格式与控制顺序

driver 的输入是 head-major 的 bf16 原始 16-bit words：

```text
Q: [32, seq_len, 128]
K: [ 8, seq_len, 128]
V: [ 8, seq_len, 128]
O: [32, seq_len, 128]
```

AXI4-Stream 每个 32-bit beat 携带两个 bf16，低 16 位先进入片上存储，高 16 位在下一周期进入。所有 DMA 字节数必须是 4 的倍数。

一次 attention transaction 的软件/硬件协同顺序是：

1. driver 写入 `seq_len`、位置 base、causal 配置和 `result_len`。
2. driver 先启动 S2MM 接收，避免 output source 先产生数据而被 back-pressure。
3. driver 写 `CTRL.start`，这是单周期 W1P 命令。
4. core 通过 `CSR_LOAD_REQ` 请求当前 GQA group 的 K/V；driver 各发送一次。一个 KV head 被同组 4 个 Q heads 复用，不重复发送 K/V。
5. core 请求 Q tile；driver 发送一个固定 32×128 tile，最后不足 32 行的部分以零填充，`active_q_rows` 由 core 控制有效计算范围。
6. driver 轮询 `STATUS`，持续服务 K/V/Q 请求并检查 sticky error。
7. 最终 output source 通过同一条 S2MM DMA 写回完整 O；driver 等待 `done` 和 DMA 完成后读取结果。

`CSR_STREAM_LEN` 只配置 PL 侧长度检查，不会隐式启动 DMA。DMA 的启动归属 PYNQ driver。这样可以明确区分 AXI-Lite 控制事务和 AXI-Stream bulk tensor 事务。

## 8. 零输入 Smoke Test

`sw/board_test.py` 提供不依赖模型权重的控制链验证。全零 Q/K/V 的正确
attention 输出应为全零。先在板上直接运行：

```bash
cd /home/root/lara_attention
PYTHONPATH="$PWD/sw" python3 sw/board_test.py \
  --bitstream p4-explore-deploy/lara_attention.bit \
  --seq-len 16 \
  --profile-json p4-explore-deploy/profile_zero_L16.json
```

通过标准：

- Overlay 加载成功；
- AXI-Lite 可写配置、接受一次 start；
- driver 能看到并服务 KV/Q load request；
- DMA 接收完成且 output `TLAST` 到达；
- 输出全为零；
- 无 timeout、`error` 或 `stream_error`。

## 9. 使用预计算 Q/K/V 验证数值

`sw/generate_board_cases.py` 生成的 NPZ 是板上和 VCS 共用的输入/期望文件。
每个 case 包含以下数组和 metadata：

```text
q_heads: uint16 [32, L, 128]
k_heads: uint16 [ 8, L, 128]
v_heads: uint16 [ 8, L, 128]
expected_o: uint16 [32, L, 128]
seq_len, causal, q_pos_base, kv_pos_base, seed
```

如果使用自定义 NPZ，至少需要提供前四个数组；数组必须是 raw BF16
16-bit words，不是 float32。直接在板上运行单个 case：

```bash
cd /home/ubuntu/lara
python3 board_test.py \
  --bitstream ./lara_attention.bit \
  --seq-len 64 \
  --npz ./board_cases_v2.6/case_L64_q3_kv3_causal.npz \
  --expected-npz ./board_cases_v2.6/case_L64_q3_kv3_causal.npz \
  --q-pos-base 3 \
  --kv-pos-base 3 \
  --causal \
  --profile-json ./exact_L64.json
```

`--expected-npz` 必须包含 `expected_o` 或 `o_heads`，shape 为
`[32, L, 128]`、dtype 为 `uint16`，表示 raw bf16 bits。建议由
`python_godel/attention_golden.py` 在相同 bf16 输入、causal 配置和位置 base
下生成参考结果。板上测试必须逐元素比较 raw bits；不要只比较均值或容差。
出现首个 mismatch 时保存输入、期望输出、实际输出和 profile，再停止后续优化。

## 10. 批量 P5 测试

### 10.1 生成测试用例

在主机项目根目录生成默认 q3/kv3 测试集：

```bash
cd ~/git/LARA
python3 sw/generate_board_cases.py \
  --output-dir board_cases_v2.6 \
  --lengths 1 16 32 64 128 512 \
  --include-noncausal \
  --q-pos-base 3 \
  --kv-pos-base 3
```

`MAX_SEQ_LEN=512` 只限制 tensor 的序列长度，不限制绝对位置 base。位置寄存器为
16 bit，因此要求 `q_pos_base + seq_len <= 65536` 且
`kv_pos_base + seq_len <= 65536`。生成器不会静默修改用户指定的 base；超出范围
会直接报错。中断后可在同一目录使用 `--resume` 跳过 metadata、shape 和 seed
均匹配的完整 case。

为了覆盖绝对位置和 causal 边界，建议至少另外生成以下场景：

```bash
# Q 比 K/V 晚一个 32-token tile
python3 sw/generate_board_cases.py \
  --output-dir board_cases_pos_q32_kv0 \
  --lengths 1 16 32 64 128 \
  --include-noncausal \
  --q-pos-base 32 \
  --kv-pos-base 0 \
  --seed 3600

# Q 位于 K/V 之前，覆盖 causal 全 mask/跳过 tile 路径
python3 sw/generate_board_cases.py \
  --output-dir board_cases_pos_q0_kv32 \
  --lengths 1 16 32 64 128 \
  --include-noncausal \
  --q-pos-base 0 \
  --kv-pos-base 32 \
  --seed 3700

# 非相等且跨 tile 的绝对位置
python3 sw/generate_board_cases.py \
  --output-dir board_cases_pos_q64_kv32 \
  --lengths 16 32 64 128 \
  --include-noncausal \
  --q-pos-base 64 \
  --kv-pos-base 32 \
  --seed 3800
```

每个输出目录建议只放一套位置参数的 case。生成完成后检查：

```bash
find board_cases_pos_q32_kv0 -maxdepth 1 -name 'case_*.npz' -print | sort
python3 - <<'PY'
import numpy as np
from pathlib import Path

for path in sorted(Path("board_cases_pos_q32_kv0").glob("case_*.npz")):
    with np.load(path) as data:
        print(path.name, "q=", int(data["q_pos_base"]),
              "kv=", int(data["kv_pos_base"]),
              "causal=", int(data["causal"]))
PY
```

### 10.2 VCS board-case 仿真

`VV/scripts/run_tb_attn_top_board_matrix.sh` 会从指定目录自动发现所有
`case_*.npz`，从每个 NPZ 的 metadata 读取序列长度、causal 模式和
`q_pos_base/kv_pos_base`，然后传给 board-case testbench。默认目录通常覆盖
L1/L16/L32/L64/L128 的 causal 和 noncausal 两种模式：

```bash
cd ~/git/LARA
SNPSLMD_LICENSE_FILE=27000@archlinux \
LM_LICENSE_FILE=27000@archlinux \
CLEAN_SIM_CACHE=1 \
bash VV/scripts/run_tb_attn_top_board_matrix.sh
```

期望结果：

```text
Board-case summary: 10/10 PASS
ALL DISCOVERED BOARD CASES PASSED
```

运行其他位置场景时只需把 case 目录作为第一个参数：

```bash
SNPSLMD_LICENSE_FILE=27000@127.0.0.1 \
LM_LICENSE_FILE=27000@127.0.0.1 \
CLEAN_SIM_CACHE=1 \
bash VV/scripts/run_tb_attn_top_board_matrix.sh \
  board_cases_pos_q32_kv0
```

如果目录中包含 L512 或其他长度，无需修改脚本，会自动加入回归。若只想
筛选某些长度，可用第二个参数或 `BOARD_CASE_LENGTHS`：

```bash
SNPSLMD_LICENSE_FILE=27000@127.0.0.1 \
LM_LICENSE_FILE=27000@127.0.0.1 \
CLEAN_SIM_CACHE=1 \
bash VV/scripts/run_tb_attn_top_board_matrix.sh \
  board_cases_rtl_contract_v2.6_q31_kv7 \
  "1 16 32 64 128"
```

建议每个目录只保存一套位置参数的 case，避免同一目录中出现多个不同版本的
同名测试语义。脚本按完整文件名建立独立日志和临时目录，因此同一目录中
可以同时保留多个长度和 causal/noncausal case。

`CLEAN_SIM_CACHE=1` 会删除本次 board-case 专用的 VCS 仿真目录、临时 case
目录和日志目录。不要在另一份 board matrix 仍运行时启动该命令。
脚本带有单实例锁；如果已有回归运行，新的启动会直接拒绝，避免共享
`sim.log`、VCS work directory 和日志被互相清理。
每个 case 默认每 10 秒输出一次 elapsed heartbeat；可通过
`VCS_HEARTBEAT_SEC=20` 调整间隔。该进度显示由 Bash 负责，不在 RTL
仿真中增加周期级 `$display`。

如需只运行一个 VCS case：

```bash
CASE_PATH=board_cases_pos_q32_kv0/case_L16_q32_kv0_causal.npz \
CASE_DIR=/tmp/lara_case_q32_kv0_l16 \
BOARD_CASE_TEST_SEQ=16 \
BOARD_CASE_CAUSAL=1 \
bash VV/scripts/run_tb_attn_top_board_case.sh
```

单 case 脚本的常用参数如下：

| 参数 | 默认值 | 作用 |
|---|---|---|
| `CASE_PATH` | `board_cases_v2.6/case_L128_q3_kv3_causal.npz` | 输入 NPZ 文件 |
| `CASE_DIR` | `/tmp/lara_case_l128` | 转换后的 `q.hex/k.hex/v.hex/expected.hex` 目录 |
| `BOARD_CASE_TEST_SEQ` | `128` | testbench 编译时的序列长度 |
| `BOARD_CASE_CAUSAL` | `1` | causal 开关 |
| `BOARD_CASE_Q_POS_BASE` | 从 NPZ metadata 读取，否则 `3` | Q 绝对位置基址 |
| `BOARD_CASE_KV_POS_BASE` | 从 NPZ metadata 读取，否则 `3` | K/V 绝对位置基址 |
| `ACTUAL_PATH` | 未设置 | 可选，保存实际输出 raw BF16 words |
| `XPM_SV` | Vivado XPM 默认路径 | XPM memory simulation source |
| `LARA_BOARD_CASE_DEFINES` | 空 | 额外传给 VCS 的 `+define` |

该脚本会自动读取 NPZ 中的 q/kv position；也可以显式覆盖：

```bash
BOARD_CASE_Q_POS_BASE=32 \
BOARD_CASE_KV_POS_BASE=0 \
CASE_PATH=board_cases_pos_q32_kv0/case_L16_q32_kv0_causal.npz \
CASE_DIR=/tmp/lara_case_override \
BOARD_CASE_TEST_SEQ=16 \
bash VV/scripts/run_tb_attn_top_board_case.sh
```

仿真日志默认位于 `/tmp/lara_board_matrix_logs/`。XPM 的
`MEMORY_INIT_FILE`、`MEMORY_PRIMITIVE` 信息通常是启动提示，不等价于失败；
应以 `BOARD CASE PASS`、`MISMATCH`、`Fatal` 和 timeout 为准。

### 10.3 复制 case 到 SD 卡

将 bitstream、驱动和 case 一起放到板上的工作目录，例如：

```bash
scp lara_attention.bit lara_attention.hwh lara_attention.xsa \
  ubuntu@<kv260-ip>:/home/ubuntu/lara/
scp sw/attn_driver.py sw/board_test.py sw/board_matrix.py \
  ubuntu@<kv260-ip>:/home/ubuntu/lara/
scp -r board_cases_v2.6 board_cases_pos_q32_kv0 \
  ubuntu@<kv260-ip>:/home/ubuntu/lara/
```

如果使用 SD 卡直接更新，复制上述同样的文件到
`/home/ubuntu/lara/`，不要混用不同构建产生的 `.bit/.hwh/.xsa`。

### 10.4 板上批量测试

```bash
cd /home/ubuntu/lara
python3 board_matrix.py \
  --bitstream ./lara_attention.bit \
  --cases ./board_cases_v2.6 \
  --output-dir ./board_results_v2.6
```

运行新位置场景：

```bash
python3 board_matrix.py \
  --bitstream ./lara_attention.bit \
  --cases ./board_cases_pos_q32_kv0 \
  --output-dir ./board_results_pos_q32_kv0
```

只有 `board_results_v2.6/summary.json` 中所有 case 为 `PASS`，并且 profile、
实际输出、输入/期望 NPZ、`manifest.json` 和部署文件 SHA-256 均已保存，P5
才算完成。没有板卡时只运行生成器和 mock 测试，不能将 mock 结果当作板上结论。

### 10.5 SD 卡启动后的完整命令顺序

以下命令适用于当前板上目录 `/home/ubuntu/lara`。如果部署包带有
`LARA_SHA256SUMS`，先在普通用户 shell 校验：

```bash
cd /home/ubuntu/lara
sha256sum -c LARA_SHA256SUMS
```

每次重新启动后，在第一次加载 overlay 前执行：

```bash
sudo -i
source /etc/profile.d/pynq_venv.sh
python3 -c 'import pynq; print(pynq.__file__)'
python3 /usr/local/share/pynq-venv/pynq-dts/insert_dtbo.py
xbutil examine
cd /home/ubuntu/lara
```

`xbutil examine` 应显示 KV260 device `Ready: Yes`。`insert_dtbo.py` 可能打印
XRT/ZOCL 的 IRQ warning；只要 device ready 且后续 Overlay 可以加载，不能仅凭
这一行判定失败。

先运行零输入控制链 smoke：

```bash
python3 board_test.py \
  --bitstream ./lara_attention.bit \
  --seq-len 1 \
  --profile-json smoke_l1.json
```

再运行一个带预计算期望值的 bit-exact case：

```bash
python3 board_test.py \
  --bitstream ./lara_attention.bit \
  --seq-len 1 \
  --npz ./board_cases_v2.6/case_L1_q3_kv3_causal.npz \
  --expected-npz ./board_cases_v2.6/case_L1_q3_kv3_causal.npz \
  --q-pos-base 3 \
  --kv-pos-base 3 \
  --causal \
  --profile-json exact_L1.json
```

最后运行完整板上矩阵：

```bash
python3 board_matrix.py \
  --bitstream ./lara_attention.bit \
  --cases ./board_cases_v2.6 \
  --output-dir ./board_results_v2.6
```

更换测试目录即可测试其他绝对位置场景：

```bash
python3 board_matrix.py \
  --bitstream ./lara_attention.bit \
  --cases ./board_cases_pos_q32_kv0 \
  --output-dir ./board_results_pos_q32_kv0
```

板上数值验证必须在能访问 PYNQ MMIO 的 root shell 中执行。完成后检查：

```bash
cat ./board_results_v2.6/summary.json
cat ./board_results_v2.6/manifest.json
find ./board_results_v2.6 -maxdepth 1 -name '*_profile.json' -print
```

## 11. 宿主机 QKV Projection 一体化入口

应用程序可以调用：

```python
from sw.attn_driver import AttentionAccelerator

accel = AttentionAccelerator("lara_attention.bit")
output = accel.run_layer(
    hidden_states, Wq, Wk, Wv,
    rms_weight=rms_gamma,
    q_pos_base=0,
    kv_pos_base=0,
    causal=True,
)
```

该入口执行：

```text
hidden states -> host RMSNorm -> host Q/K/V projection -> host RoPE
              -> head-major bf16 -> DMA/request-service -> FPGA attention
              -> DMA output -> token-major fp32 container
```

PYNQ buffer 由 `allocate` 创建。driver 在 PS 写入输入后调用 `flush()`，接收完成后调用 `invalidate()`（若平台对象提供这些方法），避免 cache coherency 造成“DMA 已完成但数据仍旧”的假通过。

## 12. 推荐的板上测试矩阵

在零输入通过后，按以下顺序跑固定数据并保存每次的 profile JSON：

```text
L = 1, 16, 32, 64, 128, 512
causal = true, false
partial Q tile = L % 32 != 0
q_pos_base/kv_pos_base = 0 和至少一个非零合法值
GQA group = 覆盖 group 0、group 7 和完整 8-group 事务
```

每个 case 至少保存 `.npz` 输入/期望、`.bit/.hwh/.xsa` SHA-256、板卡环境、
`pl_total_cycles`、`pl_mac_cycles`、`pl_stall_cycles`、K/V/Q/O DMA 时间、
request-service 时间和 host preprocessing 时间。任何 timeout、error、
`stream_error` 或 bit mismatch 都表示 P5 尚未通过。

## 13. 故障定位

| 现象 | 首先检查 |
|---|---|
| Overlay 找不到 IP | `.bit/.hwh` 是否同名同轮次，`sha256sum -c SHA256SUMS` 是否通过 |
| `start_ready=0` | 上一次事务是否完成，是否残留 DMA，读取 `CSR_STATUS` 和 `CSR_ERROR_CODE` |
| 长时间没有 request | AXI-Lite reset、PL clock、`s_axi` address map、`CSR_CTRL.start` 是否确实写入 |
| `stream_error` | `CSR_STREAM_DEST`、字节长度、AXIS `TLAST`、DMA buffer 是否 4B 对齐 |
| DMA 接收超时 | 是否在 start 前调用 `dma_recv.transfer()`，`result_len` 是否等于完整 O 长度 |
| 输出不是全零 | 先固定全零输入，再检查 bf16 endian、head-major layout 和 Q tile zero padding |
| 数值误差异常 | 检查 RoPE position base、causal mask、bf16 RNE 打包以及 Golden Model 版本 |

失败时保存：

```text
CSR_STATUS
CSR_ERROR_CODE
CSR_LOAD_REQ
CSR_PERF_CYCLES / CSR_PERF_MAC_CYCLES / CSR_PERF_STALLS
DMA send/recv 状态和 transfer byte count
```

## 14. 当前验证边界

`sw/attn_driver.py` 的 workstation mock 只验证 CSR/DMA 请求顺序和 shape/byte count，不等价于板上数值通过。真正的交付证据应至少包括：Verilator lint、VCS control-path test、Vivado post-route timing/DRC、零输入 smoke、预计算 Q/K/V 对比和一段板上运行视频。

当前设计是 prefill-first 的单序列路径，`MAX_SEQ_LEN=512`；decode、continuous batching、KV 压缩和长上下文分页不属于本轮板上签收范围。
