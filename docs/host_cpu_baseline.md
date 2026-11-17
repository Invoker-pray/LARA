# v3.12.3 — 宿主机 CPU 基线：实现差异、结果解释与使用方法

## 如何描述结果

主性能基线使用普通 NumPy attention：BF16 输入、FP32 矩阵乘法与标准 exp/softmax。先报告 CPU 与 FPGA 的实际 attention E2E，再单列同频归一化估算。CPU/FPGA 数值实现不同，需同时交代输出精度和误差；不能称为同一逐位算法的性能比较。

RTL-contract BF16 路径是正确性参考：同样使用 NumPy，但通过软件位操作、LUT 与固定累加/舍入顺序模拟 RTL，包含模型读取 LUT 和分配数组的开销。逐位复现硬件顺序对验证正确性合理；将 Python 合同模拟器当作通用 CPU 的性能基线不合理。它的时间单独标记为“合同模拟器耗时”。

以板上 q31/kv7 L128 causal 为例：CPU NumPy 实测 91.267 ms（1333.333 MHz），FPGA E2E 实测 93.949 ms（PL 71.427857 MHz），即实际延迟下 FPGA 仍慢约 2.94%。CPU NumPy 同频估算 1703.676 ms 对比 FPGA E2E 93.949 ms，估算比值约18.13。CPU BF16 合同模拟器的同频估算360669.891 ms只用于说明模拟器运行成本，不作为通用CPU加速比的分母。

同频换算假设周期数不变，不能消除缓存/内存、IPC、SIMD、Python/NumPy版本和算法精度差异；FPGA E2E的PS服务没有按假想低频重新运行。因此同频值应叫“归一化估算时间/估算比值”，不叫“物理同频实测加速比”。若需要数值合同接近且性能有代表性的CPU BF16基线，后续应使用优化的C/C++/SIMD实现，性能优化与数值误差约束分别验收。

## 本次宿主机实测（2026-11-17）

- CPU：12th Gen Intel(R) Core(TM) i7-12700H，固定逻辑 CPU 3；BLAS 单线程，1 warmup + 3 repeats。
- 环境：Python 3.12.13，NumPy 2.5.0。板上 Python 3.10/NumPy 1.26.4，版本差异会影响耗时。
- 两组 position base × L1/16/32/64/128 × causal/noncausal，共20个 case；BF16合同模型20/20 bit-exact PASS，输入按SHA256与板上结果配对。
- 计时期间采样sysfs频率并做梯形积分，估算至71.427857 MHz；不是PMU周期测量。BF16各样本加权均值约4.09–4.38 GHz。短时NumPy调用的采样点很少，归一化估算尤其粗略。采样线程本身也有计时扰动。
- i7相对板上A53的同频耗时改善（20-case几何平均）：BF16合同模拟器约6.91倍，普通NumPy约5.87倍。这些是具体软件栈的归一化估算，不能归结为纯CPU微架构性能差异。

以下为q31/kv7 causal中位数，单位ms：

| L | i7普通NumPy实测 | i7普通NumPy同频估算 | 板上NumPy同频估算 | FPGA E2E实测 | i7合同模拟器实测 |
|---|---:|---:|---:|---:|---:|
| 1 | 0.117 | 7.046 | 35.225 | 11.211 | 9.666 |
| 16 | 0.262 | 15.750 | 89.950 | 13.747 | 15.451 |
| 32 | 0.568 | 33.993 | 184.426 | 18.851 | 64.904 |
| 64 | 1.415 | 88.280 | 505.426 | 41.879 | 259.701 |
| 128 | 4.673 | 280.352 | 1703.676 | 93.949 | 895.859 |

## 一条命令运行

在仓库根目录，使用已经安装NumPy的Python环境：

```bash
.venv/bin/python3 sw/benchmark_host_cpu.py
```

默认自动选择仓库内的 `board_cases_rtl_contract_v2.6_q31_kv7` 和 `board_cases_rtl_contract_v2.6_q3_kv3`，无需手动填写路径。默认遍历L1/16/32/64/128双模式；自动在允许CPU集合中选择最高标称频率的逻辑核，并设置单核affinity。可用 `--cpu-core 3` 指定。本脚本不修改系统调频配置。

```bash
# 快速检查
.venv/bin/python3 sw/benchmark_host_cpu.py --lengths 1 16 --repeats 1 --warmup 0

# 自定义用例目录与板上报告
.venv/bin/python3 sw/benchmark_host_cpu.py \
  --case-set custom=/path/to/cases \
  --board-report /path/to/cpu_bf16.json \
  --cpu-core 3 --target-mhz 71.427857
```

默认输出到新的 `temp/host_cpu_bf16_<UTC时间>/`，已有目录不会覆盖。用例NPZ不在Git中，新克隆仓库须先生成/复制用例或用 `--case-set` 指定。默认板上参考为 `temp/cpu_bf16_study_20261117/lara_cpu_bf16_20261117/cpu_bf16.json`；该文件不存在时可仅跑宿主机，CSV的板上/FPGA列为空。

输出包括：`performance.json`（时延、每次频率采样、同频估算、逐位校验和源码哈希）、`comparison.csv`（宿主机/板上/FPGA对照）、`cpuinfo.txt`。所有估算都保留原始wall time。

## 本轮代码和验证

- 新增 `sw/benchmark_host_cpu.py`；复用现有BF16模型和普通NumPy函数，不修改板上已签核数据。
- 新增 `sw/tests/test_benchmark_host_cpu.py`：固定/动态频率积分、缺失频率、自动发现用例和核心选择测试。
- 本轮软件单测55/55 PASS。宿主机20/20 BF16 bit-exact PASS。
- 实际结果：`temp/host_cpu_bf16_20261117/`；本轮软件与文档增量记录为v3.12.3。
