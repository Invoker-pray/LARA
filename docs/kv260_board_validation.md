# KV260 上板与板上验证指南

本指南对应当前 `develop` 的 v2.4 控制链：宿主机负责 RMSNorm、QKV projection 和可选 RoPE，KV260 PL 负责 bf16 FlashAttention。当前硬件使用 16×16 MAC、8 个 KV cache bank、32 行 Q tile 双缓冲，单次事务的最大序列长度为 512。

## 1. 交付物

Vivado 成功后，部署目录包含：

```text
vivado_proj/deploy/lara_attention.bit
vivado_proj/deploy/lara_attention.hwh
vivado_proj/deploy/lara_attention.xsa
vivado_proj/reports/post_route_timing_summary.rpt
vivado_proj/reports/post_route_status.rpt
vivado_proj/reports/post_route_utilization.rpt
vivado_proj/reports/post_route_drc.rpt
```

运行 `hw/scripts/package_kv260.sh` 后，还会生成 `vivado_proj/board_bundle/`，其中包含三个硬件文件、四份 post-route 签核报告、`sw/` 下的 driver/host helper、本文档和 `SHA256SUMS`。`.bit` 与 `.hwh` 必须来自同一轮构建并保持同名，否则 PYNQ Overlay 可能加载错误的硬件元数据。

## 2. 构建与打包

在项目根目录执行：

```bash
bash hw/scripts/vivado_build.sh
```

构建脚本使用 Vivado 2025.2、KV260 `xck26-sfvc784-2LV-c` 和 83.333 MHz PL 时钟。只有 setup/hold 通过时才会生成 bitstream；脚本随后自动生成 board bundle。

如果已有 routed implementation，只需重新生成签核报告，可执行：

```bash
vivado -mode batch -source hw/scripts/vivado_report_signoff.tcl
```

单独重新打包已有部署文件：

```bash
bash hw/scripts/package_kv260.sh
sha256sum vivado_proj/board_bundle/lara_attention.{bit,hwh,xsa}
```

当前 v2.4 签核结果为 post-route WNS `+0.049 ns`、WHS `+0.011 ns`、TNS/THS `0`、DRC errors `0`；对应报告和哈希已放入 `vivado_proj/board_bundle/`。本轮默认 route 的 WNS 为 `-0.671 ns`，由 `vivado_resume_route.tcl` 从同一轮 physopt checkpoint 以 `route_design -directive Explore` 重布线后通过门禁。后续重构建仍应以新一轮报告为准，不要把旧 checkpoint 的 slack 当成新 bitstream 的签核证据。

## 3. 拷贝到板卡

将 `board_bundle/` 拷贝到 KV260，例如：

```bash
scp -r vivado_proj/board_bundle root@<kv260-ip>:/home/root/lara_attention/
ssh root@<kv260-ip>
cd /home/root/lara_attention/board_bundle
sha256sum -c SHA256SUMS
```

加载 overlay 的方式取决于镜像。常见的 Kria/KV260 流程是：

```bash
xmutil unloadapp 2>/dev/null || true
xmutil loadapp lara_attention
```

若使用 PYNQ Python 环境，可直接从 `.bit` 路径创建 `Overlay`；对应 `.hwh` 放在同一目录即可。不要在 DMA 尚未停止时覆盖当前 overlay，也不要在 PL reset 期间启动 DMA。

## 4. 数据格式与控制顺序

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

## 5. 零输入 Smoke Test

board bundle 内的 `sw/board_test.py` 提供不依赖模型权重的控制链验证。全零 Q/K/V 的正确 attention 输出应为全零：

```bash
cd /home/root/lara_attention/board_bundle/sw
python3 board_test.py --bitstream ../lara_attention.bit --seq-len 16
```

通过标准：

- Overlay 加载成功；
- AXI-Lite 可写配置、接受一次 start；
- driver 能看到并服务 KV/Q load request；
- DMA 接收完成且 output `TLAST` 到达；
- 输出全为零；
- 无 timeout、`error` 或 `stream_error`。

## 6. 使用预计算 Q/K/V 验证数值

准备一个 NPZ 文件，键名和 shape 必须为：

```text
q_heads: uint16 [32, L, 128]
k_heads: uint16 [ 8, L, 128]
v_heads: uint16 [ 8, L, 128]
```

然后执行：

```bash
python3 board_test.py \
  --bitstream ../lara_attention.bit \
  --seq-len 64 \
  --npz attention_inputs_L64.npz
```

建议同时用 `python_godel/attention_golden.py` 计算参考结果，在相同 bf16 输入、causal 配置和位置 base 下比较每个 head/token/dim。板上测试不应只比较均值；应记录最大绝对误差、最大相对误差、首个不一致坐标和原始 bf16 bits。

## 7. 宿主机 QKV Projection 一体化入口

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

## 8. 故障定位

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

## 9. 当前验证边界

`sw/attn_driver.py` 的 workstation mock 只验证 CSR/DMA 请求顺序和 shape/byte count，不等价于板上数值通过。真正的交付证据应至少包括：Verilator lint、VCS control-path test、Vivado post-route timing/DRC、零输入 smoke、预计算 Q/K/V 对比和一段板上运行视频。

当前设计是 prefill-first 的单序列路径，`MAX_SEQ_LEN=512`；decode、continuous batching、KV 压缩和长上下文分页不属于本轮板上签收范围。
