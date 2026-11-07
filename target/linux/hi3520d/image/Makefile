include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/image.mk

# 内核不在这里重新打包，直接复制 OpenWRT 内核构建阶段产出的 uImage
define Build/copy-kernel
	$(CP) $(KDIR)/uImage $@
endef

define Device/Default
  PROFILES := Default
  KERNEL_NAME := uImage
  KERNEL := copy-kernel
endef

define Device/hi3520d_dmeb
  DEVICE_TITLE := Hi3520D DMEB (16MB SPI, 1M boot + 4M kernel + 11M rootfs)
endef
TARGET_DEVICES += hi3520d_dmeb

# 19.07 的 TARGET_ROOTFS_JFFS2 依赖 USES_JFFS2（jffs2 rootfs 已处于废弃状态，
# 设备不 select 就无法在 menuconfig 里打开），这里直接指定要构建的文件系统。
TARGET_FILESYSTEMS := jffs2-64k

# 产出 $(KDIR)/root.jffs2-64k（64K 擦除块）与 $(KDIR)/uImage；
# 1M/4M/11M 的最终拼装和 u-boot 环境变量由 scripts/pack-images.sh 完成。
$(eval $(call BuildImage))
