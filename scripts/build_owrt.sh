#!/bin/bash
#
# 一键构建 Hi3520D 的 OpenWRT（v19.07.10）
#   - 用户空间：OpenWRT 自建 musl 工具链（gcc 7.5.0）
#   - 内核：海思 SDK 的 linux-3.0.8（CONFIG_EXTERNAL_KERNEL_TREE），用 SDK 自带 gcc 4.4.1 编
#   - rootfs：jffs2-64k（1M boot + 4M kernel + 11M rootfs）
#
# 用法：bash scripts/build_owrt.sh [代理地址]
#   例：bash scripts/build_owrt.sh http://192.168.5.112:7890
#
set -u
R=/home/debian/hi3520d
OW=$R/openwrt
K=$R/kernel-3.0.8
OUT=$R/out
LOG=$OUT/owrt_build.log
PROXY=${1:-}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"

if [ -n "$PROXY" ]; then
	export http_proxy=$PROXY https_proxy=$PROXY ftp_proxy=$PROXY
	echo "使用代理：$PROXY"
else
	unset http_proxy https_proxy ftp_proxy 2>/dev/null || true
fi

echo "=== [1/7] 宿主工具层适配（gcc14 / 无 python2 / mkimage 桩）==="
bash "$HERE/patch_host_tools.sh" "$OW"

echo "=== [2/7] 安装 target/linux/hi3520d ==="
rm -rf "$OW/target/linux/hi3520d"
cp -a "$R/owrt/target/linux/hi3520d" "$OW/target/linux/" 2>/dev/null \
	|| cp -a "$HERE/../target/linux/hi3520d" "$OW/target/linux/"

echo "=== [3/7] 安装 netifd 的 3.0.8 兼容补丁 ==="
NP="$OW/package/network/config/netifd/patches"
SRC_NP="$R/owrt/overlay/openwrt/package/network/config/netifd/patches"
[ -d "$SRC_NP" ] || SRC_NP="$HERE/../overlay/openwrt/package/network/config/netifd/patches"
if [ -d "$SRC_NP" ]; then
	mkdir -p "$NP"
	cp -f "$SRC_NP"/*.patch "$NP"/ && echo "已安装: $(ls "$NP")"
	rm -rf "$OW"/build_dir/target-*/netifd-*
else
	echo "警告：没有找到 netifd 补丁目录 $SRC_NP（构建会在 netifd 处失败）"
fi

echo "=== [4/7] 修正 3.0.8 内核 uapi 头（un.h / if_ether.h）==="
bash "$HERE/patch_kernel_headers.sh" "$K" "$OW"

echo "=== [5/7] 种子 .config ==="
cd "$OW"
cat > .config <<EOF
CONFIG_TARGET_hi3520d=y
CONFIG_TARGET_hi3520d_DEVICE_hi3520d_dmeb=y
CONFIG_TARGET_BOARD="hi3520d"
CONFIG_TARGET_ARCH_PACKAGES="arm_cortex-a9"
CONFIG_TARGET_KERNEL_PARTSIZE=4
CONFIG_TARGET_ROOTFS_PARTSIZE=11
CONFIG_DEVEL=y
CONFIG_EXTERNAL_KERNEL_TREE="$K"
CONFIG_EXTERNAL_KERNEL_TREE_HEADERS=n
EOF
make defconfig V=s

echo "=== [6/7] 校正 config（DEVEL / 外部内核树 / 分区大小）==="
bash "$HERE/apply_config.sh"

echo "=== [7/7] 构建（工具链 + 内核 + rootfs + packages）==="
make -j"$(nproc)" V=s 2>&1 | tee -a "$LOG"

echo "=== 收集产物并打 16MB SPI 镜像 ==="
KDIR=$(ls -d "$OW"/build_dir/target-*/linux-hi3520d 2>/dev/null | head -1)
[ -n "$KDIR" ] || { echo "找不到 kernel build dir"; exit 1; }
ls -l "$KDIR"/uImage "$KDIR"/root.jffs2-64k 2>/dev/null || true

UBOOT=$R/sdk/Hi3520D_SDK_V1.0.2.2/osdrv/pub/image_uclibc/u-boot_hi3520d.bin
[ -f "$UBOOT" ] || echo "警告：没有找到 u-boot 二进制 $UBOOT（可手工传入）"

bash "$HERE/pack-images.sh" \
	"$KDIR/uImage" "$KDIR/root.jffs2-64k" "$UBOOT" "$OUT/images" || \
	echo "打包失败：先看上面的尺寸检查"

echo "=== 完成，产物在 $OUT/images ==="
ls -l "$OUT/images" 2>/dev/null
