#!/bin/bash
#
# 把外部内核树（kernel-3.0.8）的配置补全，并重建 include/config/auto.conf。
# 背景：target/linux/hi3520d/config-3.0.8 是不完整的 .config（约 1800 行），
# 只要 auto.conf 丢失，内核 make 就会跑 silentoldconfig，遇到 NEW 符号直接 abort。
set -e

K=/home/debian/hi3520d/kernel-3.0.8
OW=/home/debian/hi3520d/openwrt
R=/home/debian/hi3520d
X=/opt/hisi-linux-nptl/arm-hisiv100-linux/target/bin/arm-hisiv100nptl-linux-
HCF="-O2 -I$OW/staging_dir/host/include -Wno-error=implicit-int -Wno-error=implicit-function-declaration -Wno-error -Wall -Wmissing-prototypes -Wstrict-prototypes"

cd "$K"

echo "=== oldconfig（空白回答=取默认值）==="
for i in $(seq 1 4000); do echo; done | \
	make ARCH=arm CROSS_COMPILE="$X" CC="${X}gcc" \
	HOSTCFLAGS="$HCF" HOST_LOADLIBES="-L$OW/staging_dir/host/lib" \
	CONFIG_SHELL=bash oldconfig 2>&1 | tail -5

echo "=== silentoldconfig（重建 auto.conf）==="
make ARCH=arm CROSS_COMPILE="$X" CC="${X}gcc" \
	HOSTCFLAGS="$HCF" HOST_LOADLIBES="-L$OW/staging_dir/host/lib" \
	CONFIG_SHELL=bash silentoldconfig 2>&1 | tail -5

echo "=== 写回 target 配置 ==="
cp "$K/.config" "$OW/target/linux/hi3520d/config-3.0.8"
cp "$K/.config" "$R/owrt/target/linux/hi3520d/config-3.0.8"

echo "config lines: $(wc -l < "$K/.config")"
echo "auto.conf: $(ls -l "$K/include/config/auto.conf" 2>/dev/null | awk '{print $5}') bytes"
grep -c '=y' "$K/.config" | sed 's/^/CONFIG_...=y count: /'
