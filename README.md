# Hi3520D OpenWRT 移植说明

基于海思官方 SDK `Hi3520D_SDK_V1.0.2.2`（`Hi3520D_V100R001C01SPC022`）把 Hi3520D 板子适配成 OpenWRT 的一个 target，产出可烧写到 16MB SPI Flash 的镜像。

- OpenWRT 版本：**v19.07.10**
- 内核：**SDK 自带 linux-3.0.8**（海思私有 BSP：mach-hi3520d / hi_sfc / HIETH）
- 用户空间：OpenWRT 自建 **musl** 工具链
- 根文件系统：**jffs2**（64K 擦除块）
- 分区：`1M(boot) / 4M(kernel) / 11M(rootfs)`，SPI Flash 共 16MB

---

## 0. 交付结果（已构建通过）

在 Debian 13 / gcc 14 的编译服务器上，`v19.07.10` 全量构建已经跑通。**固件镜像在 Releases 里下载**，仓库本身只放构建所需的代码与 SDK 组件。

Release 资产（tag `v1.0.0`）：

| 文件 | 大小 | MD5 | 说明 |
| --- | --- | --- | --- |
| `hi3520d_16m.bin` | 16777216 B | `05357e0daca8dca7947597e1b1ee0ee9` | 16MB 整片 SPI 镜像（boot+kernel+rootfs，空隙填 0xFF） |
| `boot.bin` | 226572 B | `78b651e9bcf83510350e6bc9601a9eae` | SDK 编出的 `u-boot_hi3520d.bin`（1M 分区） |
| `kernel.bin` | 3252116 B | `c23c842e45aa7969fd0575cd9c456e25` | 内核 uImage：`Linux-3.0.8`、ARM、load/entry `0x80008000`（4M 分区） |
| `rootfs.jffs2` | 1245188 B | `2a54ac902ee37c610439e42d4a8889cc` | OpenWRT rootfs，jffs2 64K 擦除块（11M 分区） |
| `uboot-env.txt` | — | — | u-boot `bootargs/bootcmd` 与烧写命令 |
| `md5sum.txt` | — | — | 上述文件的校验和 |

内核镜像来自 OpenWRT 的产物 `$(KDIR)/uImage`（`Linux-3.0.8`，ARM，入口 `0x80008000`），
rootfs 来自 `$(KDIR)/root.jffs2-64k`（jffs2 头 `85 19 03 20` 校验通过）。

rootfs 里实际包含的包（`bin/targets/hi3520d/generic/*.manifest`，31 个）：

```
base-files 204.4 / busybox 1.30.1 / dropbear 2019.78 / netifd 2021-01-09 / procd 2020-03-07
uci 2019-09-01 / ubus 2022-02-21 / ubox+logd 2019-06-16 / opkg 2021-01-31 / mtd 24 / fstools
libc(musl 1.1.24) / libgcc1 7.5.0 / libnl-tiny / libubox / libjson-c2 / uclient-fetch / usign
urandom-seed / urngd / getrandom / jshn / jsonfilter / fwtool / openwrt-keyring
```

> 这些是**编译产物**，尚未在真实 Hi3520D 板子上上电验证（见第 7 节）。

---

## 1. 为什么这么适配（关键结论）

| 事实 | 结论 |
| --- | --- |
| SDK 内核是 linux-3.0.8 + 海思私有 BSP（`arch/arm/mach-hi3520d`、`drivers/mtd/devices/hisfc350`、`drivers/net/hieth-sf`） | 不能用 OpenWRT 的 4.x/5.x 内核替代，必须沿用 SDK 内核 |
| SDK 里能编 3.0.8 的交叉编译器只有 `arm-hisiv100nptl-linux`（gcc 4.4.1 + uClibc，i386 静态可执行） | 内核与 u-boot 用海思 gcc 4.4.1；现代 gcc（≥5）编不过 3.0.x |
| 3.0.8 内核里的 uClibc rootfs 与 OpenWRT 的包体系不兼容 | 用户空间改用 OpenWRT musl 工具链重新构建，不混用厂商 rootfs |
| 内核启动参数、分区表都由 u-boot 的 `bootargs` 下发（`mtdparts=hi_sfc:...`） | 镜像布局和 bootargs 必须与 SDK 文档保持一致 |

OpenWRT 侧的实现方式：

- `target/linux/hi3520d/Makefile` 里设置 `KERNEL_PATCHVER:=3.0.8`、`KERNEL_CROSS/KERNEL_CC` 指向海思编译器、`KERNELNAME:=uImage`；
- `.config` 里设置 `CONFIG_EXTERNAL_KERNEL_TREE=/home/debian/hi3520d/kernel-3.0.8`，OpenWRT 的 `include/kernel-defaults.mk` 会直接把 `LINUX_DIR` 软链到这份外部内核树，并用 `KERNEL_CC/KERNEL_CROSS` 编译它（`make uImage modules`）；
- 内核配置基线是 `target/linux/hi3520d/config-3.0.8`（由厂商 `arch/arm/configs/hi3520d_full_defconfig` 派生，见第 5 节差异）；
- 内核头文件（`toolchain/kernel-headers`）也来自同一份外部树，保证 musl 用户空间与内核 ABI 一致。

---

## 2. 目录结构

```
hi3520d-openwrt/
├── target/linux/hi3520d/          # 直接放进 OpenWRT 源码树的 target
│   ├── Makefile                   # ARCH/BOARD/CPU_TYPE、海思交叉编译器、最小包集
│   ├── config-3.0.8               # 内核配置（完整 .config，1853 行，OpenWRT 会与 generic 配置合并）
│   ├── image/Makefile             # 只产出 rootfs(jffs2) 与 uImage，最终布局交给打包脚本
│   └── base-files/
│       └── etc/config/{network,system}
├── overlay/openwrt/               # 需要覆盖到 OpenWRT 源码树外部路径的补丁
│   └── package/network/config/netifd/patches/
│       └── 200-kernel-3.0.8-compat.patch   # netifd 适配 3.0.8 内核头
├── sdk/                           # 构建所需的上游组件（来自海思 SDK 原始压缩包，未改动）
│   ├── linux-3.0.y.tgz            # 内核源码包（含海思 BSP，解出即 linux-3.0.8）
│   └── u-boot-2010.06.tgz         # u-boot 源码包（含 hi3520d 板级代码）
├── scripts/
│   ├── setup_owrt.sh              # 把 target 放进源码树并生成 .config
│   ├── build_owrt.sh              # 一键构建 + 自动打包（7 步）
│   ├── patch_host_tools.sh        # 宿主工具层适配（gcc14 / cmake / mkimage 桩 / 去 libelf）
│   ├── patch_kernel_headers.sh    # 3.0.8 内核 uapi 头修正（un.h / if_ether.h）
│   ├── k_test.sh                  # 单独验证 3.0.8 内核能否用 OpenWRT 配置编过
│   └── pack-images.sh             # 生成 boot/kernel/rootfs 与 16MB 整片镜像 + u-boot 环境变量
└── README.md
```

镜像不放在仓库里（`hi3520d_16m.bin` 有 16MB，且每次构建都会变），统一走 **Releases**。

---

## 3. 硬件相关的事实（已确认）

- **网卡**：Hi3520D 片内集成 2 口 10/100M 交换机 + **内置 PHY**，测试板网口直接从 SOC 引出，中间**没有外置 PHY 芯片**。
  - 对应内核配置：`CONFIG_HIETH_INNER_PHY=y`、`CONFIG_HIETH_PHYID_U=3`、`CONFIG_HIETH_PHYID_D=2`、`CONFIG_HIETH_MII_RMII_MODE_U/D=0`（MII 模式）。
  - 驱动：`drivers/net/hieth-sf`，`CONFIG_HIETH_SWITCH_FABRIC=y`，IOBASE `0x10090000`、IRQ 56。
  - 下行口默认不启用（`CONFIG_HIETH_DOWNPORT_EN is not set`），所以系统里只有一个 `eth0`（上行口）。OpenWRT 的 `etc/config/network` 就按 `eth0` 静态 192.168.1.1/24 配置。
  - 驱动在 MAC 无效时会 `random_ether_addr()` 生成随机 MAC（`drivers/net/hieth-sf/net.c`），不依赖 u-boot 的 `ethaddr`。
- **SATA**：SOC 直出，AHCI 兼容控制器，基址 `0x10080000`、IRQ 52，2 个口。
  - 驱动 `drivers/ata/ahci_platform.c` 在 `module_init` 里自己 `platform_device_register()`，不依赖 mach 层注册设备，所以只要 `CONFIG_HI_SATA=y` + `CONFIG_SATA_AHCI_PLATFORM=y` + `CONFIG_ATA=y` + `CONFIG_BLK_DEV_SD=y` 即可，配置里均已打开（含 3G PHY 调参 `CONFIG_HI_SATA_PHY*`）。
  - 文件系统侧 `CONFIG_EXT4_FS=y`、`CONFIG_VFAT_FS=y`、`CONFIG_MSDOS_PARTITION=y` 已开，插硬盘可直接挂载。
- **USB**：SOC 直出 EHCI(`0x100b0000`) + OHCI(`0x100a0000`)，无外置 PHY。
  - 配置里 `CONFIG_USB_EHCI_HCD=y`、`CONFIG_USB_OHCI_HCD=y`、`CONFIG_USB_STORAGE=y`、`CONFIG_USB=y` 已开；U 盘可识别为 `/dev/sda`。
- **串口**：PL011 UART0，`console=ttyAMA0,115200`。
- **Flash**：SPI NOR 16MB，控制器 `hi_sfc`（`drivers/mtd/devices/hisfc350`），分区表由 bootargs 的 `mtdparts=` 传给内核（`CONFIG_MTD_CMDLINE_PARTS=y`）。

> 注意：SATA/USB 的设备注册都在驱动自己的 `module_init` 里完成，mach 层只注册了两个 UART。所以不要把 `CONFIG_SATA_AHCI_PLATFORM` / `CONFIG_USB_EHCI_HCD` 改成 `=m` 后忘记加载模块，否则对应接口不会出现。

---

## 4. Flash 布局与启动参数

16MB SPI Flash（沿用 SDK 官方文档《Hi3520D SDK 安装以及升级使用说明》）：

| 偏移 | 大小 | 内容 |
| --- | --- | --- |
| 0x000000 | 1MB | u-boot（`u-boot_hi3520d.bin`） |
| 0x100000 | 4MB | 内核 uImage（未压缩，约 3.2~3.4MB） |
| 0x500000 | 11MB | rootfs（jffs2，64K 擦除块） |

u-boot 环境变量（`images/uboot-env.txt` 里也有一份）：

```
setenv bootargs 'mem=64M console=ttyAMA0,115200 root=/dev/mtdblock2 rootfstype=jffs2 mtdparts=hi_sfc:1M(boot),4M(kernel),11M(rootfs)'
setenv bootcmd 'sf probe 0;sf read 0x82000000 0x100000 0x400000;bootm 0x82000000'
saveenv
```

说明：

- `mem=64M` 是 OS 可用内存；SDK 默认把 `0x84000000` 起的 187MB 划给 HiMPP 的 MMZ、`0x8fa00000` 起 5MB 给 JPEG。**本移植默认不启动 HiMPP**，所以这 192MB 目前是浪费的；如果不打算用媒体功能，可把 bootargs 改成 `mem=192M`（Hi3520D 板载 256MB DDR）来给 Linux 更多内存。若以后要接 HiMPP，再改回 `mem=64M` 并加载 `mmz.ko`。
- `root=/dev/mtdblock2` 需要 `CONFIG_MTD_BLOCK=y`（已开）。
- jffs2 挂载在 11MB 分区上，第一次启动内核会把空白区格式化成 jffs2。

烧写（u-boot 下，tftp 服务器 192.168.1.100）：

```
sf probe 0
tftp 0x82000000 boot.bin
sf erase 0x0 0x100000
sf write 0x82000000 0x0 $filesize

tftp 0x82000000 kernel.bin
sf erase 0x100000 0x400000
sf write 0x82000000 0x100000 $filesize

tftp 0x82000000 rootfs.jffs2
sf erase 0x500000 0xb00000
sf write 0x82000000 0x500000 $filesize
reset
```

也可以整片写 `hi3520d_16m.bin`（`sf erase 0x0 0x1000000` + `sf write 0x82000000 0x0 $filesize`），或用编程器直接烧。

---

## 5. 内核配置与厂商 defconfig 的差异

`config-3.0.8` 由 `hi3520d_full_defconfig` 派生，改动只有 OpenWRT 用户空间必需的部分：

| 配置 | 原值 | 改为 | 原因 |
| --- | --- | --- | --- |
| `CONFIG_DEVTMPFS` | 未设置 | `=y` | procd/udev 依赖 /dev 自动创建 |
| `CONFIG_DEVTMPFS_MOUNT` | — | `=y` | 内核自动挂载 devtmpfs |
| `CONFIG_BRIDGE` | 未设置 | `=y` | netifd 的 `option type 'bridge'` 需要 |
| `CONFIG_MAGIC_SYSRQ` | 未设置 | `=y` | 调试 |
| `CONFIG_CGROUPS/CGROUP_DEVICE` | — | `=y` | procd 资源限制 |
| `CONFIG_NAMESPACES/UTS_NS/IPC_NS/PID_NS/NET_NS` | — | `=y` | 容器/命名空间类工具 |
| `CONFIG_DEVMEM` | 未设置 | `=y` | `CONFIG_CRASH_DUMP=y` 需要 `open_port`，否则 `drivers/char/mem.c` 编不过（见 6.3） |

保持不动的关键项：`CONFIG_MTD_HISFC350=y`、`CONFIG_MTD_CMDLINE_PARTS=y`、`CONFIG_JFFS2_FS=y`、`CONFIG_MTD_BLOCK=y`、`CONFIG_HIETH_SWITCH_FABRIC=y`、`CONFIG_HI_SATA=y`、`CONFIG_SATA_AHCI_PLATFORM=y`、`CONFIG_USB_EHCI_HCD=y`、`CONFIG_USB_STORAGE=y`、`CONFIG_EXT4_FS=y`、`CONFIG_VFAT_FS=y`、`CONFIG_VT/FB=y`。

仍为关闭状态、需要时自行打开：`CONFIG_SQUASHFS`（3.0.8 里没有 OpenWRT 需要的 squashfs 选项组合，故 rootfs 用 jffs2）、`CONFIG_NETFILTER`（见第 7 节）。

---

## 6. 构建步骤（编译服务器）

已验证环境：Debian 13 (trixie)、x86_64、gcc 14.2、make 4.4、perl 5.40、Python 3.13、`/lib32` 存在（海思 gcc 4.4.1 是 i386 静态 ELF，可直接运行）。

```bash
# 0) 依赖（缺什么补什么）
sudo apt-get install -y build-essential gawk gettext git libncurses-dev libssl-dev \
    python3 rsync unzip zlib1g-dev wget bzip2 file patch diffutils u-boot-tools

# 1) 装海思工具链（从 SDK 里的 arm-hisiv100-linux.tar.bz2 安装）
#    位置：Hi3520D_SDK_V1.0.2.2/osdrv/toolchain/arm-hisiv100-linux.tar.bz2
tar xjf arm-hisiv100-linux.tar.bz2 -C /tmp/hisi
cd /tmp/hisi/arm-hisiv100-linux && sudo ./cross.install force   # 装到 /opt/hisi-linux-nptl/arm-hisiv100-linux

# 2) 解本仓库 sdk/ 里的内核源码（不要用已经编译过的树）
mkdir -p ~/hi3520d/kernel-3.0.8
tar xzf sdk/linux-3.0.y.tgz -C ~/hi3520d/kernel-3.0.8 --strip-components=1
#   3.0.x 的 kernel/timeconst.pl 在 perl ≥5.22 下会报 defined(@array)，必须打补丁：
sed -i 's/if (!defined(@val)) {/if (!@val) {/' ~/hi3520d/kernel-3.0.8/kernel/timeconst.pl

# 3) 拉 OpenWRT
git clone --depth 1 -b v19.07.10 https://github.com/openwrt/openwrt.git ~/hi3520d/openwrt

# 4) 放入 target 并一键构建（脚本会自动装 target、补 .config、编内核/rootfs、打包镜像）
bash scripts/build_owrt.sh
```

u-boot 不是每次都要重编（Release 里的 `boot.bin` 就是 SDK 原版 `u-boot_hi3520d.bin`）。要自己编的话：

```bash
mkdir -p ~/hi3520d/uboot && tar xzf sdk/u-boot-2010.06.tgz -C ~/hi3520d/uboot --strip-components=1
cd ~/hi3520d/uboot
make ARCH=arm CROSS_COMPILE=/opt/hisi-linux-nptl/arm-hisiv100-linux/target/bin/arm-hisiv100nptl-linux- hi3520d_config
make ARCH=arm CROSS_COMPILE=/opt/hisi-linux-nptl/arm-hisiv100-linux/target/bin/arm-hisiv100nptl-linux-
# 产物：u-boot.bin（要烧的是 SDK 用 mkimage 包装后的 u-boot_hi3520d.bin，见 SDK 的 osdrv/Makefile）
```

构建完成后 `scripts/build_owrt.sh` 会自动调用 `scripts/pack-images.sh`，在构建机上生成 `~/hi3520d/out/images/`（仓库里不放镜像，成品见 Releases）。
脚本 7 步依次是：宿主工具层适配 → 装 target → 装 netifd 补丁 → 修内核 uapi 头 → 种子 `.config`+`defconfig` → `apply_config.sh` → `make -j$(nproc)`，最后打包。

构建日志按编号保存（`~/hi3520d/out/owrt_build*.log`），每次失败原因都记在第 6.1~6.3 节。

单独验证内核（不跑整个 OpenWRT）：

```bash
bash scripts/k_test.sh      # 用 config-3.0.8 在干净内核树上 make uImage
```

### 6.1 构建环境适配（Debian 13 / 现代宿主机会遇到的坑）

OpenWRT 19.07 是 2019 年的代码，放到 Debian 13（gcc 14 / perl 5.40 / 没有 python2）上需要几处环境适配，脚本已处理：

1. **Python 2 前置检查**：`include/prereq-build.mk` 要求 `python` 报告 `Python 2.x`。Debian 13 没有 python2，`scripts/make_python_shim.sh` 会装一个 `/usr/local/bin/python` 包装脚本（`-V` 打印 `Python 2.7.18`，其余参数原样转给 `python3`），让前置检查通过。
2. **`CONFIG_DEVEL=y`**：`EXTERNAL_KERNEL_TREE` 只在 `DEVEL` 打开时才可见，否则 `make defconfig` 会把它重置为空字符串（表现为内核又去下载 kernel.org 的源码）。`scripts/apply_config.sh` 负责补上。
3. **jffs2 rootfs**：19.07 的 `TARGET_ROOTFS_JFFS2` 依赖 `USES_JFFS2`，而 jffs2 rootfs 在 19.07 已处于废弃状态，设备不 `select` 就无法在 menuconfig 里打开。`target/linux/hi3520d/image/Makefile` 里直接 `TARGET_FILESYSTEMS := jffs2-64k` 绕过这一依赖。
4. **内核 host 工具**：3.0.x 的 kconfig/fixdep 在 gcc 14 下会因隐式函数声明报错，`target/linux/hi3520d/Makefile` 已给 `KERNEL_MAKE_FLAGS` 追加 `-Wno-error=implicit-function-declaration`。
5. **`timeconst.pl`**：必须打第 6 步里的补丁，否则内核编译在 `kernel/timeconst.h` 处中断（`Can't use 'defined(@array)'`）。
6. **mkimage**：`make uImage` 依赖宿主机的 `mkimage`（`apt install u-boot-tools`），SDK 自带的 `tools/pc_tools/mkimage` 也可直接用。
   另外 OpenWRT 自己的 `tools/mkimage` 需要下载 u-boot 2018.03 源码（`ftp.denx.de` 在国内基本拉不动）。本 target 不需要 OpenWRT 编出来的 host mkimage，`scripts/patch_host_tools.sh` 会把 `tools/mkimage/Makefile` 换成桩：直接装宿主 `/usr/bin/mkimage`（和 `mkenvimage`，如果有）到 `staging_dir/host/bin`。
7. **cmake 3.15.1 缺 `<cstdint>`**：`build_dir/host/cmake-3.15.1/Source/cmWorkerPool.h` 用了 `std::int64_t` 却没包含 `<cstdint>`，gcc 14 下报 `'ExitStatus' was not declared`。脚本会在首行插入 `#include <cstdint>` 并删掉 `.built/.configured` 强制重编。
8. **宿主 CFLAGS**：`rules.mk` 的 `HOST_CFLAGS` 追加 `-Wno-error=implicit-int -Wno-error=implicit-function-declaration`，否则 gcc 14 会把一批老 configure 探测（`main(){return(0);}`）当成错误。
9. **去掉 host libelf**：`tools/libelf` 是 2009 年的 0.8.13，它的 configure 不接 `CFLAGS`，在 gcc 14 下必然失败（`C compiler cannot create executables`）。它不在 gcc 构建的必需路径（gcc 只用 gmp/mpfr/mpc），`tools/Makefile` 里已从 `BUILD_TOOLCHAIN` 工具列表移除。
10. **代理（可选）**：若宿主直连 `sources.openwrt.org` / `downloads.openwrt.org` 太慢，可在构建时挂局域网 HTTP 代理：
    ```bash
    export http_proxy=http://<代理IP>:7890 https_proxy=http://<代理IP>:7890
    make -j$(nproc) V=sc
    ```
    注意有的上游（如 `nixos.org`、`ftp.denx.de`）走代理反而超时，`scripts/download.pl` 会自动换下一个源；实在不行就按文件名把源码包手工放进 `dl/`（校验会比对 `PKG_HASH` / `LINUX_KERNEL_HASH`）。

### 6.2 用户空间撞上 3.0.8 内核头（本 target 必须打的三个补丁）

OpenWRT 19.07 的用户空间是 2020~2022 年的代码，默认假设内核头 ≥ 4.x；3.0.8 的 uapi 头缺东西，于是编译在 netifd 和 ubox 处反复中断。已经固化成补丁：

11. **netifd（2021-01-09）**：`overlay/openwrt/package/network/config/netifd/patches/200-kernel-3.0.8-compat.patch`，包含三件事：
    - 缺 `ADVERTISED_40000baseKR4/CR4/SR4/LR4_Full`（3.12 之后才有）→ 补 4 个宏；
    - 缺 `FRA_SUPPRESS_PREFIXLEN`（3.0.8 的 `linux/rtnetlink.h` 没有）→ 补 `#define ... 14`；
    - 3.0.8 没有 `IFLA_IPTUN_MAX` / `IFLA_VTI_MAX` / `IFLA_VXLAN_MAX`，netifd 的隧道分发代码块的括号因此失配（报 `expected identifier or '(' before 'else'`）→ 整段隧道类型分发直接返回 `-EINVAL`（本板不用隧道；保留 `system_add_sit_tunnel` 的符号引用来躲 `-Werror=unused-function`）。
12. **netifd 的 `-Wno-unknown-warning-option`**：写在 `netifd/CMakeLists.txt` 里（面向 clang），gcc 7.5 直接 `unrecognized command line option [-Werror]`。同一个补丁文件里把它删掉。
13. **`include/linux/un.h`**：3.0.8 里 `struct sockaddr_un` 用 `sa_family_t` 却没定义，ubox/logd 直接 `#include <linux/un.h>` 时 `unknown type name 'sa_family_t'`。
    改成内核自己的命名 `__kernel_sa_family_t`（新版 uapi 就是这么写的），既自包含又不会和 `linux/socket.h`、musl 的 `sa_family_t` 重复定义。`scripts/patch_kernel_headers.sh` 处理。
14. **`include/linux/if_ether.h`**：`struct ethhdr` 在 3.0.8 是无条件定义，musl 的 `netinet/if_ether.h` 也定义同一个结构，netifd 同时 include 二者 → `redefinition of 'struct ethhdr'`。
    给内核头加 4.x 的 `__UAPI_DEF_ETHHDR` 开关（默认 1），netifd 补丁在文件开头写 `#define __UAPI_DEF_ETHHDR 0`，内核就让出该结构、由 musl 提供。同样由 `scripts/patch_kernel_headers.sh` 处理。

> 注意：这两个头在内核自身编译时也会用到，`patch_kernel_headers.sh` 只做语义等价改名/加开关（`__kernel_sa_family_t` 就是 `unsigned short`），不影响 ABI。

### 6.3 内核侧的两个配置坑

15. **`drivers/char/mem.c` 的 `open_port` 未定义**：厂商 defconfig 里 `CONFIG_DEVMEM` / `CONFIG_DEVKMEM` / `CONFIG_DEVPORT` 全关，但 `CONFIG_CRASH_DUMP=y` 会用到 `open_oldmem → open_port`，于是报 `'open_port' undeclared`。
    解决：`config-3.0.8` 里打开 **`CONFIG_DEVMEM=y`**（顺带得到 `/dev/mem`，flash 调试也用得上）。
16. **`config-3.0.8` 是完整 `.config`**：早期版本是从厂商 defconfig 摘的片段，`make silentoldconfig` 会在 `GCOV_KERNEL` 处 `aborted! Console input/output is redirected`，进而 `No rule to make target 'include/config/auto.conf'`。
    现在的文件是在干净内核树里 `yes '' | make ARCH=arm CROSS_COMPILE=… oldconfig` 补全后的 1853 行完整配置（`# CONFIG_xxx is not set` 也全量展开），OpenWRT 直接拿来合并即可。


---

## 7. 已知限制 / 后续工作

1. **netfilter 未启用**：厂商 defconfig 里 `CONFIG_NETFILTER is not set`，OpenWRT 的 `firewall`/`iptables` 用不了。若需要 NAT/防火墙，要在 `config-3.0.8` 里打开 `CONFIG_NETFILTER=y`、`CONFIG_NF_CONNTRACK`、`CONFIG_NF_NAT`、`CONFIG_IP_NF_IPTABLES` 等，然后重编内核；`DEFAULT_PACKAGES` 里再补 `firewall4`/`iptables`。
2. **HiMPP 未集成**：`package/mpp.tgz`、`package/drv.tgz`（HiMPP 媒体处理、`mmz.ko`）没有并入 OpenWRT。要用媒体功能需要：
   - 按 SDK 方式编出 `mpp` 的 ko，放进 rootfs 的 `/lib/modules/3.0.8/`；
   - bootargs 恢复 `mem=64M`，并在启动脚本里按 SDK 参数加载 `mmz.ko`（187MB @0x84000000 + 5MB JPEG @0x8fa00000）；
   - OpenWRT 侧增加启动脚本 `insmod`。
3. **包集最小化**：3.0.8 内核不支持现代 kmod 包的多数特性，`DEFAULT_PACKAGES` 只保留 `base-files libc libgcc busybox dropbear mtd uci opkg netifd fstools uclient-fetch logd urandom-seed urngd`。加包前先确认它不依赖内核特性（尤其 netfilter、nftables、squashfs）。
4. **11MB rootfs 容量**：装不下 LuCI + 很多工具。需要更大空间可改成 `1M + 3M + 12M` 或裁剪内核（关掉 FB/USB gadget/多余文件系统）。
5. **未做真机验证**：本文档的构建在编译服务器上完成，尚未在实际 Hi3520D 板子上上电跑过；首次上电请务必接串口看启动日志。
6. **SATA/USB 电源与复位**：SOC 直出接口的供电/复位由板级硬件决定，内核不管；如果硬盘/USB 不识别，先量供电和复位脚，再看 `dmesg | grep -i -E 'ata|usb|sd'`。
7. **u-boot 环境变量**：SDK 的 `board/hi3520d/board.c` 只做 `setenv("verify","n")`，默认没有 `bootargs/bootcmd`，必须按第 4 节手工设置并 `saveenv`，否则进不了系统。
8. **`/dev/mem` 已打开**：为解决 `open_port` 未定义，`CONFIG_DEVMEM=y`，root 可以直接读写物理内存。量产固件若不想要这个口子，改成关掉 `CONFIG_CRASH_DUMP` 即可（两者只能留一个）。
9. **最终镜像不由 OpenWRT 的 image 阶段产出**：`target/linux/hi3520d/image/Makefile` 只负责让构建产出 `uImage` 与 `root.jffs2-64k`；1M/4M/11M 的拼装、0xFF 填充、u-boot 环境变量由 `scripts/pack-images.sh` 完成（`build_owrt.sh` 最后一步自动调用）。这样做的原因是 19.07 的 image 流水线按 squashfs/sysupgrade 设计，套 3.0.8 + jffs2 要多写不少模板，收益不大。
10. **netifd 不支持隧道**：为绕开 3.0.8 缺失的 `IFLA_IPTUN_*`，netifd 补丁把 sit/gre/vti/vxlan 等隧道类型统一返回 `-EINVAL`。以太网、静态地址、DHCP 客户端不受影响；需要用隧道时得另找老版本 netifd 或补全那些 `IFLA_*` 枚举。

---

## 8. 常见问题排查

| 现象 | 排查 |
| --- | --- |
| 内核编译报 `Can't use 'defined(@array)' ... timeconst.pl` | 没打 timeconst.pl 补丁（见 6.1 第 5 条） |
| `make uImage` 报找不到 `mkimage` | 宿主机没装 `u-boot-tools`（或把 SDK `tools/pc_tools/mkimage` 加到 PATH） |
| 内核编译报 host 工具隐式声明错误 | target Makefile 已加 `KERNEL_MAKE_FLAGS += HOSTCFLAGS=...-Wno-error=implicit-function-declaration` |
| 内核 `drivers/char/mem.c` 报 `'open_port' undeclared` | `CONFIG_DEVMEM` 没开（6.3 第 15 条） |
| `make silentoldconfig` 报 `Console input/output is redirected` / `No rule to make target 'include/config/auto.conf'` | `config-3.0.8` 是片段而不是完整 `.config`（6.3 第 16 条） |
| netifd 报 `redefinition of 'struct ethhdr'` | 内核 `if_ether.h` 没加 `__UAPI_DEF_ETHHDR` 开关（6.2 第 14 条） |
| netifd 报 `'ADVERTISED_40000baseKR4_Full' undeclared` 或 `expected identifier or '(' before 'else'` | netifd 补丁没装上（6.2 第 11 条），检查 `package/network/config/netifd/patches/` 下有没有 `200-kernel-3.0.8-compat.patch` |
| netifd 报 `unrecognized command line option '-Wno-unknown-warning-option'` | netifd `CMakeLists.txt` 里的 clang 选项，补丁里已删（6.2 第 12 条） |
| logd/ubox 报 `unknown type name 'sa_family_t'` | 内核 `include/linux/un.h` 未修正（6.2 第 13 条） |
| netifd 补丁 dry-run 通过、编译却仍报错 | `build_dir/target-*/netifd-*` 里的源码是旧的，`rm -rf` 掉让它重新解包再打补丁 |
| 启动停在 `Uncompressing Linux...` 后无输出 | 内核 `bootargs` 里 `console=ttyAMA0,115200` 丢了，或 uImage 加载地址与 `bootcmd` 的 `0x82000000` 不一致 |
| `VFS: Cannot open root device "mtdblock2"` | `mtdparts=` 没传或分区名/顺序不对；确认 `CONFIG_MTD_CMDLINE_PARTS=y`、`CONFIG_MTD_BLOCK=y` |
| rootfs 挂载后立刻 panic / jffs2 校验错 | rootfs 镜像没用 64K 擦除块（`mkfs.jffs2 -e 64KiB`），或分区大小与镜像不匹配 |
| 网络起不来 | 确认 `eth0` 存在（`ifconfig -a`）；内置 PHY 模式下 `CONFIG_HIETH_INNER_PHY=y` 必须是 y；看 `dmesg | grep -i hieth` |
| 找不到 `/dev/sda` | `CONFIG_USB_STORAGE`/`CONFIG_BLK_DEV_SD` 是否为 y；`dmesg | grep -i usb` |
| 找不到 SATA 盘 | `CONFIG_HI_SATA`/`CONFIG_SATA_AHCI_PLATFORM` 是否为 y；`dmesg | grep -i -E 'ahci|ata'` |

---

## 9. 代码来源与版权

- `target/`、`scripts/`、`overlay/`、本 README：针对本板子的适配代码，可自由使用。
- `sdk/linux-3.0.y.tgz`、`sdk/u-boot-2010.06.tgz`：取自海思 `Hi3520D_SDK_V1.0.2.2` 的原始压缩包，**未做任何改动**，仅作为构建输入放在仓库里，版权归海思（HiSilicon）/ 原厂所有，遵循其 SDK 许可；如需公开分发请自行确认授权范围。
- 工具链 `arm-hisiv100-linux.tar.bz2` 没有放进仓库（海思 gcc 4.4.1，且是 i386 静态 ELF 的厂商包），需要时从原 SDK 获取并按 6 节步骤安装。
- OpenWRT 源码不打进仓库，按 6 节 `git clone -b v19.07.10` 拉取。
