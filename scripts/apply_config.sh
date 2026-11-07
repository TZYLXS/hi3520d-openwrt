#!/bin/bash
# 给 OpenWRT .config 补上 hi3520d 需要的选项，然后跑 oldconfig
set -e
cd /home/debian/hi3520d/openwrt

python3 - <<'PY'
import io, re
p = '.config'
s = io.open(p, encoding='utf-8').read()

def setstr(s, key, val):
    s = re.sub(r'^%s=.*$' % key, '%s="%s"' % (key, val), s, flags=re.M)
    if not re.search(r'^%s=' % key, s, flags=re.M):
        s += '\n%s="%s"\n' % (key, val)
    return s

def setval(s, key, val):
    s = re.sub(r'^# %s is not set$' % key, '%s=%s' % (key, val), s, flags=re.M)
    s = re.sub(r'^%s=.*$' % key, '%s=%s' % (key, val), s, flags=re.M)
    if not re.search(r'^%s=' % key, s, flags=re.M):
        s += '\n%s=%s\n' % (key, val)
    return s

s = setval(s, 'CONFIG_DEVEL', 'y')
s = setstr(s, 'CONFIG_EXTERNAL_KERNEL_TREE', '/home/debian/hi3520d/kernel-3.0.8')
s = setval(s, 'CONFIG_TARGET_KERNEL_PARTSIZE', '4')
s = setval(s, 'CONFIG_TARGET_ROOTFS_PARTSIZE', '11')
io.open(p, 'w', encoding='utf-8').write(s)
print('config patched')
PY

yes '' | make oldconfig > /tmp/oldconfig.log 2>&1 || true

echo "---- verify ----"
grep CONFIG_DEVEL .config || true
grep CONFIG_EXTERNAL_KERNEL_TREE .config || true
grep CONFIG_TARGET_KERNEL_PARTSIZE .config || true
grep CONFIG_TARGET_ROOTFS_PARTSIZE .config || true
grep CONFIG_TARGET_hi3520d_DEVICE .config || true
