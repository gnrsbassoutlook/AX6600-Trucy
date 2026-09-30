# OpenList 助手（luci-app-openlist-assist v1.2.0）—— 界面与联动说明

> 主机 `192.168.1.1` / 副机 `192.168.3.1`（AX6600 · bleachwrt · 内核 6.12.93）· 2026-09-30
>
> 入口：**LuCI → 服务 → OpenList 助手**（排在「ADH设备过滤助手」后面）

---

## 一、这一版改了什么（v1.0.0 → v1.2.0）

| 改动 | 说明 |
|---|---|
| **一块盘 = 一个开关** | 不再把所有按钮平铺一屏。每行只露一个开关：没挂 → 点一下挂；挂了 → 点一下卸 |
| **次要功能收进「⋯」** | 强力挂载 / 强力卸载 / 检查健康 / 清除脏标记 / 格式化，默认折叠 |
| **「全部挂载/卸载」挪进批量面板** | 并且含义写死为「**勾选的那些盘**」，可以逐块勾 |
| **刷新同时更新 OpenList 存储** | 页面顶部状态条里直接显示「OpenList 存储 N 个 / 存储离线 N」 |
| **与 OpenList 存储联动** | 盘上显示它被哪个存储引用；卸这种盘时自动先停 OpenList、卸完自动拉起 |
| **新增「内置存储」面板** | 把 109 GiB 的内置 eMMC 空分区也管起来（默认未挂载，点开关即挂） |
| **eject 加 USB 闸门** | 补掉一个真能变砖的漏洞，见 §7 |
| **工具适配 OpenWrt 真实包名** | 见 §6 |
| **v1.1.1：修 `diskctl list` 的树形归属** | 老版"见到分区就往上一行底下缩进"，会把 `mmcblk0p27` 画到 `/dev/sda` 底下，看着像 4T 盘的分区。现在**真的按 `parent` 配对**，父盘不在清单里的分区单独列一段 |
| **v1.1.2：跟着 OpenList 存储改名同步** | 存储 `/我的4T硬盘` 改成了 `/THW-4T`（在 OpenList 面板里改的）。代码里的注释样例、本说明与 `OpenList-4T硬盘挂载-操作说明.md` 一起对齐。**无功能改动** —— 联动是按 `root`（`/mnt/sda2`）认盘的，改名不影响 |
| **v1.1.3：状态条区分「整盘」和「分区」** | 老版把两者混在一起数，插一个 4 盘位硬盘柜会显示成「**USB 盘 8**」，看着像插了 8 块盘。现在拆成「**N 块 · M 分区**」，见 §11 |
| **v1.2.0：存储能一键「改指向」/「新建」** | 换盘、换 USB 口、盘符从 `sda` 变 `sdb`，旧指向就失效（网页上那个目录变成打不开的「根路径未挂载」）。现在存储表**每行一个「改指向…」**、面板头一个**「新建存储」**，弹出的是**当前真实存在的盘**列表（内置 eMMC 也在里面）。见 §4.4 |

---

## 二、界面结构（从上到下）

```
┌ 状态条 ── USB盘 / 已挂载 / OpenList / OpenList存储 / 内置存储 / NTFS / exFAT ┐
├ USB 硬盘 ──────────────────────────────────────────────── [刷新] ─┤
│   /dev/sda  3.6T  ATA ST4000VX005-2LY1            [安全弹出]      │
│     sda1  [无文件系统][挂不了]                          (开关禁用) │
│     sda2  [ntfs][已挂载][OpenList · /THW-4T]                   │
│           已用 2.5T / 3.6T（69%）    已挂载 ●──  [⋯]              │
├ 内置存储 ────────────────────────────────────────────────────────┤
│   /dev/mmcblk0  111.5G                                            │
│     mmcblk0p27  [ext4][未挂载][内置]    未挂载 ○──  [⋯]           │
├ 批量操作（默认折叠）───────────────────────────────────────────┤
├ OpenList ── 存储表：挂载路径 / 类型 / 实际根路径 / 在线状态 ─────┤
├ 工具自检 ── [检查] [一键安装] ───────────────────────────────────┤
└ 执行结果 ── 所有操作的原样输出 ──────────────────────────────────┘
```

**开关的语义**（这是这版的核心）：

- **灰色 = 未挂载**，点一下 → 挂载
- **绿色 = 已挂载**，点一下 → 卸载
- **开关禁用（半透明）= 这个分区没有文件系统**（比如 Windows 保留分区 `sda1`），
  本来就挂不上，不给点

挂载失败不弹窗，失败原因（比如「盘脏了」）会原样打在下面「执行结果」里，
并且提示你去「⋯」里用**强力挂载**。

---

## 三、批量操作

默认折叠，点标题展开。里面：

- **范围写得明明白白**：`下面勾选的那些盘（只含 USB 硬盘，不含内置存储）`
- 每块可挂载的 USB 分区一个复选框，**默认全勾**（新插的盘自动勾上，拔掉的自动取消）
- 一个「强制模式」选项：
  - 挂载时遇到带脏标记的盘**自动加 force**
  - 卸载时卸不掉**自动转 lazy**，并临时停 OpenList（卸完自动拉起）
- 按钮：`挂载选中` / `卸载选中` / `全选` / `全不选`

实现上「批量」是把勾选的盘**逐个**发请求，所以每块盘都会在结果区留下自己那一段输出，
最后再打一条汇总（成功 N 块 / 失败 N 块 + 失败名单），比一个笼统的「全部完成」有用得多。

---

## 四、和 OpenList 的联动（重点）

### 4.1 先说清楚一件事

**OpenList 的「存储」不挂载任何东西 —— 它只是指向一个本地路径。**

所以关系是单向的：

```
你挂上 /mnt/sda2  →  OpenList 存储「/THW-4T」能用（状态：在线）
你卸载 /mnt/sda2  →  那个存储立刻变成「根路径未挂载」，OpenList 网页上那里报错
```

「挂载」是操作系统层面的事，「存储」只是 OpenList 配置里的一个路径。
两者不是同一套机制，所以**必须有联动才不会互相踩**。

### 4.2 本页做的三件事

1. **看得见**：盘那一行直接挂徽章 `OpenList · /THW-4T`；
   顶部状态条会有 `OpenList 存储 N 个`，存储根路径没挂上时额外亮一个红 chip `存储离线 N`。
2. **卸得掉**：如果这块盘正被某个 OpenList 存储引用，那个开关**自动带上 `stop`** ——
   点下去会先 `killall openlist`，卸载成功后再自动把 OpenList 拉起来。
   （不然一定 `device busy`：OpenList 正占着盘上的文件。）
   页面上会写明「会先临时停 OpenList，卸完自动拉起」。
3. **看得到底**：下面 OpenList 面板里列出全部存储的
   `挂载路径 / 驱动 / 实际根路径 / 在线状态`，离线的直接标红。

### 4.3 ⭐ 怎么读到 OpenList 的存储列表的（不需要口令）

**关键技巧**：OpenList 把一枚**长期有效的 API token** 明文存在数据库里。

```sh
# OpenList 的数据在 /root/openlist_run/data/
#   config.json —— 配置（含 jwt_secret）
#   data.db     —— SQLite，存储 / 用户 / 设置都在里面
#
# 设置表 x_setting_items 里有一项 key=token，值形如：
#   openlist-<uuid>-....<64 位 base64>...
#   ★ 这是**等同管理员**的凭据，别贴到任何地方（含本仓库、聊天、截图）
# 它能直接当 Authorization 头用，权限等同管理员。
strings -n 2 /root/openlist_run/data/data.db \
  | grep -o 'tokenopenlist-[^ ]*string' | head -1 \
  | sed 's/^token//; s/string$//'
```

于是：**不用存 OpenList 管理员口令，不用装 sqlite3，不用改 OpenList 任何配置**。

> 走过弯路记录一下：试过用 `config.json` 里的 `jwt_secret` 自己签一个 HS256 的 JWT，
> 结果被拒 `token is invalidated` —— 因为 OpenList 校验时还会比对 token 里内嵌的
> 口令哈希，光有密钥签不出来。

`diskctl olstorages` 就是这条链路的封装，可以单独跑：

```sh
diskctl olstorages | jq .
# {"ok":true,"err":"","storage":[{"id":1,"mount_path":"/THW-4T",
#   "driver":"Local","status":"work","disabled":false,"root":"/mnt/sda2"}]}
```

读不到时（OpenList 没跑 / 没有 token 项）会返回 `{"ok":false,"err":"..."}`，
界面照常渲染，只是 OpenList 板块显示一条黄色提示 —— **不影响挂载卸载**。

### 4.4 ⭐ v1.2.0：换盘了怎么办 —— 「改指向…」

**问题**：OpenList 的存储配置里存的是**一条路径**（比如 `/mnt/sda2`），
既不是设备名也不是 UUID。而这台机器上 USB 盘的挂载点是 `/mnt/<分区名>`，
分区名又随**插的顺序和 USB 口**变：

```
单分区 U 盘 → /dev/sda1 → /mnt/sda1
4T 硬盘（有保留分区）→ /dev/sda2 → /mnt/sda2
换个 USB 口 → 盘符变 sdb → /mnt/sdb1 ← 旧指向立刻失效
```

一旦路径对不上，OpenList 网页上那个目录就打不开，本页会亮红字
「**根路径未挂载**」。以前只能自己去 OpenList 网页上改路径。

**现在**：存储表每行右边多了 **「改指向…」**（*路径没挂上时它自动变成醒目的主按钮，
一眼就知道该点哪儿*），面板头多了 **「新建存储」**。点开弹出选择器，列出：

| 列 | 内容 |
|---|---|
| 设备名 | `sda1` / `mmcblk0p27` … |
| 挂载点 | `/mnt/sda1` … |
| 文件系统 / 容量 | `exfat` · `1.8G` … |
| 标签 | 内置 eMMC 会标「**内置 eMMC**」 |

**没挂载的盘置灰**并提示"先把它挂上"—— 因为改指向要读当前挂载点，
盘都没挂就无从谈起。**内置 eMMC 也在列表里**（挂到 `/mnt/emmc`）。

#### 为什么不是「分区号 1~9 下拉」

| 情况 | 固定 1~9 会怎样 |
|---|---|
| 扩展分区盘（`sda1` + `sda5`） | 2 / 3 / 4 是空的 |
| 换 USB 口 → `sda` 变 `sdb` | 选单里**没有 "b"** |
| 小 U 盘无分区表，设备名就是 `sda` | 没有数字可选 |

所以改成**动态列出当前真实存在的盘** —— 插什么就出现什么，三种情况全覆盖。

#### 命令行等价

```sh
diskctl olmap <存储id> <设备名>     # 改指向：把存储 <id> 的根路径改成该盘现在的挂载点
diskctl olnew <存储名> <设备名>     # 新建存储，例如 diskctl olnew /TWS-SD sda1
```

> **实测（两台）**：改指向 `sda2 → sda1 → sda2` 往返成功、路径逐次复核生效；
> 指向**未挂载**的盘被拒；非法 id / 不含 `/` 的存储名 / 重名新建均被拒。
> 主机上验证时 `/THW-4T → /mnt/sda2` 全程未动。

⚠️ **改名后 WebDAV 地址会跟着变**：`/dav/THW-4T/` → `/dav/新名字/`，
手机上的 owlfiles / CX 文件管理器要同步改地址，否则 404。

---

## 五、内置存储（那块 128G 的 eMMC）

### 5.1 它到底是什么

```
mmcblk0  mmc0:0001 SLD128   115 GiB   ← 整颗 eMMC（标称 128GB）
  p18   2 GiB   squashfs               ← rootfs（挂 /rom）
  p18内 offset 99M 起 1.8G ext4        ← overlay（loop0，挂 /）
  p22   20 MiB  rootfs_data            ← 出厂数据区
  p26   512 MiB swap
  p27  111.5 GiB ext4  PARTLABEL=primary  ← ★ 全空，出厂没人用
```

**`/dev/mmcblk0p27` = 109.2 GiB 的 ext4，里面只有一个 `lost+found`，完全是空的。**

### 5.2 怎么用

界面上它出现在「内置存储」面板，和 USB 盘一样的开关：

- 点开关 → 挂到 **`/mnt/emmc`**（ext4 用默认参数，不需要任何额外驱动）
- 再点 → 卸载

**实测性能**（主机 192.168.1.1，512MB 顺序读写，其中"冷读"前有 `drop_caches`）：

| 目标 | 顺序写 | 冷读 |
|---|---|---|
| 内置 eMMC（ext4） | **118.5 MB/s** | **160.5 MB/s** |
| 4T 机械盘（NTFS） | 94.8 MB/s | 47.6 MB/s |

也就是说这块 eMMC **比那块 4T 机械盘还快**（尤其读快 3 倍），拿来当临时中转区很合适：
解压临时目录、待整理的文件、临时下载缓存。ext4 也不会有 NTFS 的脏标记问题。

⚠️ **eMMC 有写入寿命，别拿它当 7×24 的下载盘或长期热数据盘。**

### 5.2.1 ⚠️ 挂上 ≠ 出现在 OpenList / WebDAV

**这是最容易误会的一点**：你在助手页点开关把 eMMC 挂上，只是让它在
**路由器本机**多了一个 `/mnt/emmc` 目录。**OpenList 和 WebDAV 完全不知道它的存在。**

原因是 OpenList 的 WebDAV 暴露的是**它自己的虚拟根目录**，而虚拟根下面挂什么，
取决于你在 OpenList 里配了几个「存储」。实测主机上 `PROPFIND /dav/` 只返回一项：

```
/dav/
/dav/THW-4T/      ← 只有这一个，因为它只有 1 个存储
```

所以想让 eMMC 也能通过 WebDAV 访问，必须**再给 OpenList 加一个存储指过去**：

| 字段 | 填什么 |
|---|---|
| 驱动 | `Local` |
| 挂载路径 | `/eMMC`（这是你在 WebDAV 里看到的目录名，随便起） |
| 根文件夹路径 | `/mnt/emmc` |
| WebDAV 策略 | `native_proxy`（和现有存储保持一致） |

加完之后 `PROPFIND /dav/` 里就会多出 `/dav/eMMC/`，
和 `/dav/THW-4T/` 是同级的两个目录。

**两步缺一不可**：先挂上（`/mnt/emmc` 得存在），再加存储。
顺序反了的话，OpenList 里那个存储会一直报「根路径未挂载」。

### 5.3 要开机自动挂上

`/etc/config/fstab` 里其实早就有一条（block detect 生成的），只是禁用了：

```sh
# 注意 target 默认写的是 /mnt/mmcblk0p27，和助手页用的 /mnt/emmc 不是一个地方，
# 要一起改，否则开机挂在上面的路径、助手页却认 /mnt/emmc，会显示成"未挂载"。
uci set fstab.@mount[2].target='/mnt/emmc'
uci set fstab.@mount[2].enabled=1
uci commit fstab
```

（`@mount[2]` 就是 UUID `ec444341-4596-4d00-b0c9-36ca8ca223e4` 那条。）

默认**没有**帮你打开，因为这是主机的中枢配置，留给你决定。
不打开的话，每次重启后要到助手页点一下开关才会挂上 —— 对"临时中转区"这个定位来说反而更省 eMMC 寿命。

### 5.4 ⛔ 安全边界（重要）

白名单是**精确到分区**的，写在 `/etc/config/openlist-assist`：

```
option internal_devs 'mmcblk0p27'
option internal_mount '/mnt/emmc'
```

**绝不能**往里加 `mmcblk0` / `mmcblk0p18` / `mmcblk0p22` / `mmcblk0p26` ——
它们分别是整颗 eMMC、rootfs、rootfs_data、swap，动一个就变砖。

另外两处硬保护（实测已验证）：

| 操作 | 对内置盘的结果 |
|---|---|
| `diskctl eject mmcblk0p27` | ❌ 拒绝 —— 「不是 USB 设备，不能弹出（保护内置存储）」 |
| `diskctl format mmcblk0p27 ...` | ❌ 拒绝 —— 「不是 USB 设备，拒绝操作（保护系统盘）」 |
| `diskctl mount mmcblk0p18` | ❌ 拒绝 —— 「不在可操作范围内」 |
| 界面上的格式化按钮 | 内置盘那行**根本不渲染**格式化按钮 |

---

## 六、支持的格式 / 工具矩阵

### 6.1 挂载：全都不需要装包

| 格式 | 驱动 | 状态 |
|---|---|---|
| NTFS | `ntfs3` | ✅ 内核内置 |
| exFAT | `exfat` | ✅ 内核内置 |
| FAT32 / FAT16 | `vfat` | ✅ 内核内置 |
| ext4 | `ext4` | ✅ 内核内置 |

挂载参数按类型自动分支：

| 类型 | `-t` | 选项 |
|---|---|---|
| blkid 报 `ntfs` | `ntfs3` | `iocharset=utf8` |
| `exfat` | `exfat` | `iocharset=utf8,umask=000` |
| `vfat`/`fat`/`msdos` | `vfat` | `iocharset=utf8,utf8=1,umask=000` |
| `ext4` | `ext4` | 默认 |

### 6.2 格式化 / 检查：要装用户态工具，**包名和 OpenWrt 有出入**

界面「工具自检 → 一键安装」跑的是（实测在 24.10.8 官方源上可用）：

```sh
opkg update
opkg install exfat-mkfs exfat-fsck dosfstools e2fsprogs
```

🔴 **两个必须记住的坑**：

1. **官方源里没有 `exfatprogs` 这个总包**。搜出来的是拆开的
   **`exfat-mkfs`**（提供 `mkfs.exfat`）和 **`exfat-fsck`**（提供 `fsck.exfat`）。
   写 `opkg install exfatprogs` 只会得到 `Unknown package 'exfatprogs'`。
2. **`dosfstools` 装出来的命令叫 `mkfs.fat` / `fsck.fat`，不叫 `mkfs.vfat` / `fsck.vfat`。**
   所以 `diskctl` 里专门有个 `which_fat()` 两种名字都认，
   否则界面上会一直显示「mkfs.fat ❌ 缺失」而其实已经装好了。

### 6.3 什么都做不了的

**NTFS 格式化**：缺 `mkntfs`。它属于 `ntfs-3g` 包，而 `ntfs-3g` 是 FUSE 实现，
本固件**没有 fuse 模块** → 装不上。要 NTFS 请在 Windows 上格式化。
（NTFS 的**挂载与读写**完全没问题，因为走的是内核 ntfs3。）

### 6.4 实测结论（loop 回环镜像，三种格式跑通全链路）

| 格式 | 格式化 | 挂载 | 真实读写 | 卸载 |
|---|---|---|---|---|
| ext4 | ✅ `mke2fs` | ✅ `/mnt/loop1` | ✅ | ✅ |
| exFAT | ✅ `mkfs.exfat` | ✅ 62.0M | ✅ | ✅ |
| FAT32 | ✅ `mkfs.fat -F 32` | ✅ 63.0M | ✅ | ✅ |

---

## 七、安全边界（这块盘/这套系统上**绝不**发生的事）

| 保护 | 怎么做的 |
|---|---|
| 不碰系统盘 | 只处理 USB 盘 + 内置白名单分区；`mmcblk0p18/p22/p26` 一律拒绝 |
| 不卸系统挂载点 | 非管辖设备且挂载点不在 `/mnt/*` 下 → 拒绝卸载 |
| 弹出只对 USB | `eject` 前先验 `is_usb`。**少了这道闸门，`eject mmcblk0p27` 会顺着 parent 摸到 `mmcblk0`，往 `/sys/block/mmcblk0/device/delete` 写 1 —— 等于把系统盘拔了。** |
| 格式化三重闸门 | ① 必须是分区 ② 必须是 USB ③ 必须未挂载 ④ 界面上要你**手打一遍设备名**才执行 |
| 不写分区表 | 本插件**不碰分区表、不写 fstab**（分区/建表交给 `diskman`，各管一摊） |
| 无命令注入 | Lua 侧参数白名单 `^[a-z0-9]+$` + 单引号包裹；`x; rm -rf /` 这类进不来 |
| 不搞坏 OpenList | 卸载时临时停 OpenList，**无论成功失败都会自动拉起**（实测 15152 → 19629） |

---

## 八、命令行等价操作（SSH 里也能干同样的事）

```sh
diskctl list                  # 列盘（整盘带它自己的分区；父盘未放行的分区单独一段）
diskctl json                  # 同上，JSON（界面用）
diskctl mount   sda2          # 挂载        [--force] [--ro]
diskctl umount  sda2          # 卸载        [--force] [--stop]
diskctl clean   sda2          # 清 NTFS 脏标记（挂载法）
diskctl dirty   sda2          # 只读检查是否有脏标记
diskctl eject   sda          # 安全弹出（仅 USB）
diskctl format  sda2 exfat    # 格式化      --yes（exfat | vfat | ext4）
diskctl openlist start|stop   # 启停 OpenList
diskctl olstorages            # OpenList 存储列表（JSON）
diskctl tools [--install]     # 工具自检 / 一键安装
diskctl log 60                # 看最近 60 条操作日志（/tmp/diskctl.log）

# 内置存储
diskctl mount  mmcblk0p27     # → /mnt/emmc
diskctl umount mmcblk0p27
```

`diskctl list` 在主机（USB 4T + 内置白名单分区）上的实际输出：

```
------------------------------------------------------------
【硬盘】可操作的盘（USB 硬盘 + 内置白名单）
------------------------------------------------------------
▌/dev/sda   整盘 3.6T   ATA      ST4000VX005-2LY1
   └ sda1   16.0M   ?   ⛔ 无文件系统（挂不了，属正常）
   └ sda2   3.6T   ntfs   ✅ 已挂载 → /mnt/sda2
------------------------------------------------------------
【内置分区】所属整盘不在清单内，单独列出
------------------------------------------------------------
▌/dev/mmcblk0p27   111.5G   ext4   ⭕ 未挂载   （属 /dev/mmcblk0）
------------------------------------------------------------
```

> 小字说明为什么要有第二段：内置白名单**只放行 `mmcblk0p27`**（`mmcblk0` 本身
> 不能放行，那是整颗 eMMC），所以它的"父盘"永远不会出现在第一段里。
> 与其硬塞到别的盘底下，不如明确单列并标出真实归属。

---

## 九、部署与回滚

### 部署（文件已就位，这里记的是方法）

```sh
# 打包（本地）
cd luci-app-openlist-assist/root && tar czf /tmp/oa.tgz .
# 路由器上
wget -O /tmp/oa.tgz http://<你的电脑IP>:8898/openlist-assist.tgz
md5sum /tmp/oa.tgz                       # 与本地 md5 -q 对齐
tar xzf /tmp/oa.tgz -C /
chmod 755 /usr/bin/diskctl
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
/etc/init.d/uhttpd restart
```

> ⭐ **推包小技巧**：不用 base64 分块传（容易出错、超过 4KB 还会被 dropbear 掐断）。
> 在 Mac 上 `python3 -m http.server 8898 --bind <本机网卡IP>`，
> 让路由器 `wget` 拉 —— 一行搞定，还能 `md5sum` 核对。
> 注意主机在 `192.168.1.x`、副机在 `192.168.3.x`，**得绑对网卡**。

### 回滚

```
/root/oadbak/v113/diskctl              # v1.1.3 的（改指向前最后一版）★ 首选
/root/oadbak/v113/main.htm
/root/oadbak/v113/openlist_assist.lua
/root/oadbak/diskctl.old               # v1.0.0 的
/root/oadbak/diskctl.pre-listfix.old   # v1.1.0 的（树形归属修复前）
/root/oadbak/openlist_assist.lua.old
/root/oadbak/main.htm.old
/root/oadbak/openlist-assist.old
```

```sh
# 回到 v1.1.3
cp /root/oadbak/v113/diskctl /usr/bin/diskctl
cp /root/oadbak/v113/openlist_assist.lua /usr/lib/lua/luci/controller/openlist_assist.lua
cp /root/oadbak/v113/main.htm /usr/lib/lua/luci/view/openlist_assist/main.htm
chmod 755 /usr/bin/diskctl
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache && /etc/init.d/uhttpd restart
```

> ⚠️ **踩过的坑：备份会被自己的部署脚本覆盖。**
> 推送命令时 SSH 端**偶发把整条命令重复执行一遍**，于是「备份 → 解包」这套跑了两次，
> 第二遍备份下来的其实是**刚铺好的新版** —— `/root/oadbak/v113/` 就成了空壳。
> **现象**：`md5sum /root/oadbak/v113/diskctl` 与 `/usr/bin/diskctl` **完全相同**。
> **对策**：部署后**必须比对"备份 vs 当前"的 md5**，两者不同才算备份成功。
> 发现相同，就从 `dist/` 里的旧 ipk 重新提取（**注意 ipk 是三层嵌套**：
> gzip → tar → 里面的 `data.tar.gz` 才是文件树，Mac 上 `ar` 解不了）。
>
> v1.1.3 的真实 md5（用来核对备份是不是真旧版）：
>
> ```
> aa5924909dfd0e0c2447ecfa3b28d54f  diskctl
> 464fc7d6afd40c55c3753615fa36c42f  main.htm
> 69bdeaefd606bb92aae2a807b4308f57  openlist_assist.lua
> ```

`uninstall.sh` 只删界面 5 个文件，**绝不动** `mount-data-disk.sh` /
`99-mount-data-disk` / `rc.local` / `fstab` / OpenList 配置 / 盘上数据。

### 版本号

改版本要**同时改两处**：`Makefile` 的 `PKG_VERSION` 与 `build-ipk.py` 的 `PKG_VERSION`。

---

## 十、已知限制 / 下一步

1. **OpenList 存储的「改名 / 删除」本页不做** —— 那是 OpenList 面板的职责。
   本页只做两件写操作：**改指向**（§4.4）与**新建存储**。改名 / 删除仍去 OpenList 网页
   （改名实测可行：一次性存储 `/RENAME-TEST` → `/RENAMED-OK` 成功、指向未丢；
   注意改名后 WebDAV 路径跟着变）。
2. **批量操作用逐个请求实现**，盘特别多时是 N 次请求。目前 ≤ 几块，够用。
3. **eject 依赖桥接芯片支持软弹出**。Norelsys NS1066 支持；
   不支持的芯片会退化成「刷完缓存，直接拔是安全的」提示。
4. **`sda1`（16MB Microsoft 保留分区）** 界面上会显示「挂不了」，这是正常的，别去动它。
5. 可选：`opkg remove mount-utils` 彻底修好 `mount`/`umount`；
   可选：给 OpenList 建 `/etc/init.d/openlist` 服务脚本（免 `killall`）。

---

## 十一、插硬盘柜 / 多块盘 / RAID 会怎样

> 这一节是实测得出的（前端用真 JS 离线渲染 + CLI 用合成数据跑，见 §十二 的验证手法），
> 不是推测。

### 11.1 多盘位 USB 硬盘柜 → 每块盘一个独立的 `/dev/sdX`

Linux 的 USB 存储驱动**不看柜子**，它只看到柜子后面挂着几个 SATA 盘，
每个盘给一个独立的盘符。所以 4 盘位的柜子插上来是：

```
sda      ← 主机上原本那块 4T 盘（已经占了 sda）
sdb      ← 柜子第 1 块盘
sdc      ← 柜子第 2 块盘
sdd      ← 柜子第 3 块盘
```

⚠️ **不是 `sda3`、`sda4`** —— 那个数字是「**同一块盘上的第几个分区**」，
不是「第几块盘」。盘符用**字母**区分，分区用**数字**区分：

| 写法 | 含义 |
|---|---|
| `sdb` | 第 2 块硬盘（整盘） |
| `sdb1` | 第 2 块硬盘上的第 1 个分区 |
| `sda2` | 第 1 块硬盘上的第 2 个分区（就是现在那块 4T 的数据区） |

⚠️ 还有个反直觉的地方：**盘符顺序不保证和柜子里的槽位顺序一致**，
甚至重启后会变（取决于内核探测到哪块盘先就绪）。所以**别用 `sda`/`sdb` 记盘**，
要用 **UUID** 或卷标认盘 —— 助手页和 `fstab` 都是这么做的。

助手页上会怎么显示（实测渲染输出）：

```
▌/dev/sda   整盘 3.6T   ATA ST4000VX005-2LY1        ← 每块盘一张卡
   └ sda1   16.0M   ?      ⛔ 无文件系统
   └ sda2   3.6T   ntfs   ✅ 已挂载 → /mnt/sda2
▌/dev/sdb   整盘 1.8T   ATA WDC WD20EFRX-68E
   └ sdb1   1.8T   ext4   ⭕ 未挂载
▌/dev/sdc   整盘 931.5G ATA ST1000DM003-1CH1
   └ sdc1   931.5G  ntfs   ✅ 已挂载 → /mnt/sdc1
▌/dev/sdd   整盘 7.3T   exfat              ← 整盘直接带文件系统（无分区表）
   └ sdd    7.3T   exfat   ✅ 已挂载 → /mnt/sdd
```

顶部状态条会写「**USB 硬盘 4 块 · 3 分区**」，批量操作面板会把
`sda2 / sdb1 / sdc1 / sdd` 四行都列出来、默认全勾。

> v1.1.3 之前这里会显示成「USB 盘 8」（整盘+分区一起数），看着像插了 8 块盘。
> 这是本次修掉的问题。

**挂载点**：USB 盘用 `/mnt/<设备名>`，所以是 `/mnt/sdb1`、`/mnt/sdc1`……
内置盘固定用 `/mnt/emmc`。

### 11.2 硬件 RAID 柜（RAID0 / 1 / 5）→ 系统只看见「一个逻辑盘」

硬件 RAID 是在**柜子的固件里**做的。柜子把 N 块物理盘合成 1 个逻辑卷，
只把这一个卷暴露给 USB。所以路由器上：

```
sda      ← 主机原本那块 4T 盘
sdb      ← 整个 RAID 卷（容量按 RAID 级别算：RAID0=全和，RAID1=最小盘，RAID5=N-1）
  sdb1   ← 你在上面建的分区
```

**路由器完全不感知 RAID 的存在**，也看不到里面有几块盘、哪块盘坏了。
助手页只显示 `sdb` 一块盘、`sdb1` 一个分区 —— 和插一块普通硬盘长得一模一样。

实测渲染出来的样子：

```
▌/dev/sdb   整盘 10.9T   RAID5_VOLUME      ← 卷标/型号是柜子固件报的
   └ sdb1   10.9T   ext4   ✅ 已挂载 → /mnt/sdb1
```

这意味着三件事：

1. **RAID 的健康状态、重建进度、坏盘告警，全都只能在柜子的管理界面/软件里看**，
   路由器这边一概不知情。硬盘柜通常带个 USB 管理口或 Windows 工具。
2. **RAID0 一块盘坏 = 全部数据没了**（这是 RAID0 的定义，不是柜子的毛病）。
3. **RAID5 重建期最脆弱**：重建要读所有盘，期间再坏一块就全丢。
   柜子在做重建的时候，路由器这边性能会明显掉，但界面上看不出原因。

### 11.3 软 RAID（`mdadm`）—— ❌ 本机做不了

实测确认：

```
/proc/mdstat          不存在
lsmod | grep md_mod   空
lsmod | grep raid     空（只有个无关的 md5.ko 是校验算法的）
/dev/md*              不存在
```

bleachwrt 这个固件**没有编译任何 md/RAID 内核模块**，而且因为内核版本是自编译的
`6.12.93`，官方源的 `kmod-*` 也装不上（ABI hash 不匹配）。所以：

- ✅ 硬件 RAID 柜：**能用**（对路由器就是一块普通盘）
- ❌ 路由器自己组软 RAID：**做不到**，别在这上面花时间

### 11.4 挂柜子时要注意的

| 事项 | 说明 |
|---|---|
| **供电** | 多盘柜一定要用**自带电源适配器**的。路由器 USB 口带不动 >1 块 3.5" 盘 |
| **接口** | 优先走 USB 3.0 口；走 2.0 会全部盘挤在 ~40MB/s |
| **拔之前** | 每块盘逐个在助手页点「安全弹出」，或整柜关机后再拔 |
| **`/mnt` 目录名** | 盘符变了挂载点就变（`sdb1` → `sdc1`），OpenList 的存储是按路径配的，**盘符一飘存储就断** |
| **认盘方式** | 所以给 OpenList 配存储时，**能用 UUID 就别用盘符**（OpenList 的 Local 驱动填的是路径，这里只能靠你保持盘符稳定 —— 固定插槽顺序可以减少飘动） |

> 💡 对多盘场景，更稳的做法是**每块盘单独配一个存储**（`/盘A`、`/盘B`……），
> 不要指望用一个存储扫全部盘。

---

## 十二、验证手法（怎么在不插盘的情况下验证多盘逻辑）

这轮为了回答"多块盘会怎么显示"，用了两套离线验证，都**不需要真的插硬盘**：

**① 前端：Node 里桩掉 DOM，喂合成数据跑真 JS**

把 `main.htm` 的 `<script>` 段抠出来，桩掉 `document` / `XMLHttpRequest`，
喂进"4 块盘的设备 JSON"，然后 dump `oa-devs` / `oa-strip` / `oa-batch-list` 的
`innerHTML` 并跑断言（卡片数、开关数、`<form>` 必须 0、button 必须都带 `type`）。

**② 后端：把 `enum_to_file` 换成读固定文件**

`do_list` 的树形打印只依赖 `enum_to_file` 写出的一个文本文件，所以复制一份
`diskctl`、把 `enum_to_file()` 改成 `cp /tmp/xxx.devs "${DEVFILE}"`，
就能用**合成的设备列表**跑真实的打印逻辑：

```sh
enum_to_file() {
    cp /tmp/oa-sim/fake.devs "${DEVFILE}"     # 只在测试副本里这么改
}
```

设备文件格式（9 个字段，`|` 分隔）：

```
设备名|kind|父盘|扇区数|文件系统|卷标|UUID|挂载点|型号
sda2|part|sda|7814000640|ntfs||8CB8C15FB8C14902|/mnt/sda2|
```

`kind` 取值：`disk`=USB 整盘、`part`=USB 分区、`internal`=内置整盘、`ipart`=内置分区。

---

## 相关文档

| 文档 / 脚本 | 讲什么 |
|---|---|
| `OpenList-WebDAV写入403-根因与修复.md` | **WebDAV 能读不能写（403）的真根因**：上游 admin 默认权限位 `0x71FF`（29183）**缺 bit9 = WebDAV 写入** → 新装的 OpenList 开箱即坏。含完整权限位表、三种修法、三层验证、`/dav` 虚拟根不能写文件的坑 |
| `openlist-fix-webdav-write.sh` | 一键修：登录 → 读权限位 → **只加 bit9** → 回写 → 复验；`-n` 只体检、`-d <存储名>` 修完顺便 WebDAV 真写实测 |
| `OpenList-4T硬盘挂载-操作说明.md` | 把 4T 实体盘挂进 OpenList（存储配置、热插拔、开机自动挂） |

> 与本插件的分工：**插件管「盘 ↔ 存储指向」**（挂载、改指向、新建存储）；
> **权限位是 OpenList 用户账号的事**，插件不碰 —— 需要时用上面那个脚本或面板「管理 → 用户」。 <br>
> ⚠️ 客户端地址别填 `.../dav`（虚拟根，PUT 会 404），要填到存储：`.../dav/THW-4T`。
