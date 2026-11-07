include $(TOPDIR)/rules.mk

ARCH:=arm
BOARD:=hi3520d
BOARDNAME:=HiSilicon Hi3520D
CPU_TYPE:=cortex-a9
FEATURES:=

# 海思 SDK 配套内核为 linux-3.0.8（ARMv7 / PL011 / hi_sfc / HIETH），
# 只有 SDK 自带的 gcc 4.4.1 (arm-hisiv100nptl) 能编译它；
# OpenWRT 自身的 musl/gcc 工具链只用于用户空间。
KERNEL_PATCHVER:=3.0.8
KERNEL_CROSS:=/opt/hisi-linux-nptl/arm-hisiv100-linux/target/bin/arm-hisiv100nptl-linux-
KERNEL_CC:=$(KERNEL_CROSS)gcc
KERNELNAME:=uImage

include $(INCLUDE_DIR)/target.mk

# 3.0.x 的 host 工具（kconfig/fixdep 等）在 gcc 14 下会因隐式声明报错，放宽该告警
KERNEL_MAKE_FLAGS += HOSTCFLAGS="$(HOST_CFLAGS) -Wno-error=implicit-function-declaration"

# 11MB rootfs 分区内只放最小可用路由系统（LuCI 可选，见 README）
DEFAULT_PACKAGES:=base-files libc libgcc busybox dropbear mtd uci opkg netifd fstools uclient-fetch logd urandom-seed urngd

$(eval $(call BuildTarget))
