# v3.12.2 — KV260 CPU BF16 与同频口径测试（2026-11-17）

## 结果与边界

- FPGA：使用 v3.12 driver 与其复用的 v3.11 bitstream，20/20 bit-exact PASS。
- CPU：在 KV260 Cortex-A53 CPU 3 实际运行 RTL BF16 合同软件计算，20/20 raw-BF16 bit-exact PASS。
- 每个 case 1 次 warmup、3 次正式测量，表中为中位数；L=1/16/32/64/128，两个 position-base 组，各含 causal/noncausal。
- CPU 实测频率 1333.333 MHz，PL 实测约 71.427857 MHz；CPUFreq 只公布 333.333/444.444/666.666/1333.333 MHz，目标频率不受支持，未强行写入非支持频点。
- CPU 同频结果为估算：实际 wall_ms × 实测 CPU MHz / 71.427857。每次计时前后读取 CPU 频率；20 个 case 的归一化均有效。
- 频率快照不是 PMU 连续测量；估算假设周期数不随降频变化。估算 CPU 时间不能冒充实际低频运行，也没有重新测量假想低频 CPU 服务下的 FPGA E2E。
- CPU BF16 模式复用 RTL golden：BF16 乘法、FP32 累加、LUT exp/reciprocal、既定顺序和舍入；它是 Python/NumPy 软件模拟，不是原生 BF16 指令或优化过的通用 CPU kernel。不能把模拟器开销计成 FPGA 对通用 CPU 的架构加速比。
- 该模式计时包括完整模型函数调用（含 LUT 文件读取、内部数组分配和软件位操作），是合同模拟器的运行耗时，不是独立抽出的 CPU 矩阵乘法内核耗时。
- 同时保留 NumPy FP32 标准 attention（BF16 输入）的实际/归一化数据，作为实用软件基线；该路径的数值算法不与 RTL 逐位等价。
- attention E2E 含输入准备、请求服务与 DMA，不含 Overlay 编程和 buffer 分配；不包含完整 Transformer。

## q31/kv7 causal 代表点

| L | CPU BF16 软件计算实测 ms | CPU BF16 等效 71.427857 MHz ms | NumPy FP32 实测 ms | NumPy FP32 等效 71.427857 MHz ms | FPGA E2E ms |
|---|---:|---:|---:|---:|---:|
| 1 | 217.127 | 4053.073 | 1.887 | 35.225 | 11.211 |
| 16 | 347.442 | 6485.642 | 4.819 | 89.950 | 13.747 |
| 32 | 1398.826 | 26111.666 | 9.880 | 184.426 | 18.851 |
| 64 | 5551.467 | 103628.392 | 27.076 | 505.426 | 41.879 |
| 128 | 19321.413 | 360669.891 | 91.267 | 1703.676 | 93.949 |

## 复现与证据

- 新增脚本：`sw/benchmark_cpu_bf16.py`。默认同时运行 RTL BF16 软件计算和 NumPy FP32；`--try-match-clock` 仅设置内核支持的目标频点，并在退出时恢复原 governor/频率设置。
- 本地软件单测 50/50 PASS，包含 EXP LUT 向量/标量 2051 点一致性、频率不支持时无写入、异常退出恢复及单位换算测试。
- NumPy 1.26 兼容修复：`np.uint64(1) << 23` 改为等值 `np.uint64(1 << 23)`；没有修改 RTL。首轮失败日志仍保留为 `run.log`，修复后日志为 `cpu_run.log`。
- bit SHA256：`c7e9e5d5a248ba4a0ca5d3e358b96fd9581a5bbbb70dd3e5030d037b418c60b1`。
- 原始数据：`temp/cpu_bf16_study_20261117/lara_cpu_bf16_20261117/`，含 CPU JSON、FPGA JSON/CSV、输入 NPZ、bit/hwh/xsa、运行脚本及源码。
- 全部对照表：`temp/cpu_bf16_study_20261117/comparison.csv`；归档校验和见同目录 `board_archive.sha256`。
- 板上工作目录：`/home/ubuntu/lara_cpu_bf16_20261117`。板上 RTC 日期与宿主机不同，报告日期取宿主机；耗时使用单调时钟。

在板上解包测试目录后执行（选择新的输出路径）：

```bash
cd /home/ubuntu/lara_cpu_bf16_20261117
sudo env XILINX_XRT=/usr BOARD=KV260 LARA_CPU_THREADS=1 \
  /usr/local/share/pynq-venv/bin/python3 sw/benchmark_cpu_bf16.py \
  --case-set q31=./board_cases_rtl_contract_v2.6_q31_kv7 \
  --case-set q3=./board_cases_rtl_contract_v2.6_q3_kv3 \
  --lengths 1 16 32 64 128 --cpu-core 3 --warmup 1 --repeats 3 \
  --target-mhz 71.427857 --try-match-clock \
  --fpga-performance ./fpga_performance/performance.json \
  --output ./cpu_bf16_repeat.json
```
