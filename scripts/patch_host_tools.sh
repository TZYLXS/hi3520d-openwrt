#!/bin/bash
#
# 让 OpenWRT 19.07 的宿主工具层能在 Debian 13 / gcc 14 上编过。
# 幂等：重复执行不会重复改。
#
#   1) rules.mk 的 HOST_CFLAGS 追加 -Wno-error=implicit-int / implicit-function-declaration
#   2) tools/Makefile 从 BUILD_TOOLCHAIN 工具列表里去掉 libelf（0.8.13 老 configure 在 gcc14 下必失败）
#   3) tools/mkimage/Makefile 换成桩：直接装宿主 /usr/bin/mkimage（+ mkenvimage）
#   4) cmake 3.15.1 的 cmWorkerPool.h 补 #include <cstdint>，并清掉它的 .built/.configured
#
set -u
OW=${1:-/home/debian/hi3520d/openwrt}
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$OW" || { echo "找不到 $OW"; exit 1; }

echo "=== 1) HOST_CFLAGS ==="
python3 - <<'PY'
import io
p = 'rules.mk'
s = io.open(p, encoding='utf-8').read()
if 'Wno-error=implicit-int' in s:
    print('ALREADY')
else:
    old = 'HOST_CFLAGS:=-O2 $(HOST_CPPFLAGS)\n'
    new = ('HOST_CFLAGS:=-O2 $(HOST_CPPFLAGS) -Wno-error=implicit-int '
           '-Wno-error=implicit-function-declaration\n')
    assert old in s, 'rules.mk 里没找到 HOST_CFLAGS 行'
    io.open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
    print('patched')
PY

echo "=== 2) 去掉 host libelf ==="
python3 - <<'PY'
import io
p = 'tools/Makefile'
s = io.open(p, encoding='utf-8').read()
old = 'tools-$(BUILD_TOOLCHAIN) += gmp mpfr mpc libelf expat'
new = 'tools-$(BUILD_TOOLCHAIN) += gmp mpfr mpc expat'
if old in s:
    io.open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
    print('patched')
else:
    print('ALREADY' if new in s else 'PATTERN-NOT-FOUND')
PY

echo "=== 3) mkimage 桩 ==="
mkdir -p tools/mkimage
cat > tools/mkimage/Makefile <<'MK'
#
# 桩：OpenWRT 的 host mkimage 需要 u-boot 2018.03 源码（国内基本拉不动），
# 本项目用宿主 u-boot-tools 的 mkimage 生成 uImage，这里直接安装宿主版本。
#
include $(TOPDIR)/rules.mk

PKG_NAME:=mkimage
PKG_VERSION:=host

include $(INCLUDE_DIR)/host-build.mk

HOST_BUILD_DIR:=$(BUILD_DIR_HOST)/mkimage-host

define Host/Prepare
	mkdir -p $(HOST_BUILD_DIR)
endef

define Host/Compile
endef

define Host/Install
	$(INSTALL_BIN) /usr/bin/mkimage $(STAGING_DIR_HOST)/bin/mkimage
	-if [ -x /usr/bin/mkenvimage ]; then \
		$(INSTALL_BIN) /usr/bin/mkenvimage $(STAGING_DIR_HOST)/bin/mkenvimage; \
	fi
endef

define Host/Clean
	rm -f $(STAGING_DIR_HOST)/bin/mkimage $(STAGING_DIR_HOST)/bin/mkenvimage
endef

$(eval $(call HostBuild))
MK
grep -q '/usr/bin/mkimage' tools/mkimage/Makefile && echo "stub ok"

echo "=== 4) cmake cstdint ==="
make tools/cmake/prepare >/tmp/cmake_prepare.log 2>&1 || true
H="$OW/build_dir/host/cmake-3.15.1/Source/cmWorkerPool.h"
if [ -f "$H" ]; then
	if ! grep -q 'include <cstdint>' "$H"; then
		sed -i '1i #include <cstdint>' "$H"
		echo "cstdint inserted"
	fi
	rm -rf build_dir/host/cmake-3.15.1/.built build_dir/host/cmake-3.15.1/.configured
else
	echo "WARN：还没有 $H（先 make tools/cmake/prepare 会生成）"
fi

echo "=== 宿主工具层适配完成 ==="
