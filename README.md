# Hi3520D 平台 OpenWRT 19.07.10 的移植实现与板级验证

**摘要**　海思 Hi3520D 的官方 SDK 停留在 2013 年前后的软件栈：linux-3.0.8 内核、uClibc 根文件系统、没有包管理，网络配置靠手写脚本。本文把这块板子接进 OpenWRT 19.07.10 的构建体系，做法是保留厂商内核与板级驱动、换掉整个用户空间，最终产出可直接烧写到 16MB SPI Flash 的整片镜像。移植过程中真正花时间的不是写 target 的几十行 Makefile，而是三类摩擦：一是 2019 年的 OpenWRT 构建系统跑在 2026 年的宿主工具链上，二是 2020 年之后的用户空间代码默认内核头 ≥ 4.x，三是厂商内核配置本身有缺口。全文记录了这三类问题的现象、定位依据和最终处理方式，共 16 处改动，其中 3 处已固化成可复用的补丁文件。镜像大小为 16777216 字节，MD5 为 `23432c522bdb115ede327cc17bb9361c`，已在实板上完成烧写与上电验证，串口控制台、以太网、USB 与 SATA 存储均工作正常。在此之上又做了一轮功能扩展：把 SMB 共享做进固件、让 SoC 的两个 SATA 口都参与挂载，并给外部编程器单独出了一份带 u-boot 环境的整片镜像。

**关键词**　OpenWRT；Hi3520D；嵌入式系统移植；linux-3.0.8；交叉编译；内核用户空间 ABI

---

## 1 引言

Hi3520D 是海思面向视频监控的 SoC，Cortex-A9 单核，板载 256MB DDR，外挂 16MB SPI NOR。它的 SDK（`Hi3520D_SDK_V1.0.2.2`，发行包 `Hi3520D_V100R001C01SPC022`）自带一套完整的板级支持：私有 mach 层、SPI Flash 控制器 `hisfc350`、带内置 PHY 的以太网驱动 `hieth-sf`、SATA/USB 控制器驱动，以及基于 uClibc 的根文件系统。

问题在于这套用户空间几乎没有维护价值。要改网络配置得改 `/etc/init.d` 里的 shell 脚本，装软件没有包管理，进程守护靠 busybox 的 `inetd`。OpenWRT 的 procd、netifd、uci、opkg 这一套恰好是这类设备最缺的东西，于是有了本文的工作：把 Hi3520D 变成 OpenWRT 的一个 target。

移植路线上有一个约束是硬的，先摆出来：3.0.8 内核里的板级代码（`arch/arm/mach-hi3520d`、`drivers/mtd/devices/hisfc350`、`drivers/net/hieth-sf`）是海思私有的，没有 upstream 版本，也不可能用 OpenWRT 的 4.x/5.x 内核替代——换内核等于重写全部板级驱动。所以本移植采用混合方案：**内核与 u-boot 保持厂商原样，只把用户空间整体换成 OpenWRT**。后文所有设计选择都由这个前提推出来。

---

## 2 平台与约束

### 2.1 硬件事实

测试板的网络、USB、SATA 三个接口全部从 SoC 直接引出，中间没有任何外置 PHY 或桥接芯片。这一点决定了驱动配置，也决定了排查方向——接口不通时先怀疑驱动和时钟，而不是外部器件。

| 接口 | 控制器与资源 | 关键内核配置 |
| --- | --- | --- |
| 以太网 | `hieth-sf`，基址 `0x10090000`，IRQ 56；片内 2 口 10/100M 交换 + 内置 PHY | `CONFIG_HIETH_SWITCH_FABRIC=y`、`CONFIG_HIETH_INNER_PHY=y`、`CONFIG_HIETH_PHYID_U=3`、`CONFIG_HIETH_PHYID_D=2` |
| SATA | AHCI 兼容，基址 `0x10080000`，IRQ 52，2 个口 | `CONFIG_HI_SATA=y`、`CONFIG_SATA_AHCI_PLATFORM=y`、`CONFIG_ATA=y`、`CONFIG_BLK_DEV_SD=y` |
| USB | EHCI `0x100b0000` + OHCI `0x100a0000`，host 模式 | `CONFIG_USB=y`、`CONFIG_USB_EHCI_HCD=y`、`CONFIG_USB_OHCI_HCD=y`、`CONFIG_USB_STORAGE=y` |
| 串口 | PL011 UART0，`console=ttyAMA0,115200` | 内核自带 |
| Flash | SPI NOR 16MB，控制器 `hisfc350`，分区表由 bootargs 下发 | `CONFIG_MTD_HISFC350=y`、`CONFIG_MTD_CMDLINE_PARTS=y`、`CONFIG_MTD_BLOCK=y` |

两个细节值得单独说明，它们都影响后续的构建配置。

第一，以太网下行口默认关闭（`CONFIG_HIETH_DOWNPORT_EN` 未设置），系统里只会出现一个 `eth0`。驱动在 MAC 地址无效时不读 u-boot 的 `ethaddr`，而是调 `random_ether_addr()` 生成随机地址（`drivers/net/hieth-sf/net.c`），所以每次擦除环境变量后 MAC 会变。`etc/config/network` 按 `eth0` 静态 `192.168.1.1/24` 配置。

第二，SATA 和 USB 的设备注册不在 mach 层。`ahci_platform.c` 在自己的 `module_init` 里 `platform_device_register()`，USB 侧则没有等价的注册代码，靠控制器驱动自行探测。这带来一个操作上的约束：这两个选项不能改成 `=m` 后忘记加载模块，否则接口直接不出现；也意味着 USB 枚举是整个移植里唯一没有静态代码依据、只能靠实测确认的环节。

### 2.2 SDK 组成

| 组件 | 版本 | 用途 | 备注 |
| --- | --- | --- | --- |
| 内核源码 | linux-3.0.8（`osdrv/kernel/linux-3.0.y.tgz`，96.5MB） | 内核与内核头 | 含海思 BSP |
| u-boot 源码 | u-boot-2010.06（`osdrv/uboot/u-boot-2010.06.tgz`，12.5MB） | bootloader | 含 `hi3520d` 板级代码 |
| 工具链 | `arm-hisiv100nptl-linux`，gcc 4.4.1 + uClibc | 编内核和 u-boot | i386 静态 ELF，x86_64 宿主需 `/lib32` |
| 媒体包 | `package/mpp.tgz`、`package/drv.tgz` | HiMPP 与 MMZ | 本次未集成 |

工具链这一项是整条链路里最别扭的地方。SDK 里能编 3.0.8 的编译器只有 gcc 4.4.1，而现代 gcc（≥5）在 3.0.x 上会因 `asm` 语法和隐式函数声明大面积报错，没有修复价值。所以内核侧必须用它，用户空间侧则不能用它——uClibc 与 OpenWRT 的包体系不兼容，也没有对应的 libc 头。方案里因此存在两套编译器并行，这在 3 节展开。

### 2.3 Flash 布局与启动链

分区沿用 SDK 文档《Hi3520D SDK 安装以及升级使用说明》的划分，没有改动：

| 偏移 | 大小 | 内容 |
| --- | --- | --- |
| `0x000000` | 1MB | u-boot（`u-boot_hi3520d.bin`） |
| `0x100000` | 4MB | 内核 uImage（未压缩，实际 3.2MB 左右） |
| `0x500000` | 11MB | rootfs（jffs2，64K 擦除块） |

u-boot 的 `board.c` 只做了一件事——`setenv("verify","n")`，没有预置 `bootargs` 和 `bootcmd`。所以烧完第一次必须手工设置这两条并 `saveenv`，否则板子停在命令行不动：

```
setenv bootargs 'mem=64M console=ttyAMA0,115200 root=/dev/mtdblock2 rootfstype=jffs2 mtdparts=hi_sfc:1M(boot),4M(kernel),11M(rootfs)'
setenv bootcmd 'sf probe 0;sf read 0x82000000 0x100000 0x400000;bootm 0x82000000'
saveenv
```

---

## 3 移植方案

### 3.1 用外部内核树，而不是让 OpenWRT 下载内核

OpenWRT 默认自己管理内核源码和补丁队列，支持外部树的方式是 `CONFIG_EXTERNAL_KERNEL_TREE`。设好这个变量之后，`include/kernel-defaults.mk` 会把 `LINUX_DIR` 软链到指定目录，接着照常执行 `make uImage modules`，只是编译器和配置文件都换成我们指定的。这条路径对本移植是必需的：3.0.8 的源码只存在于厂商压缩包里，OpenWRT 的 kernel.org 下载逻辑拿不到它。

有三个配套设置容易漏：

- `KERNEL_PATCHVER:=3.0.8` 写在 `target/linux/hi3520d/Makefile` 里，决定 OpenWRT 去找 `config-3.0.8` 而不是 `config-4.14`；
- `KERNEL_CROSS` / `KERNEL_CC` 指向海思编译器，`KERNELNAME:=uImage` 指定产物名；
- 外部树只在 `CONFIG_DEVEL=y` 时可见。不打开的话，`make defconfig` 会把 `EXTERNAL_KERNEL_TREE` 重置成空字符串，然后内核转头去下载 kernel.org 的源码——这个失败现象很有迷惑性，看起来像网络问题。`scripts/apply_config.sh` 负责补这一项。

内核头也来自同一份树（`toolchain/kernel-headers`）。这一点看起来是细节，实际是保证 musl 用户空间与 3.0.8 内核 ABI 一致的前提，也是 4.2 节那几处 uapi 冲突的来源。

### 3.2 两套编译器并存

内核：海思 gcc 4.4.1 + uClibc 头，只能编内核和 u-boot。
用户空间：OpenWRT 自建 musl 工具链（gcc 7.5.0），编 busybox、procd、netifd 等。

两套编译器意味着两份 libc 头、两种 ABI 假设，中间靠内核 uapi 头对齐。这条缝里出的问题全部集中在 4.2 节。实践中判断"该用哪套"很简单：凡是进 `target/linux/hi3520d` 的内核侧代码走海思编译器，凡是 `package/` 下的包走 musl 工具链，交叉点只有内核头。

### 3.3 rootfs 用 jffs2，且要靠 image Makefile 绕过依赖

19.07 的 squashfs 路线对本板不适用——3.0.8 里没有 OpenWRT 期望的那组 squashfs 选项，而且 11MB 分区上做只读根 + overlay 的收益不大。选择 jffs2 时遇到一个构建系统层面的障碍：`TARGET_ROOTFS_JFFS2` 依赖设备 `select` 出的 `USES_JFFS2`，而 jffs2 rootfs 在 19.07 已是废弃状态，新设备不会自动选它，menuconfig 里根本打不开。

绕过方式是在 `target/linux/hi3520d/image/Makefile` 里直接写 `TARGET_FILESYSTEMS := jffs2-64k`，跳过对 `USES_JFFS2` 的依赖判断。代价是放弃 OpenWRT 的 sysupgrade 元数据生成——本板用 u-boot 的 `sf` 命令烧写，本来也不需要那套东西。

### 3.4 目录组织

```
target/linux/hi3520d/        ARCH/BOARD/CPU_TYPE、海思编译器、最小包集
    Makefile
    config-3.0.8             完整 .config，1853 行
    image/Makefile           只产出 rootfs(jffs2) 与 uImage
    base-files/etc/config/   network、system
overlay/openwrt/             需要落到源码树其它位置的补丁
    package/network/config/netifd/patches/200-kernel-3.0.8-compat.patch
scripts/                     setup / build / patch_host_tools / patch_kernel_headers
                             k_test / pack_images
sdk/                         linux-3.0.y.tgz、u-boot-2010.06.tgz（原包未改）
```

镜像不进仓库。`hi3520d_16m.bin` 每次构建都会变，且 16MB 对 git 不友好，成品统一放 Releases。

---

## 4 实现中的问题与处理

这一节按"层"组织：宿主工具、用户空间与内核头、内核配置。判据统一为报错现象——不是猜的，是构建日志里真实中断的位置。

### 4.1 宿主工具层（10 处）

把 2019 年的构建系统搬到 Debian 13 上，最先撞的是构建工具自身。[表 4-1] 列出了全部 10 处，其中 4 处值得单独说。

| # | 现象 | 处理 |
| --- | --- | --- |
| 1 | `prereq-build.mk` 要求 `python` 报 `Python 2.x` | `make_python_shim.sh` 装 `/usr/local/bin/python` 包装脚本，`-V` 输出 2.7.18，其余参数转给 python3 |
| 2 | `EXTERNAL_KERNEL_TREE` 被 defconfig 重置为空 | `apply_config.sh` 补 `CONFIG_DEVEL=y` |
| 3 | jffs2 rootfs 在 menuconfig 中不可选 | `TARGET_FILESYSTEMS := jffs2-64k`（3.3 节） |
| 4 | 3.0.x 的 kconfig/fixdep 在 gcc 14 下隐式声明报错 | `KERNEL_MAKE_FLAGS` 追加 `-Wno-error=implicit-function-declaration` |
| 5 | `kernel/timeconst.pl` 报 `Can't use 'defined(@array)'` | perl ≥ 5.22 移除了该语法，`sed` 改成 `if (!@val)` |
| 6 | OpenWRT 的 `tools/mkimage` 要下载 u-boot 2018.03 源码 | 换成桩 Makefile，直接装宿主 `/usr/bin/mkimage` 进 `staging_dir/host/bin` |
| 7 | cmake 3.15.1 的 `cmWorkerPool.h` 未包含 `<cstdint>` | 首行插入 include，删 `.built/.configured` 强制重编 |
| 8 | 老 configure 探测 `main(){return(0);}` 被判错 | `HOST_CFLAGS` 加 `-Wno-error=implicit-int -Wno-error=implicit-function-declaration` |
| 9 | `tools/libelf` 0.8.13 报 `C compiler cannot create executables` | 从 `BUILD_TOOLCHAIN` 工具列表移除（gcc 只用 gmp/mpfr/mpc） |
| 10 | 上游源码拉取慢/超时 | 可挂 HTTP 代理；不行就按文件名手工放进 `dl/`（校验会比对 `PKG_HASH`） |

`timeconst.pl` 这一处是 3.0.x 与现代 perl 的已知不兼容，报错发生在内核编译早期，容易被误判成内核源码损坏。改法只有一行，但不看报错原文很难想到。

`mkimage` 的处理值得解释。`make uImage` 需要一个能打 uImage 头的宿主工具，OpenWRT 的做法是自己编一个，而这需要下载 u-boot 2018.03 的源码。`ftp.denx.de` 在国内基本拉不动，最初试过把 `tools/mkimage` 整个目录删掉，结果 `tools/Makefile` 里仍有引用，构建在后面才炸。最后改成保留目录、把它的 Makefile 换成一个"复制宿主二进制"的桩，既满足依赖图又不触发下载。宿主侧装 `u-boot-tools` 即可。

`libelf` 那处也走了弯路。它 2009 年的 configure 用 `main(){return(0);}` 探测编译器，gcc 14 把 `-Wimplicit-int` 当错误，于是报"C compiler cannot create executables"。先试了给 `HOST_CFLAGS` 放宽 `-Werror`，没用——这个老 configure 不读 `CFLAGS` 环境变量；又试 `HOST_CONFIGURE_VARS` 显式传参，仍被 `host-build.mk` 的变量传递规则挡掉。最后确认它根本不在 gcc 的依赖路径上（gcc 只需要 gmp、mpfr、mpc），直接从工具列表删掉，比继续和它较劲划算。

### 4.2 用户空间撞上 3.0.8 的内核头（4 处）

这一类问题的共同原因是：OpenWRT 19.07 的用户空间代码（netifd 2021-01-09、ubox 2019-06）默认内核头 ≥ 4.x，而 3.0.8 的 uapi 头缺东西、或者与 musl 的定义重叠。全部集中在 netifd 和 ubox 两个包上，一共 4 处。

**（1）netlink 常量缺失。** `ADVERTISED_40000baseKR4/CR4/SR4/LR4_Full` 是 3.12 之后才加的链路模式位，3.0.8 的 `linux/ethtool.h` 只有到 10000baseSR。netifd 的 `device.c` 无条件引用这四个宏，编译直接报未声明。补 4 个 `#define` 即可，语义上就是给定对应 bit，不影响功能。

**（2）`IFLA_IPTUN_*` 整族缺失，导致语法错误。** 这一处比较特殊：3.0.8 根本没有 IP 隧道接口的 netlink 属性枚举，netifd 的隧道分发代码里用 `IFLA_IPTUN_MAX` 做数组边界，宏不存在时编译器看到的是一个裸露标识符，随后 `switch` 块的括号失配，报 `expected identifier or '(' before 'else'`——报错位置在语法层，看不出根因是缺宏。修法有两个方向：补一整套隧道属性枚举（工作量不小，而且 3.0.8 的隧道实现本来就不支持这些属性），或者直接让这段分发返回 `-EINVAL`。本板不用隧道，选后者；同时保留 `system_add_sit_tunnel` 的符号引用，避免 `-Werror=unused-function` 反过来报错。

**（3）`struct ethhdr` 重复定义。** 3.0.8 的 `include/linux/if_ether.h` 无条件定义该结构，musl 的 `netinet/if_ether.h` 也定义一份。netifd 同时 include 两者，报 `redefinition of 'struct ethhdr'`。3.0.8 没有 4.x 才引入的 `__UAPI_DEF_ETHHDR` 开关，处理办法是给内核头补上这个开关（默认值为 1，保持原有行为），再在 netifd 补丁开头写 `#define __UAPI_DEF_ETHHDR 0`，让内核头把结构让给 musl。

**（4）`linux/un.h` 不自包含。** 3.0.8 的 `struct sockaddr_un` 用了 `sa_family_t`，但这个类型在该头里没有定义，此前一直是靠其它头顺带引入。ubox/logd 单独 `#include <linux/un.h>` 时直接报 `unknown type name 'sa_family_t'`。改成内核自己的命名 `__kernel_sa_family_t`（新版 uapi 的写法），既自包含，又不会和 `linux/socket.h`、musl 的 `sa_family_t` 撞车。

另外 netifd 的 `CMakeLists.txt` 里写了一个面向 clang 的 `-Wno-unknown-warning-option`，gcc 7.5 遇到未知告警选项直接报错并因 `-Werror` 中止。这一项和上面四处一起放进了同一个补丁文件。

后两处（`un.h`、`if_ether.h`）改的是内核头，因此抽成 `scripts/patch_kernel_headers.sh` 独立处理，幂等，重复执行输出 `already`；它的第二个参数可以同步 `staging_dir/toolchain-*/include/linux/` 里的副本，否则用户空间看到的仍是旧头。这两处都是语义等价改名或加开关，不改变 ABI，内核自身编译不受影响。

### 4.3 内核侧的两处配置缺口

**（1）`open_port` 未定义。** `drivers/char/mem.c` 编到一半报 `'open_port' undeclared`。原因是厂商 defconfig 里 `CONFIG_DEVMEM`、`CONFIG_DEVKMEM`、`CONFIG_DEVPORT` 全关，而 `CONFIG_CRASH_DUMP=y` 会经 `open_oldmem` 走到 `open_port`，这个函数只在 `CONFIG_DEVMEM` 打开时才存在。打开 `CONFIG_DEVMEM=y` 解决，顺带得到 `/dev/mem`（flash 调试时用得上）。这两个选项是互斥的取舍，量产固件若不想要裸内存访问，改关 `CONFIG_CRASH_DUMP`。

**（2）配置片段不能直接喂给 `silentoldconfig`。** 早期版本的 `config-3.0.8` 是从厂商 `hi3520d_full_defconfig` 里摘出来的片段，缺 `GCOV_KERNEL` 等 OpenWRT 会新增的符号。非交互环境下 `make silentoldconfig` 遇到新符号要提问，立刻 `aborted! Console input/output is redirected`，随后 `No rule to make target 'include/config/auto.conf'`。现在的文件是在干净内核树里执行 `yes '' | make ARCH=arm CROSS_COMPILE=… oldconfig` 补全后的完整 `.config`，1853 行，未设置的项也以 `# CONFIG_x is not set` 全量展开。

### 4.4 改动清单的规模

16 处改动里，真正属于"移植设计"的只有 3 处（外部内核树、双编译器、jffs2 选型），其余 13 处都是环境适配。这不是巧合：老 SoC 的移植难点往往不在板级，而在两端软件栈的年代差。

---

## 5 构建与产物

### 5.1 环境

编译在 Debian 13（trixie）、x86_64、gcc 14.2、make 4.4、perl 5.40、Python 3.13 上完成。`/lib32` 必须存在，因为海思 gcc 4.4.1 是 i386 静态可执行文件。

### 5.2 构建流程

`scripts/build_owrt.sh` 把整条链走完，7 步：

1. 宿主工具层适配（`patch_host_tools.sh`：python2 shim、cmake cstdint、mkimage 桩、去 libelf、放宽 `-Werror`）；
2. 把 `target/linux/hi3520d` 装进 OpenWRT 源码树；
3. 装 netifd 补丁；
4. 修内核 uapi 头（`patch_kernel_headers.sh`）；
5. 种子 `.config` 与 defconfig；
6. `apply_config.sh` 补 `CONFIG_DEVEL` 等运行时必需项；
7. `make -j$(nproc)`。

最后调 `pack-images.sh` 完成拼装。日志按编号留在 `~/hi3520d/out/owrt_build*.log`，前文那些报错现象都是从这些日志里翻出来的。

单独验证内核可以不跑整个 OpenWRT：`scripts/k_test.sh` 用 `config-3.0.8` 在干净内核树上 `make uImage`，出问题能快很多。

### 5.3 产物

| 文件 | 大小 | MD5 |
| --- | --- | --- |
| `hi3520d_16m.bin` | 16777216 B | `23432c522bdb115ede327cc17bb9361c` |
| `hi3520d_16m_programmer.bin` | 16777216 B | `216da5217d4f6bb75679908fdb654920` |
| `boot.bin` | 226572 B | `78b651e9bcf83510350e6bc9601a9eae` |
| `boot_env_1m.bin` | 1048576 B | `4208a78827a2970b85b5a6fccb56683b` |
| `env.bin` | 262144 B | `61078564c5f04aecca91007541ec9629` |
| `kernel.bin` | 3252116 B | `c23c842e45aa7969fd0575cd9c456e25` |
| `rootfs.jffs2` | 2293764 B | `06101bbc82b52de1f08d4b3f11b181a3` |

`hi3520d_16m.bin` 是给 `sf` 命令整片写入用的，u-boot 环境区是空白；`hi3520d_16m_programmer.bin` 把环境变量焊进了 `0x80000`，适合 CH341A 一类的编程器直接写，细节见附录 D。`boot_env_1m.bin` 是含环境的 1MB boot 分区内容，`env.bin` 是可以单独写到 `0x80000` 的 0x40000 环境块。

内核 uImage 头校验：`27 05 19 56`，镜像名 `Linux-3.0.8`，ARM，load/entry 均为 `0x80008000`，与 `bootcmd` 里 `0x82000000` 加载后 `bootm` 的用法一致。rootfs 的 jffs2 魔数为 `85 19 03 20`，64K 擦除块，2.19MB 装进 11MB 分区。

根文件系统包含 33 个包：在原 31 个基础上加了 `samba36-server` 3.6.25 与 `hi3520d-smb`（本地包，只带脚本和配置）。其余为 base-files 204.4、busybox 1.30.1、dropbear 2019.78、netifd 2021-01-09、procd 2020-03-07、uci 2019-09-01、ubus 2022-02-21、ubox+logd 2019-06-16、opkg 2021-01-31、mtd、fstools、musl 1.1.24、libgcc1 7.5.0、libnl-tiny、libubox、libjson-c2、uclient-fetch、usign、urandom-seed、urngd、getrandom、jshn、jsonfilter、fwtool、openwrt-keyring 等。

### 5.4 关于打包脚本

`target/linux/hi3520d/image/Makefile` 只让构建产出 `uImage` 与 `root.jffs2-64k`，1M/4M/11M 的拼接、0xFF 填充、u-boot 环境变量文本都由 `scripts/pack-images.sh` 完成。把这两件事分开是有意的：19.07 的 image 流水线围绕 squashfs 和 sysupgrade 元数据设计，要让它在 jffs2 + 外部内核树的条件产出整片镜像，需要重写大量模板，而收益只是"能在 `bin/targets/` 里多一个文件"。脚本化之后改分区、改填充值都直接改脚本，反而清楚。

---

## 6 板级验证

### 6.1 烧写与启动

用 u-boot 的 `sf` 命令按分区写入（`boot` 0x0/0x100000、`kernel` 0x100000/0x400000、`rootfs` 0x500000/0xb00000），或直接整片写 `hi3520d_16m.bin`。上电后 u-boot 正常引导，`bootm` 解压内核、启动到 `Linux version 3.0.8`，内核识别 `hisfc350` 控制器并按 `mtdparts` 建立三个分区，挂载 `/dev/mtdblock2` 上的 jffs2 根文件系统，最后进入 OpenWRT 用户空间，串口控制台出现 shell 提示符。

### 6.2 功能检查

上电实测的结果：

| 项目 | 结果 |
| --- | --- |
| 启动与 rootfs | 正常启动，jffs2 可读写，重启后配置保留 |
| 串口控制台 | 正常，`console=ttyAMA0,115200` 生效 |
| 以太网 | `eth0` 正常出现并可通信（内置 PHY 模式，无外置 PHY） |
| USB | U 盘可识别为 `/dev/sda`，可挂载 |
| SATA | 硬盘可识别并可挂载（`CONFIG_EXT4_FS`、`CONFIG_VFAT_FS` 已开） |
| 软件管理 | `opkg`、`uci`、`ubus` 可用，procd 正常托管服务 |

### 6.3 结论

镜像在实板上功能正常。此前对 USB 枚举的担心（mach 层没有 `platform_device` 注册）在实测中没有出现——控制器驱动自行探测成功。这一条属于"代码里看不到但实际成立"，写在这里是为了避免后来者照着代码结构做出错误判断。

---

## 7 SMB 存储与双 SATA

### 7.1 需求

硬件这一侧很直接：板上底部两个 SATA 座都接到 SoC 的 SATA 控制器，要求两口都能挂盘；共享走账号密码验证，客户端可读可写；CPU 是单核 Cortex-A9、没有 NEON，SMB 的参数不能照抄 PC 上的思路。

### 7.2 内核侧不需要改

`config-3.0.8` 里 `CONFIG_HI_SATA=y`、`HI_SATA_IOBASE=0x10080000`、`IOSIZE=0x10000`、`IRQNUM=52`、`HI_SATA_PORTS=2`、`MODE=0` 本来就在。`ahci_sys.c` 用 `n_ports = CONFIG_HI_SATA_PORTS` 决定端口数，`ahci_sys_hi3520d_defconfig.c` 按这个宏逐个上电、开时钟、解复位，两个口的 `CKEN`、`TX_RST`、`RX_RST` 都是独立的。驱动由 `ahci_platform.c` 在 `module_init` 里自注册 platform_device，所以内核这边只要 `BLK_DEV_SD`、`EXT4_FS`、`VFAT_FS` 开着，两口就能出 `/dev/sdX`。这一版没有改内核。

### 7.3 用户空间：一个包加两个脚本

新增 `package/utils/hi3520d-smb`，`DEPENDS:=+samba36-server`，装 `/etc/init.d/sata-mount`、`/etc/init.d/smbuser`，以及 Samba 的 uci 配置和 `smb.conf.template`。

`sata-mount` 的 `START=40`，开机后最多等 15 秒，轮询等 `sda`、`sdb` 出现；挂载顺序是 `ext4(writeback,nobarrier)` → `ext4` → `ext3` → `ext2` → `vfat(utf8)` → `auto`，哪个能挂就用哪个，分别落到 `/mnt/sata1`、`/mnt/sata2`，挂上后 `chown 1000:1000`，配合 SMB 的 `force user` 直接可写。`stop()` 里两块盘都 `umount`。

这个脚本不做无限重试：盘到位慢就等满 15 秒，再慢只能手工 `mount`，避免开机被一块坏盘拖住。

### 7.4 账号与权限

`security = user`，`passdb backend = smbpasswd`，`map to guest = Never`，`null passwords = no`，`invalid users = root`；共享项 `read_only = no`、`guest_ok = no`，`create_mask 0664`、`dir_mask 0775`，`force user = smbuser`。默认账号 `smbuser`、口令 `hi3520d`，改 `/etc/config/samba` 里的 `smbuser`、`smbpass` 两项即可。

`smbuser` 的 `START=50`，比 samba 的 `START=60` 早一步：从 uci 读账号口令，`/etc/passwd`、`/etc/group` 里没有 uid/gid 1000 的条目就补一条，`smbpasswd` 库里没有该用户才执行 `smbpasswd -a`，最后 `chmod 600 /etc/samba/smbpasswd`。重复启动不会重复建号。

### 7.5 性能上的取舍

模板保留了 `use sendfile = yes`、`min receivefile size = 16384`、`max protocol = SMB2`，另外打开 `large readwrite`、`read raw`、`write raw` 和 `socket options = TCP_NODELAY`，把打印子系统整个关掉（`load printers = no`、`printcap name = /dev/null`、`disable spoolss`），日志压到 `log level = 0`、`max log size = 50`，`deadtime = 15`。

理由都在 CPU 上：单核 A9 没有 NEON，SMB 的瓶颈不是磁盘带宽，而是每字节的拷贝和协议往返。`sendfile` 让 3.0.8 内核做零拷贝，SMB2 减少往返次数，关打印是因为 `smbd` 启动时会探测打印机，在没有并口的板子上纯属浪费。

关于 `ext4` 的 `data=writeback,nobarrier`：换来的是写入延迟更低，代价是掉电可能丢最近几秒的数据。这个取舍适合共享盘，不适合当数据库盘。

### 7.6 打包阶段遇到的三个问题

**包编译报 "No targets specified and no makefile found"。** OpenWRT 默认的 `Build/Compile` 会进包目录执行 `make`，而这个包只有文件、没有源码。加一个空的 `define Build/Compile` 即可。

**配置被 samba36 的默认文件盖掉。** `samba36-server` 自己也装 `/etc/config/samba` 和 `/etc/samba/smb.conf.template`，opkg 的安装顺序不保证，装完 root 里留下的是 129 字节的默认 config。改成把配置放 `/etc/hi3520d-smb/`，由 `/etc/uci-defaults/90-hi3520d-smb` 在首启统一覆盖，不再依赖安装顺序。

**镜像没重打。** 包已经装进 `root-hi3520d`，但 `root.jffs2-64k` 还是旧文件。原因是重建 `.config` 时丢了 `CONFIG_TARGET_ROOTFS_JFFS2`，`install-images` 的文件系统列表为空；同时旧 `root.jffs2-64k` 还在，规则直接判定 up-to-date。补回选项、把旧产物挪开之后才真正重建，rootfs 从 1.19MB 涨到 2.19MB。

### 7.7 尚未验证的部分

两口同时插盘、SMB 的实际读写速率、`force user` 与盘上既有文件属主不一致时的表现，都还没有实测数据。目前能确认的是包进了镜像、脚本和配置在 rootfs 里。

---

## 8 讨论

### 8.1 尚未启用的能力

**netfilter 关闭。** 厂商 defconfig 里 `CONFIG_NETFILTER is not set`，因此 OpenWRT 的 `firewall`、`iptables` 都不能用，设备只能做二层交换和静态路由，不能做 NAT。要用得打开 `CONFIG_NETFILTER`、`CONFIG_NF_CONNTRACK`、`CONFIG_NF_NAT`、`CONFIG_IP_NF_IPTABLES` 一整套并重编内核，再在 `DEFAULT_PACKAGES` 里补 `iptables`。这是本移植与"可用路由器固件"之间最大的一处差距。

**squashfs 关闭。** 直接后果是没有只读根和回滚能力，rootfs 只能 jffs2，误删文件就得重烧。若要 squashfs，需要先确认 3.0.8 里哪组选项可用，再改分区方案（只读根 + overlay 需要两个分区或一个分区内的两段）。

**HiMPP 未集成。** `package/mpp.tgz`、`package/drv.tgz` 里的媒体处理与 `mmz.ko` 没有并入。要用媒体功能，需要按 SDK 方式编出 ko 放进 `/lib/modules/3.0.8/`，并在启动脚本里按 SDK 参数加载 `mmz.ko`（187MB @ `0x84000000`、JPEG 5MB @ `0x8fa00000`）。这与当前 `mem=64M` 的 bootargs 是配套的。

### 8.2 内存分配的取舍

`mem=64M` 不是保守，是为了给 MMZ 留位置。Hi3520D 板载 256MB，SDK 默认把 `0x84000000` 起的 187MB 划给媒体内存池、`0x8fa00000` 起 5MB 给 JPEG，Linux 只拿到 64MB。本移植不启动 HiMPP，这 192MB 目前是空的。如果确定不做媒体功能，把 bootargs 改成 `mem=192M` 能显著缓解 3.0.8 内核在 64MB 下的内存压力；一旦要接 HiMPP，就得改回来。

### 8.3 容量与包集

11MB 的 rootfs 分区装不下 LuCI 加一堆工具。需要更大空间可以改成 `1M + 3M + 12M`，或者裁内核（关 FB、关 USB gadget、关用不到的文件系统），把 uImage 压到 2MB 出头。包集保持最小也有原因：3.0.8 不支持现代 kmod 包的多数特性，`DEFAULT_PACKAGES` 只保留 `base-files libc libgcc busybox dropbear mtd uci opkg netifd fstools uclient-fetch logd urandom-seed urngd`；加包前得先确认它不依赖 netfilter、nftables 或 squashfs。

### 8.4 `/dev/mem` 的取舍

为解决 `open_port`，`CONFIG_DEVMEM=y` 是必要的，代价是 root 能直接读写物理内存。这是嵌入式调试的常规口子，但在量产固件里应当关掉——关 `CONFIG_CRASH_DUMP` 即可，两者留一个。

### 8.5 隧道能力被牺牲

netifd 补丁把 sit/gre/vti/vxlan 等隧道类型统一返回 `-EINVAL`。以太网、静态地址、DHCP 客户端都不受影响，但确实失去了隧道能力。要恢复，得补全 3.0.8 缺失的那批 `IFLA_*` 枚举，并确认内核侧的隧道实现能对应上——工作量不小，且本板的使用场景里用不到。

### 8.6 后续工作

按优先级排：一是打开 netfilter 并补 `iptables`，这是让设备具备基本路由能力的前提；二是评估 squashfs 可行性，解决误操作恢复问题；三是按需集成 HiMPP；四是长时间稳定性与压力测试——目前的验证覆盖了功能，但没有跑老化。

---

## 9 结论

本文把 Hi3520D 接入了 OpenWRT 19.07.10 的构建体系，路线是保留厂商内核与板级驱动、替换整个用户空间，产出 16MB 整片 SPI 镜像（MD5 `23432c522bdb115ede327cc17bb9361c`）。全部改动 16 处，其中 3 处固化为可复用补丁：netifd 的 3.0.8 兼容补丁、内核 uapi 头修正脚本、完整 `.config`。

功能扩展部分的代码量同样不大：一个只带脚本的本地包、两个 init 脚本、一份 SMB 模板，加上一个把 u-boot 环境焊进烧录器镜像的脚本。真正的成本在打包链上——包能编进去不等于镜像会重打，配置装到哪个路径也取决于 opkg 的安装顺序，这类问题只看代码是发现不了的。

从工作量分布看，移植本身的代码量很小，绝大部分精力花在两端软件栈的年代差上：宿主工具链要迁就 2019 年的构建系统，用户空间要迁就 2010 年的内核头。这类问题的共同特征是报错位置与根因不在同一层——`open_port` 未定义看起来是内核代码问题，实际是配置；`expected identifier before 'else'` 看起来是语法错误，实际是缺宏。判断依据只能是构建日志里的真实中断位置，逐处核对，而不是照着清单改。

镜像已在实板完成烧写与上电验证，启动、网络、USB、SATA 与包管理均正常。netfilter、squashfs、HiMPP 三项能力尚未启用，属已知边界。

---

## 附录 A 构建步骤

```bash
# 0) 依赖
sudo apt-get install -y build-essential gawk gettext git libncurses-dev libssl-dev \
    python3 rsync unzip zlib1g-dev wget bzip2 file patch diffutils u-boot-tools

# 1) 装海思工具链（SDK 的 osdrv/toolchain/arm-hisiv100-linux.tar.bz2）
tar xjf arm-hisiv100-linux.tar.bz2 -C /tmp/hisi
cd /tmp/hisi/arm-hisiv100-linux && sudo ./cross.install force   # → /opt/hisi-linux-nptl/arm-hisiv100-linux

# 2) 解仓库里的内核源码，并打 timeconst.pl 补丁
mkdir -p ~/hi3520d/kernel-3.0.8
tar xzf sdk/linux-3.0.y.tgz -C ~/hi3520d/kernel-3.0.8 --strip-components=1
sed -i 's/if (!defined(@val)) {/if (!@val) {/' ~/hi3520d/kernel-3.0.8/kernel/timeconst.pl

# 3) 拉 OpenWRT
git clone --depth 1 -b v19.07.10 https://github.com/openwrt/openwrt.git ~/hi3520d/openwrt

# 4) 一键构建 + 打包
bash scripts/build_owrt.sh
```

u-boot 一般不用重编（Release 里的 `boot.bin` 就是 SDK 原版）。要自己编：

```bash
mkdir -p ~/hi3520d/uboot && tar xzf sdk/u-boot-2010.06.tgz -C ~/hi3520d/uboot --strip-components=1
cd ~/hi3520d/uboot
make ARCH=arm CROSS_COMPILE=/opt/hisi-linux-nptl/arm-hisiv100-linux/target/bin/arm-hisiv100nptl-linux- hi3520d_config
make ARCH=arm CROSS_COMPILE=/opt/hisi-linux-nptl/arm-hisiv100-linux/target/bin/arm-hisiv100nptl-linux-
# u-boot.bin 还需经 SDK 的 osdrv/Makefile 包装成 u-boot_hi3520d.bin 才能烧
```

## 附录 B 常见故障排查

| 现象 | 排查方向 |
| --- | --- |
| `Can't use 'defined(@array)' ... timeconst.pl` | 没打 timeconst.pl 补丁（4.1 表第 5 项） |
| `make uImage` 找不到 `mkimage` | 宿主未装 `u-boot-tools`，或桩 Makefile 未生效 |
| 内核编译报 host 工具隐式声明 | `KERNEL_MAKE_FLAGS` 里的 `-Wno-error=implicit-function-declaration` 丢失 |
| `'open_port' undeclared` | `CONFIG_DEVMEM` 未开（4.3 节） |
| `Console input/output is redirected` / 无 `auto.conf` | `config-3.0.8` 是片段而非完整 `.config`（4.3 节） |
| `redefinition of 'struct ethhdr'` | `if_ether.h` 缺 `__UAPI_DEF_ETHHDR` 开关（4.2 节） |
| `'ADVERTISED_40000baseKR4_Full' undeclared` 或 `expected identifier ... 'else'` | netifd 补丁未装，检查 `patches/200-kernel-3.0.8-compat.patch` |
| `unrecognized command line option '-Wno-unknown-warning-option'` | netifd `CMakeLists.txt` 的 clang 选项，补丁里已删 |
| `unknown type name 'sa_family_t'` | `include/linux/un.h` 未修正（4.2 节） |
| 补丁 dry-run 通过但编译仍报错 | `build_dir/target-*/netifd-*` 是旧源码，删掉重新解包 |
| 卡在 `Uncompressing Linux...` 无输出 | `console=` 丢失，或 uImage 加载地址与 `bootcmd` 不一致 |
| `VFS: Cannot open root device "mtdblock2"` | `mtdparts=` 未传或分区顺序不对；确认 `MTD_CMDLINE_PARTS`、`MTD_BLOCK` |
| rootfs 挂载后 panic / 校验错 | 镜像非 64K 擦除块，或分区大小与镜像不匹配 |
| `eth0` 不出现 | `CONFIG_HIETH_INNER_PHY=y` 是否生效，`dmesg | grep -i hieth` |
| 无 `/dev/sda` | `CONFIG_USB_STORAGE`、`CONFIG_BLK_DEV_SD`，`dmesg | grep -i usb` |
| SATA 盘不识别 | `CONFIG_HI_SATA`、`CONFIG_SATA_AHCI_PLATFORM`，`dmesg | grep -i -E 'ahci|ata'` |

## 附录 C 代码来源与版权

- `target/`、`scripts/`、`overlay/` 与本文件：针对本板子的适配代码，可自由使用。
- `sdk/linux-3.0.y.tgz`、`sdk/u-boot-2010.06.tgz`：取自海思 `Hi3520D_SDK_V1.0.2.2` 原始压缩包，未做改动，版权归海思（HiSilicon）所有，遵循其 SDK 许可；公开再分发前请自行确认授权范围。
- 工具链 `arm-hisiv100-linux.tar.bz2` 未入库（海思 gcc 4.4.1，i386 静态 ELF），需从原 SDK 获取。
- OpenWRT 源码不入库，按附录 A 拉取 `v19.07.10`。

## 附录 D 烧录器整片镜像

`hi3520d_16m.bin` 里的 u-boot 环境区是空白的（0xFF）。用 `sf` 命令写入时这不是问题，前面已经 `saveenv` 过；但拿编程器直接写整片，u-boot 读到无效 CRC 就会退回编译进固件的默认环境，没有 `bootcmd`，上电不会自动引导。

环境在 SPI 上的位置来自 `include/configs/hi3520d.h`：

```c
#define CONFIG_ENV_IS_IN_SPI_FLASH 1
#define CONFIG_ENV_OFFSET          0x80000   /* environment starts here */
#define CONFIG_ENV_SIZE            0x40000   /* include ENV_HEADER_SIZE */
```

即偏移 `0x80000`、长度 `0x40000`，结构是 4 字节 CRC32 加 `key=value\0` 串。这段落在 1MB boot 分区内，u-boot 二进制（226572 字节）之后，两者不重叠。

`scripts/make_programmer_image.py` 按这个格式生成环境块并拼出整片镜像：

```bash
python3 make_programmer_image.py boot.bin kernel.bin rootfs.jffs2 out/
```

产出 `hi3520d_16m_programmer.bin`、`boot_env_1m.bin`、`env.bin`。写进去的变量是 `bootcmd`、`bootargs`、`mtdparts`、`bootdelay=2`、`baudrate=115200`、`ipaddr=192.168.1.200`、`serverip=192.168.1.100`、`gatewayip`、`netmask`、`bootfile`。

验证过的是三件事：环境块 CRC 字段与重算值一致；`0x100000` 处字节与 `kernel.bin` 完全相同、`0x500000` 处与 `rootfs.jffs2` 完全相同；环境区之外到 boot 分区末尾、以及 `0xC0000`–`0x100000` 都是 0xFF。

编程器写 16MB 的 SPI NOR（W25Q128、MX25L12845E 这类）时选整片镜像即可。旧板那颗 `MX25L6406E` 只有 8MB，装不下这个镜像。写完建议先读回比对前 1MB，u-boot 区没有备份机制，写坏了只能再拆一次芯片。

## 参考文献

1. HiSilicon. Hi3520D SDK 安装以及升级使用说明. `Hi3520D_SDK_V1.0.2.2` 发行包内 `01.software/board/documents_cn/`（n.d.）.
2. OpenWRT Project. OpenWrt 19.07 documentation / source tree, tag `v19.07.10`. https://github.com/openwrt/openwrt（2020）.
3. The Linux Kernel Organization. Linux kernel 3.0.8 source, `arch/arm/mach-hi3520d`, `drivers/net/hieth-sf`, `drivers/mtd/devices/hisfc350`（2011）.
4. musl libc project. musl 1.1.24, `include/netinet/if_ether.h`, `include/sys/un.h`. https://musl.libc.org（2018）.
5. Rich Felker et al. musl libc 与 glibc 在 uapi 头兼容性上的差异说明（见 musl FAQ 与 `include/` 目录注释）.
