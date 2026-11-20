set -eo pipefail

# 1. 确认上传完整。首次使用的 SD 卡需要安装离线 PYNQ 环境。
sha256sum --quiet -c LARA_SHA256SUMS

# 首次使用SD卡　 bash offline/scripts/kv260_pynq_offline_install.sh "$PWD/offline"

source /etc/profile.d/pynq_venv.sh

# 2. 每次上电初始化板卡；poll 与 v3.12 板测使用相同的请求服务方式。
RESULT=results-$(date +%Y%m%d-%H%M%S)
mkdir "$RESULT"
export LARA_REQUEST_MODE=poll
python3 clear_pynq_cache.py --bitstream ./lara_attention.bit 2>&1 | tee "$RESULT/init.log"
cp board_environment.json LARA_SHA256SUMS "$RESULT/"

# 3. 两组位置 × 六档长度 × causal/noncausal。CPU 3 上运行单线程 NumPy 基线。

#python3 run_board_full_validation.py --bitstream ./lara_attention.bit \
#	--case-set q31kv7=./board_cases_rtl_contract_v2.6_q31_kv7 \
#	--case-set q3kv3=./board_cases_rtl_contract_v2.6_q3_kv3 \
#	--lengths 1 16 32 64 128 512 --cpu-core 3 --cpu-threads 1 \
#	--warmup 1 --repeats 5 --output-dir "$RESULT/validation" 2>&1 | tee "$RESULT/test.log"

python3 run_board_full_validation.py --bitstream ./lara_attention.bit \
	--case-set q31kv7=./board_cases_rtl_contract_v2.6_q31_kv7 \
	--case-set q3kv3=./board_cases_rtl_contract_v2.6_q3_kv3 \
	--lengths 512 --cpu-core 3 --cpu-threads 1 \
	--warmup 0 --repeats 1 --output-dir "$RESULT/validation" \
	2>&1 | tee "$RESULT/test.log" &&
	python3 demo_comparison.py "$RESULT/validation/performance/cpu1/performance.csv" |
	tee "$RESULT/comparison.csv"
# 4. 展示各用例实测延迟与同频估算，打包原始数据和日志。
python3 demo_comparison.py "$RESULT/validation/performance/cpu1/performance.csv" | tee "$RESULT/comparison.csv"
tar -czf "$RESULT.tar.gz" "$RESULT"
echo "结果归档：$PWD/$RESULT.tar.gz"
