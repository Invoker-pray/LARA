#!/usr/bin/env bash

set -eo pipefail
cd /home/jiao/git/LARA

# sudo ip addr flush dev enp7s0
# sudo ip addr add 192.168.2.1/24 dev enp7s0
# sudo ip link set dev enp7s0 up

export BOARD_IP=192.168.2.100
# sudo ip addr flush dev eth0
# sudo ip addr add 192.168.2.100/24 dev eth0
# sudo ip link set dev eth0 up
# ping 192.168.2.1

# 2. 打包已签核的 v3.11 bit 和当前驱动；每次演示用一个新目录。

# 离线安装包的生成
#bash sw/prepare_kv260_pynq_offline.sh "$PWD/offline"

# bitstream的生成

#LARA_BUILD_TAG=v3_12_rebuild \
#LARA_ROUTE_DIRECTIVE=Explore \
#bash hw/scripts/vivado_build.sh

#需要上板的文件的打包
bash sw/package_kv260_board.sh \
	vivado_proj/build-v3_11_causal_collimit_20261010 \
	board_payload_v3_11_causal_collimit_20261010 \
	offline/sd-bundle

DEMO=lara-demo-$(date +%Y%m%d-%H%M%S)
mkdir -p temp
bash sw/package_kv260_board.sh \
	vivado_proj/build-v3_11_causal_collimit_20261010 \
	"temp/$DEMO" \
	board_payload_v3_11_causal_collimit_20261010/offline

# 3. 加入两组测试数据和板端命令，重新生成传输校验清单。
cp -r board_cases_rtl_contract_v2.6_q31_kv7 board_cases_rtl_contract_v2.6_q3_kv3 "temp/$DEMO/"
cp demo2.sh sw/demo_comparison.py "temp/$DEMO/"

cd "temp/$DEMO"
find . -type f ! -name LARA_SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum >LARA_SHA256SUMS
cd ..

# 4. 上传。下一步在板子终端进入刚传过去的目录。
scp -r "$DEMO" "ubuntu@$BOARD_IP:/home/ubuntu/demo"
echo "板上执行：cd /home/ubuntu/demo/$DEMO && sudo bash demo2.sh"
