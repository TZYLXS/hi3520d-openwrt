include $(TOPDIR)/rules.mk

PKG_NAME:=hi3520d-smb
PKG_VERSION:=1.0
PKG_RELEASE:=1

PKG_LICENSE:=GPL-2.0
PKG_MAINTAINER:=

include $(INCLUDE_DIR)/package.mk

define Package/hi3520d-smb
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=SATA dual-disk mount and Samba tuning for Hi3520D
  DEPENDS:=+samba36-server
endef

define Package/hi3520d-smb/description
  Mounts both SATA ports under /mnt, creates the Samba account, and installs
  a smb.conf template tuned for a single-core Cortex-A9 without NEON.
endef

define Package/hi3520d-smb/conffiles
/etc/hi3520d-smb/samba.config
/etc/hi3520d-smb/smb.conf.template
endef

define Build/Compile
endef

# 配置不直接落到 /etc/config/samba、/etc/samba/smb.conf.template：那两个路径
# samba36-server 自己也会装，opkg 安装顺序不定，最后留下的可能是它的默认文件。
# 先放到 /etc/hi3520d-smb/，由 uci-defaults 在所有包装完之后统一覆盖。
define Package/hi3520d-smb/install
	$(INSTALL_DIR) $(1)/etc/hi3520d-smb
	$(INSTALL_CONF) ./files/samba.config $(1)/etc/hi3520d-smb/samba.config
	$(INSTALL_CONF) ./files/smb.conf.template $(1)/etc/hi3520d-smb/smb.conf.template
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/sata-mount.init $(1)/etc/init.d/sata-mount
	$(INSTALL_BIN) ./files/smbuser.init $(1)/etc/init.d/smbuser
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/90-hi3520d-smb $(1)/etc/uci-defaults/90-hi3520d-smb
	$(INSTALL_DIR) $(1)/mnt/sata1 $(1)/mnt/sata2
endef

$(eval $(call BuildPackage,hi3520d-smb))
