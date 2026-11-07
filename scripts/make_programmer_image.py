#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
为外部 SPI 烧录器生成 Hi3520D 16MB 整片镜像。

和 hi3520d_16m.bin 的区别：把 u-boot 环境变量按 u-boot 2010.06 的格式
（4 字节 CRC32 + 环境字符串，0x40000 字节）写到 SPI 偏移 0x80000，
这样用 CH341A 之类的编程器整片写入后，板子上电就能直接引导，
不需要再进串口敲 setenv / saveenv。

输入：boot.bin(1MB 分区内容)、kernel.bin、rootfs.jffs2
输出：hi3520d_16m_programmer.bin、boot_env_1m.bin、env.bin

用法：python3 make_programmer_image.py <boot.bin> <kernel.bin> <rootfs.jffs2> <输出目录>
"""

import os
import struct
import sys
import zlib

FLASH_SIZE = 16 * 1024 * 1024
BOOT_SIZE = 1 * 1024 * 1024
KERNEL_SIZE = 4 * 1024 * 1024
ROOTFS_SIZE = 11 * 1024 * 1024

ENV_OFFSET = 0x80000          # u-boot include/configs/hi3520d.h: CONFIG_ENV_OFFSET
ENV_SIZE = 0x40000            # CONFIG_ENV_SIZE（含 4 字节 CRC 头）

# 设备上实际要用的环境变量。bootargs/bootcmd 必须和分区布局一致。
ENV_VARS = [
    ("baudrate", "115200"),
    ("bootdelay", "2"),
    ("bootcmd", "sf probe 0;sf read 0x82000000 0x100000 0x400000;bootm 0x82000000"),
    ("bootargs", "mem=64M console=ttyAMA0,115200 root=/dev/mtdblock2 "
                 "rootfstype=jffs2 mtdparts=hi_sfc:1M(boot),4M(kernel),11M(rootfs)"),
    ("ipaddr", "192.168.1.200"),
    ("serverip", "192.168.1.100"),
    ("gatewayip", "192.168.1.1"),
    ("netmask", "255.255.255.0"),
    ("bootfile", "hi3520d_16m.bin"),
    ("mtdparts", "hi_sfc:1M(boot),4M(kernel),11M(rootfs)"),
]


def build_env_blob():
    """返回 ENV_SIZE 字节的 u-boot 环境块：crc32 + key=value\\0..."""
    data = b"".join(
        k.encode() + b"=" + v.encode() + b"\x00" for k, v in ENV_VARS
    ) + b"\x00"
    body_len = ENV_SIZE - 4
    if len(data) > body_len:
        raise SystemExit("环境变量超过 %d 字节" % body_len)
    data = data + b"\x00" * (body_len - len(data))
    crc = zlib.crc32(data) & 0xFFFFFFFF
    return struct.pack("<I", crc) + data


def main():
    if len(sys.argv) != 5:
        print(__doc__)
        raise SystemExit(2)

    boot_path, kernel_path, rootfs_path, outdir = sys.argv[1:5]
    boot = open(boot_path, "rb").read()
    kernel = open(kernel_path, "rb").read()
    rootfs = open(rootfs_path, "rb").read()

    if len(boot) > ENV_OFFSET:
        raise SystemExit("u-boot 二进制 %d 字节，已经压到环境区 0x%X" % (len(boot), ENV_OFFSET))
    if len(kernel) > KERNEL_SIZE:
        raise SystemExit("内核超过 4MB 分区")
    if len(rootfs) > ROOTFS_SIZE:
        raise SystemExit("rootfs 超过 11MB 分区")

    env = build_env_blob()

    # 整片镜像：未使用的区域保持 0xFF（相当于擦除后的 SPI NOR）
    flash = bytearray(b"\xFF" * FLASH_SIZE)
    flash[0:len(boot)] = boot
    flash[ENV_OFFSET:ENV_OFFSET + ENV_SIZE] = env
    base = BOOT_SIZE
    flash[base:base + len(kernel)] = kernel
    base += KERNEL_SIZE
    flash[base:base + len(rootfs)] = rootfs

    # boot 分区单独一份（含环境），方便只重写 u-boot 区
    boot_part = bytearray(flash[0:BOOT_SIZE])

    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "hi3520d_16m_programmer.bin"), "wb") as f:
        f.write(flash)
    with open(os.path.join(outdir, "boot_env_1m.bin"), "wb") as f:
        f.write(boot_part)
    with open(os.path.join(outdir, "env.bin"), "wb") as f:
        f.write(env)

    print("u-boot      : %d 字节" % len(boot))
    print("env         : %d 字节 @ 0x%X (crc 已算)" % (ENV_SIZE, ENV_OFFSET))
    print("kernel      : %d 字节 @ 0x%X" % (len(kernel), BOOT_SIZE))
    print("rootfs      : %d 字节 @ 0x%X" % (len(rootfs), BOOT_SIZE + KERNEL_SIZE))
    print("整片镜像    : %d 字节" % len(flash))


if __name__ == "__main__":
    main()
