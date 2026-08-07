# LARA 下一阶段优化路线

更新日期：2026-08-02

## 当前已完成状态

v2.5 P0-P4 已完成。P4 candidate 1 streaming/fused PV 已设为源码默认：

- 32x32 主循环：`4345 -> 3209` cycles；
- 32x64 主循环：`8429 -> 5809` cycles；
- matching Explore route：WNS `+0.021 ns`、WHS `+0.010 ns`、TNS/THS `0`；
- 144158/144158 routable nets fully routed，DRC Error severity `0`；
- Explore post-route：95479 LUT、56940 FF、50 BRAM、48 URAM、165 DSP；
- 回退：`LARA_STREAMING_PV_ROLLBACK`。

当前 accepted 证据是 routed DCP，不是部署文件。板测前必须用
`hw/scripts/export_p4_explore_deploy.sh` 从该 DCP 生成同一轮 `.bit/.hwh/.xsa`。

## 从 `xx` 项目迁移的有效方法

`~/git/xx` 中最值得保留的不是 INT8/CNN 数据路径，而是工程方法：

1. 使用 AXI4-Stream/AXI DMA 代替大块 AXI-Lite 逐字搬运；
2. legacy 路径和 DMA 路径并存，直到板上 bit-exact 与性能证据完成；
3. 每个阶段有独立 profiler、端到端 benchmark、明确回退；
4. 先做单张 smoke，再做固定数据集，再做 200 样本统计；
5. 记录每层/每阶段 latency，而不是只报告总时间。

这些方法与 LARA 当前的 GQA、bf16、head-major DMA 和 online softmax 相容，
但不能直接复制 `xx` 的 INT8、MNIST 或 MVM RTL。

## P5：KV260 实板基线与部署闭环

P5 不改 RTL，先关闭“仿真快但板上未知”的风险。当前 v2.6 已补齐
`sw/generate_board_cases.py` 和 `sw/board_matrix.py`：前者生成带 metadata 的
raw-bf16 输入/期望 NPZ，后者在板上逐 case 运行、逐元素比较并归档实际输出和
profile。`sw/board_test.py` 现在支持 `--causal/--non-causal` 以及
`--q-pos-base/--kv-pos-base`。

1. 导出 P4 Explore deployment bundle，并记录 `.bit/.hwh/.xsa` 的 SHA-256。
2. 按 `docs/kv260_board_validation.md` 完成启动、网络、PYNQ/overlay 和零输入 smoke。
3. 用固定 NPZ 做 `L=1,16,32,64,128,512`，分别覆盖 causal/non-causal、
   partial Q tile、non-zero position base 和 GQA group 切换。
4. 记录 `pl_total_cycles`、`pl_mac_cycles`、`pl_stall_cycles`、Q/K/V DMA、
   output DMA、request-service 和 host preprocessing 时间。
5. 以 Python golden 的 raw bf16 bits 做逐元素比较；任何 mismatch 都先停止优化。

P5 通过条件：所有定向 case bit-exact、无 timeout/error/stream_error，且保存
板卡型号、镜像、Vivado/PYNQ 版本、温度/频率、SHA-256 和完整 profile JSON。

生成固定 case：

```bash
python3 sw/generate_board_cases.py \
  --output-dir board_cases_v2.6 \
  --include-noncausal \
  --q-pos-base 3 \
  --kv-pos-base 3
```

For `L=512`, absolute position base `3` cannot fit in the deployed
`MAX_SEQ_LEN=512` address space. The generator emits an explicit message and
uses base `0` for that full-length case; shorter cases retain base `3`.

板卡导出 P4 `.bit` 后运行完整矩阵：

```bash
python3 sw/board_matrix.py \
  --bitstream vivado_proj/p4-explore-deploy/lara_attention.bit \
  --cases board_cases_v2.6 \
  --output-dir board_results_v2.6 \
  --environment-json kv260_environment.json
```

`summary.json` 中所有 case 必须为 `PASS`；profile、实际 raw-bf16 输出和
bitstream SHA-256 必须一起归档；`manifest.json` 保存环境 metadata 和 case 汇总。
没有板卡时可以运行生成器和 mock 单元测试，但不能把 mock 结果写成 P5 板上通过。

## P6：PS request-service 与 DMA 搬运优化

只有 P5 profile 证明 request-service 或 DMA 占比是主要瓶颈时才实施。先做
software-only 变体：

- 保持连续 CMA buffer，避免每个 tile 重复分配和重复 dtype/reshape；
- 对 K/V group 传输使用预打包、对齐、固定 buffer，减少 Python 临时对象；
- 统计 DMA setup、DMA transfer、cache flush/invalidate 和 polling 分项；
- 评估 DMA completion interrupt 与当前 polling 的差异；
- 保持现有 `CSR_LOAD_REQ` 协议和同步回退路径。

若软件优化仍不足，再评估 `Q prefetch depth=1` 或 request coalescing。任何
prefetch 都必须保持 Q tile tag、active rows、position base 和 backpressure
稳定，并提供 `Q_PREFETCH_ENABLE=0` 回退。禁止先改公开 CSR 再测量。

## P7：物理时序余量优化

P4 Explore 只有约 21 ps setup 余量，P7 的目标是提高鲁棒性，不降低时钟约束。

顺序固定为：

1. 用 matching route 的 timing、fanout、congestion 和 bounding-box 报告定位；
2. 优先对最差 MAC->output-buffer 或 score/context mux 做局部寄存器；
3. 再评估 DSP48E2 A/B/M/P 内部寄存器；
4. 使用同轮 phys_opt/Explore；
5. 只有多轮证明同一物理跨区问题后才使用最小 Pblock。

不得使用 false path、multicycle path、降低 83.333 MHz 或全局
`MAX_FANOUT` 掩盖真实路径。每个 RTL 变体必须从 clean synthesis 开始。

### 2026-08-05 综合检查点

本轮 `board_cases_rtl_contract_v2.6_q31_kv7` 的 VCS 回归为 `10/10 PASS`。
对应综合目录为 `vivado_proj/build-20260805T162458Z/`。

综合结果仍不满足上板条件：

- WNS `-2.162 ns`，TNS `-2861.068 ns`；
- WHS `-0.090 ns`，THS `-1456.603 ns`；
- setup failing endpoints `6951`，hold failing endpoints `59194`；
- CLB LUT `254476/117120`，利用率 `217.28%`；
- `u_mac` LUT `190790`。

当前最差 setup 路径为
`u_mac/split_phase_row_r_reg[12][0] -> u_mac/block_acc_bits_reg[12][11][30]`，
数据延迟 `13.890 ns`，其中 routing delay `9.608 ns`。这说明上一轮默认
两相索引展开没有达到预期，且引入了较大的控制选择/扇出网络；下一轮应优先
回退或重构该局部优化，再重新执行完整 VCS 回归和 synthesis-only。

### 2026-08-06 split-8 / split-16 候选

本轮先将默认 `TILE_SPLIT_FACTOR` 调整为 `8`，并增加
`LARA_TILE_SPLIT_FACTOR_2` 作为兼容回退。物理 MAC 从每周期 16x8 个
active PE 降为 16x2 个 active PE，预计显著降低 `u_mac` 的 LUT、FP32
加法器数量和控制布线压力；代价是 MAC 阶段周期数约增加 4 倍。

在 `split-8` 综合后，资源已从严重超限降到接近器件上限，但仍有
`127202 LUT`、`108.61%` 利用率，且 WNS 仍约 `-2.2 ns`。因此下一轮继续
尝试 `split-16`，将物理 MAC 收缩到每周期 16x1 个 active PE，优先目标是先
把 LUT 压回器件容量内，再观察布线拥塞是否顺带改善 setup slack。

该候选尚未经过完整 VCS 和 Vivado 证据验证，只有在 L1-L128 全部 bit-exact
通过后才能继续综合。

## P8：可选的架构扩展

P5-P7 完成后才考虑：

- 长上下文分页/KV cache streaming；
- decode/continuous batching；
- Q/K/V DMA 与 PL compute 的双缓冲；
- 更宽 AXI data path 或更大 Q tile。

这些方向会改变内存容量、CSR 语义或事务调度，不能与 P6/P7 混做。优先级由
板上 profile 决定，而不是由理论带宽或论文峰值决定。

## 每阶段固定门禁

RTL 变更：Python golden/driver -> Verilator behavioral+synthesis -> VCS
behavioral/synthesis/XPM -> clean Vivado synth/place/phys_opt/route/DRC。

板测变更：host unit tests -> mock request-service -> zero smoke -> precomputed
NPZ bit-exact -> length/causal matrix -> profile archive。

接受条件：功能无回退、主目标至少 10% 收益或明显提高时序余量、资源和 DRC
可接受、证据可复现。失败方案必须保留报告和一键回退，不能为了保留候选而
牺牲默认配置。

## 参考资料

- AMD `UG1089` KV260 Starter Kit User Guide；
- AMD `DS986` KV260 Starter Kit Datasheet、`DS987` K26 SOM Datasheet；
- AMD `PG021` AXI DMA Product Guide；
- AMD `UG949` UltraFast Design Methodology；
- PYNQ DMA/allocate 文档；
- FlashAttention/FlashAttention-2 的 IO-aware tiling 与 online attention 论文。

上述资料只提供平台、DMA、时序和 IO-aware dataflow 方法；算法和 RTL 仍以
LARA 的 exact bf16、GQA、causal 和当前 CSR/AXIS 合同为准。
