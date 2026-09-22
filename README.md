# LARA — KV260 Streaming Attention Accelerator

LARA 是部署在 AMD KV260（PYNQ）上的 GQA attention 加速器（PL 端 BF16
QK/PV + online softmax，PS 端 host projection/协议），当前签核基线 v2.6
（71.429 MHz，L512 bit-exact 板上 20/20）。v3.x 在保持 legacy 协议与
bit-exact 前提下推进 transport/overlap 优化。

## 分支与目录

- `master`：上板部署源（hw/sw、打包与上板测试脚本）。
- `develop`：在 master 之上额外包含 VV/ 仿真环境、python_godel/ golden
  model 与回归脚本。
- `hw/rtl` RTL，`sw/` PYNQ driver 与上板脚本，`VV/tb`+`VV/scripts` VCS
  testbench 与回归，`python_godel/` Python golden model。
- 详细提交记录见 [`docs/commitlog.md`](docs/commitlog.md)。

## 验证门禁（develop）

```bash
python3 python_godel/attention_golden.py --test-all   # golden model
python3 -m unittest discover -s sw/tests              # driver/board 脚本单测
verilator --lint-only ...                             # RTL lint
RUN_SYNTH_PATHS=1 RUN_XPM_PATHS=1 bash VV/scripts/run_regression.sh   # VCS 28 项
bash VV/scripts/run_tb_attn_top_board_matrix.sh <case-root> "<lengths>"  # 板级 case 仿真
```

RTL 修改必须依次通过 Python golden、Verilator、VCS 全部仿真后才可进入
Vivado 构建与上板；上板发现的问题须先在仿真中稳定复现，再做精准修复。
