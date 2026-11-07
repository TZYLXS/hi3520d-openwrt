#!/bin/bash
# 用 OpenWRT 的 target 内核配置独立验证 linux-3.0.8 能否编译（不改动 SDK 原始树）
set -e
R=/home/debian/hi3520d
K=$R/kernel-3.0.8
LOG=$R/out/k_test.log
exec > >(tee -a "$LOG") 2>&1
echo "=== [1/5] 解出干净内核树 ==="
rm -rf "$K"; mkdir -p "$K"
tar -xzf "$R/sdk/Hi3520D_SDK_V1.0.2.2/osdrv/kernel/linux-3.0.y.tgz" -C "$K" --strip-components=1
echo "=== [2/5] 主机工具兼容补丁 ==="
python3 - "$K/kernel/timeconst.pl" <<'EOF'
import sys, io
p = sys.argv[1]
s = io.open(p, encoding='utf-8', errors='replace').read()
s = s.replace('if (!defined(@val)) {', 'if (!@val) {')
io.open(p, 'w', encoding='utf-8').write(s)
EOF
echo "=== [3/5] 使用 OpenWRT target 配置 ==="
cp "$R/owrt/target/linux/hi3520d/config-3.0.8" "$K/.config"
cd "$K"
export PATH=/opt/hisi-linux-nptl/arm-hisiv100-linux/target/bin:$PATH
make ARCH=arm oldconfig </dev/null
echo "=== [4/5] 编译 uImage ==="
make ARCH=arm CROSS_COMPILE=arm-hisiv100nptl-linux- HOSTCFLAGS="-Wno-error=implicit-function-declaration -Wno-implicit-function-declaration" -j6 uImage
echo "=== [5/5] 结果 ==="
ls -l arch/arm/boot/uImage
