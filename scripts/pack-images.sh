#!/bin/bash
#
# Hi3520D OpenWRT 镜像打包脚本
#
# 输入：
#   $1  uImage            OpenWRT 内核（由 SDK gcc 4.4.1 编译，通常 3.0~3.4MB）
#   $2  root.jffs2-64k    rootfs（OpenWRT 生成，64K 擦除块）
#   $3  u-boot_hi3520d.bin 海思 SDK 编译出的 u-boot
#
# 输出（$OUT，默认 ~/hi3520d/out/images）：
#   boot.bin        1MB 分区内容（u-boot，未填充）
#   kernel.bin      4MB 分区内容（uImage）
#   rootfs.jffs2    11MB 分区内容（jffs2）
#   hi3520d_16m.bin 16MB 整片 SPI Flash 镜像（1M boot + 4M kernel + 11M rootfs）
#   uboot-env.txt   u-boot 环境变量（bootargs / bootcmd / 烧写命令）
#   md5sum.txt
#
set -e

UIMAGE=${1:?用法: $0 <uImage> <root.jffs2-64k> <u-boot.bin> [输出目录]}
ROOTFS=${2:?缺少 rootfs}
UBOOT=${3:?缺少 u-boot}
OUT=${4:-$HOME/hi3520d/out/images}

BOOT_SIZE=$((1 * 1024 * 1024))
KERNEL_SIZE=$((4 * 1024 * 1024))
ROOTFS_SIZE=$((11 * 1024 * 1024))
FLASH_SIZE=$((16 * 1024 * 1024))

die() { echo "错误: $*" >&2; exit 1; }
size_of() { stat -c %s "$1"; }

[ -f "$UIMAGE" ] || die "找不到内核 $UIMAGE"
[ -f "$ROOTFS" ] || die "找不到 rootfs $ROOTFS"
[ -f "$UBOOT" ]  || die "找不到 u-boot $UBOOT"

mkdir -p "$OUT"
rm -f "$OUT"/boot.bin "$OUT"/kernel.bin "$OUT"/rootfs.jffs2 "$OUT"/hi3520d_16m.bin "$OUT"/md5sum.txt

us=$(size_of "$UIMAGE"); rs=$(size_of "$ROOTFS"); bs=$(size_of "$UBOOT")
echo "u-boot : $bs 字节 (分区 $BOOT_SIZE)"
echo "kernel : $us 字节 (分区 $KERNEL_SIZE)"
echo "rootfs : $rs 字节 (分区 $ROOTFS_SIZE)"

[ "$bs" -le "$BOOT_SIZE" ]   || die "u-boot 超过 1MB 分区"
[ "$us" -le "$KERNEL_SIZE" ] || die "内核超过 4MB 分区"
[ "$rs" -le "$ROOTFS_SIZE" ] || die "rootfs 超过 11MB 分区（请裁剪包集）"

cp "$UBOOT"  "$OUT/boot.bin"
cp "$UIMAGE" "$OUT/kernel.bin"
cp "$ROOTFS" "$OUT/rootfs.jffs2"

# 整片镜像：三个分区依次拼接，空余部分填 0xFF（未编程的 SPI NOR 状态）
{
	cat "$OUT/boot.bin"
	head -c $((BOOT_SIZE - bs)) /dev/zero | tr '\0' '\377'
	cat "$OUT/kernel.bin"
	head -c $((KERNEL_SIZE - us)) /dev/zero | tr '\0' '\377'
	cat "$OUT/rootfs.jffs2"
	head -c $((ROOTFS_SIZE - rs)) /dev/zero | tr '\0' '\377'
} > "$OUT/hi3520d_16m.bin"

[ "$(size_of "$OUT/hi3520d_16m.bin")" -eq "$FLASH_SIZE" ] || die "整片镜像大小不是 16MB"

cat > "$OUT/uboot-env.txt" <<'ENVEOF'
# 在 u-boot 串口（ttyAMA0,115200）下执行：
setenv bootargs 'mem=64M console=ttyAMA0,115200 root=/dev/mtdblock2 rootfstype=jffs2 mtdparts=hi_sfc:1M(boot),4M(kernel),11M(rootfs)'
setenv bootcmd 'sf probe 0;sf read 0x82000000 0x100000 0x400000;bootm 0x82000000'
setenv serverip 192.168.1.100
setenv ipaddr 192.168.1.200
saveenv

# 烧写（tftp 服务器放在 192.168.1.100，镜像放 /srv/tftp）：
sf probe 0
# 1) u-boot（1MB 分区）
tftp 0x82000000 boot.bin
sf erase 0x0 0x100000
sf write 0x82000000 0x0 $filesize
# 2) 内核（4MB 分区）
tftp 0x82000000 kernel.bin
sf erase 0x100000 0x400000
sf write 0x82000000 0x100000 $filesize
# 3) rootfs（11MB 分区）
tftp 0x82000000 rootfs.jffs2
sf erase 0x500000 0xb00000
sf write 0x82000000 0x500000 $filesize

# 或者整片写入（等价于上面三步）：
# tftp 0x82000000 hi3520d_16m.bin
# sf erase 0x0 0x1000000
# sf write 0x82000000 0x0 $filesize

# 复位启动
reset
ENVEOF

( cd "$OUT" && md5sum boot.bin kernel.bin rootfs.jffs2 hi3520d_16m.bin > md5sum.txt )

echo
echo "输出目录: $OUT"
ls -l "$OUT"
cat "$OUT/md5sum.txt"
