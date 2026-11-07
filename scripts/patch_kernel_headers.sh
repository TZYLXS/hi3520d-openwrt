#!/bin/bash
#
# 给 Linux 3.0.8 的内核 uapi 头补两处现代修正（幂等，可反复执行）
#   1) include/linux/un.h：sa_family_t → __kernel_sa_family_t
#      3.0.8 的 un.h 用了 sa_family_t 却没有定义，直接用 <linux/un.h> 的用户态程序
#      （如 ubox/logd）会报 unknown type name；用内核自己的 __kernel_sa_family_t
#      命名还能避免与 <linux/socket.h>、musl 的 sa_family_t 重复定义。
#   2) include/linux/if_ether.h：给 struct ethhdr 加 __UAPI_DEF_ETHHDR 开关
#      （4.x 起的内核做法）。musl 的 <netinet/if_ether.h> 也定义了 struct ethhdr，
#      两者同时 include（netifd 就是这样）会 redefinition；打开开关后 netifd 在
#      #include 前定义 __UAPI_DEF_ETHHDR 0，内核让出该结构。
#
# 用法： patch_kernel_headers.sh <内核树路径> [OpenWRT 根目录]
#   第二参数给出时，同时改 staging_dir/toolchain-*/include/linux/ 下已安装的头。
#
set -u

K=${1:?用法: $0 <内核树> [OpenWRT 根目录]}
OW=${2:-}

[ -f "$K/include/linux/un.h" ] || { echo "找不到 $K/include/linux/un.h"; exit 1; }

apply_un() {
	python3 - "$1" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
changed = False
old_block = ('#ifndef sa_family_t_defined\n#define sa_family_t_defined\n'
             'typedef unsigned short sa_family_t;\n#endif\n\n')
if old_block in s:
    s = s.replace(old_block, ''); changed = True
if 'sa_family_t sun_family;' in s and '__kernel_sa_family_t' not in s:
    s = ('#ifndef __kernel_sa_family_t_defined\n#define __kernel_sa_family_t_defined\n'
         'typedef unsigned short __kernel_sa_family_t;\n#endif\n\n') + s
    s = s.replace('sa_family_t sun_family;', '__kernel_sa_family_t sun_family;')
    changed = True
if changed:
    io.open(p, 'w', encoding='utf-8').write(s)
    print('un.h      patched  ' + p)
else:
    print('un.h      already  ' + p)
PY
}

apply_eth() {
	python3 - "$1" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
if '__UAPI_DEF_ETHHDR' in s:
    print('if_ether  already  ' + p); raise SystemExit
i = s.index('struct ethhdr {')
j = s.index('packed));', i) + len('packed));')
s = (s[:i] + '#ifndef __UAPI_DEF_ETHHDR\n#define __UAPI_DEF_ETHHDR 1\n#endif\n'
     '#if __UAPI_DEF_ETHHDR\n' + s[i:j] + '\n#endif /* __UAPI_DEF_ETHHDR */' + s[j:])
io.open(p, 'w', encoding='utf-8').write(s)
print('if_ether  patched  ' + p)
PY
}

echo "== 内核源码头 =="
apply_un "$K/include/linux/un.h"
apply_eth "$K/include/linux/if_ether.h"

if [ -n "$OW" ]; then
	echo "== 已安装的工具链头（重编内核时会被重新覆盖，但可让当前构建立即生效） =="
	for h in "$OW"/staging_dir/toolchain-*/include/linux/un.h; do
		[ -f "$h" ] && apply_un "$h"
	done
	for h in "$OW"/staging_dir/toolchain-*/include/linux/if_ether.h; do
		[ -f "$h" ] && apply_eth "$h"
	done
fi

echo
echo "完成。改动后会触发内核重编（这些头同时被内核自身使用，语义等价，不影响 ABI）。"
