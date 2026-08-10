# Test Data Generation

本文档区分两类“测试数据”：

1. 工作站生成的 NPZ 输入和 RTL bit-exact 期望输出；
2. KV260 实板运行后生成的功能、性能、周期数和每周期效率结果。

所有工作站命令均从 LARA 仓库根目录执行。正式用例只使用
`board_cases_rtl_contract_v2.6_fixed` 和
`board_cases_rtl_contract_v2.6_q31_kv7`，不要使用历史
`board_cases_v2.6` 作为当前 RTL 的 expected output。

## 1. 生成正式 NPZ 测试用例

生成 q3/kv3 的 L1、L16、L32、L64、L128、L512 causal/noncausal 用例：

```bash
cd /home/jiao/git/LARA

python3 sw/generate_board_cases.py \
  --output-dir board_cases_rtl_contract_v2.6_fixed \
  --lengths 1 16 32 64 128 512 \
  --include-noncausal \
  --model rtl \
  --backend vectorized \
  --q-pos-base 3 \
  --kv-pos-base 3 \
  --seed 2602 \
  --resume
```

生成 q31/kv7 的同一长度矩阵：

```bash
python3 sw/generate_board_cases.py \
  --output-dir board_cases_rtl_contract_v2.6_q31_kv7 \
  --lengths 1 16 32 64 128 512 \
  --include-noncausal \
  --model rtl \
  --backend vectorized \
  --q-pos-base 31 \
  --kv-pos-base 7 \
  --seed 2602 \
  --resume
```

`--model rtl --backend vectorized` 生成与当前 RTL 运算顺序一致的 raw BF16
`uint16` 输入和 `expected_o`，不是普通 FP32 Python attention 输出。固定 seed
使两次生成可复现。`--resume` 会校验 metadata、shape 和 seed，只跳过完整且匹配的
NPZ；生成 L512 时被中断，可以直接重新执行同一命令。

### 1.1 手动加入已经生成的 payload

`sw/package_kv260_board.sh` 不自动包含测试用例。先运行打包脚本生成 payload，
再从仓库根目录手动复制两套用例，并重新生成总 SHA-256 清单：

```bash
PAYLOAD_DIR=/home/jiao/git/LARA/board_payload_submission

cp -a board_cases_rtl_contract_v2.6_fixed "$PAYLOAD_DIR/"
cp -a board_cases_rtl_contract_v2.6_q31_kv7 "$PAYLOAD_DIR/"

(
  cd "$PAYLOAD_DIR"
  find . -type f ! -name LARA_SHA256SUMS -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 sha256sum > LARA_SHA256SUMS
)

(cd "$PAYLOAD_DIR" && sha256sum -c LARA_SHA256SUMS)
```

必须在复制测试用例后刷新 `LARA_SHA256SUMS`。否则旧清单虽然可能校验成功，
但不会覆盖后来加入的 NPZ 文件。

如果只想先验证生成器，使用单独的临时目录生成一个 L1 case：

```bash
python3 sw/generate_board_cases.py \
  --output-dir /tmp/lara_case_smoke \
  --lengths 1 \
  --model rtl \
  --backend vectorized \
  --q-pos-base 31 \
  --kv-pos-base 7 \
  --seed 2602
```

## 2. 检查生成结果

运行生成器单元测试：

```bash
python3 -m unittest sw.tests.test_board_case_generation
```

检查两套正式性能矩阵的 L1-L128 causal/noncausal 文件是否齐全，不加载 FPGA：

```bash
python3 sw/board_performance.py \
  --case-set q3kv3=./board_cases_rtl_contract_v2.6_fixed \
  --case-set q31kv7=./board_cases_rtl_contract_v2.6_q31_kv7 \
  --lengths 1 16 32 64 128 \
  --list-only
```

正确输出最后应包含：

```text
selected performance matrix complete: 20 cases
```

为提交归档生成测试用例 SHA-256 清单：

```bash
find \
  board_cases_rtl_contract_v2.6_fixed \
  board_cases_rtl_contract_v2.6_q31_kv7 \
  -maxdepth 1 -type f -name 'case_*.npz' -print0 \
  | sort -z \
  | xargs -0 sha256sum \
  > board_cases_rtl_contract_v2.6_SHA256SUMS

sha256sum -c board_cases_rtl_contract_v2.6_SHA256SUMS
```

## 3. 用 VCS 验证生成数据

分别运行两套 board-case 回归：

```bash
SNPSLMD_LICENSE_FILE=27000@127.0.0.1 \
LM_LICENSE_FILE=27000@127.0.0.1 \
bash VV/scripts/run_tb_attn_top_board_matrix.sh \
  board_cases_rtl_contract_v2.6_fixed \
  "1 16 32 64 128 512"

SNPSLMD_LICENSE_FILE=27000@127.0.0.1 \
LM_LICENSE_FILE=27000@127.0.0.1 \
bash VV/scripts/run_tb_attn_top_board_matrix.sh \
  board_cases_rtl_contract_v2.6_q31_kv7 \
  "1 16 32 64 128 512"
```

这一步可能耗时较长。正式使用某个 NPZ 前，至少应看到对应 case 的
`BOARD CASE PASS`；完整回归应以矩阵全部通过结束。

## 4. 在 KV260 上生成最终结果数据

下面的命令在已经复制好 payload 的 KV260 上执行。结果目录必须使用新名称，
`run_board_full_validation.py` 不会覆盖非空目录。

```bash
sudo -i
source /etc/profile.d/pynq_venv.sh
cd /home/ubuntu/board_payload

sha256sum -c LARA_SHA256SUMS

python3 clear_pynq_cache.py \
  --bitstream ./lara_attention.bit \
  --force
```

初始化必须显示 `overall_status: PASS`。随后生成两套用例 L1-L128 的完整功能和
性能数据：

```bash
LARA_REQUEST_POLL_SLEEP_US=20 \
python3 -u run_board_full_validation.py \
  --bitstream ./lara_attention.bit \
  --case-set q3kv3=./board_cases_rtl_contract_v2.6_fixed \
  --case-set q31kv7=./board_cases_rtl_contract_v2.6_q31_kv7 \
  --lengths 1 16 32 64 128 \
  --output-dir ./board_full_submission_cpu1 \
  --cpu-threads 1 \
  --cpu-core 3 \
  --cpu-clock-mhz 1333.333 \
  --warmup 1 \
  --repeats 5 \
  2>&1 | tee ./board_full_submission_cpu1.log
```

`--case-set` 可以指向 payload 外的任意绝对或相对目录，例如
`q3kv3=/home/ubuntu/testcases/q3kv3`。参数可以重复传入；标签必须唯一。测试脚本不再
隐式查找固定目录。`--lengths` 只选择目录中对应长度，缺少任一所选长度或模式时会
直接报错，不会静默跳过。

不要为正式长测试添加 `--timeout-ms`。`--cpu-clock-mhz` 只应用于 CPU 周期数和
每周期效率计算；端到端时间仍使用实测 wall time，不进行伪同频换算。只有确认板上
CPU 3 在整轮测试期间保持 1333.333 MHz 时才能使用上述值，否则删除该参数，让脚本
读取 cpufreq，或传入实测稳定频率。

主要结果文件为：

```text
board_full_submission_cpu1/
├── consolidated_results.json
├── run_manifest.json
├── functional/
│   ├── q3kv3/summary.json
│   └── q31kv7/summary.json
├── performance/cpu1/
│   ├── performance.json
│   └── performance.csv
├── logs/
└── provenance/
```

`performance.json` 和 `performance.csv` 同时记录：

- FPGA bit-exact 状态和 mismatch 数量；
- PL transaction、MAC、stall、core-active 周期和换算时间；
- FPGA host-to-host E2E 和同板 CPU baseline wall time；
- effective GOPS；
- `cpu_ops_per_cycle`、`pl_transaction_ops_per_cycle`、
  `pl_active_ops_per_cycle`；
- PL 相对 CPU 的 transaction/active 每周期架构效率。

运行结束后检查：

```bash
cat board_full_submission_cpu1/consolidated_results.json
head -n 2 board_full_submission_cpu1/performance/cpu1/performance.csv
```

只有 `FULL VALIDATION STATUS: PASS`、两套功能矩阵均通过、性能矩阵 bit-exact
全部通过时，才应将该目录中的数据用于论文、演示视频和最终提交。
