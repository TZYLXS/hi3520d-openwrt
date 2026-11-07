#!/bin/bash
set -e
cd /home/debian/hi3520d/openwrt
rm -rf target/linux/hi3520d
cp -a /home/debian/hi3520d/owrt/target/linux/hi3520d target/linux/
cat > .config <<'EOF'
CONFIG_TARGET_hi3520d=y
CONFIG_TARGET_BOARD="hi3520d"
CONFIG_TARGET_ARCH_PACKAGES="arm_cortex-a9"
CONFIG_TARGET_ROOTFS_JFFS2=y
# CONFIG_TARGET_ROOTFS_SQUASHFS is not set
CONFIG_TARGET_KERNEL_PARTSIZE=4
CONFIG_TARGET_ROOTFS_PARTSIZE=11
CONFIG_EXTERNAL_KERNEL_TREE="/home/debian/hi3520d/kernel-3.0.8"
EOF
make defconfig > /tmp/defconfig.log 2>&1
echo "defconfig exit=$?"
grep -E "^CONFIG_TARGET_(BOARD|ARCH_PACKAGES|KERNEL_PARTSIZE|ROOTFS_PARTSIZE)|^CONFIG_EXTERNAL_KERNEL_TREE|^CONFIG_TARGET_ROOTFS_JFFS2|^CONFIG_TARGET_ROOTFS_SQUASHFS|^CONFIG_TARGET_hi3520d|^CONFIG_TARGET_PROFILE" .config || true
tail -5 /tmp/defconfig.log
