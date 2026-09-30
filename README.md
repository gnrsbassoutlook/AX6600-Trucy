# AX6600-Trucy

京东云 **AX6600**（IPQ60xx）在 **bleachwrt / OpenWrt 24.10** 上的自用插件与运维脚本合集。

- **`luci-app-openlist-assist`** —— 给路由器上的 U 盘 / 移动硬盘套一个 LuCI 界面，
  挂载、卸载、清脏标记、格式化、安全弹出都在网页上点。
- **`luci-app-adhfilter`** —— 按设备差异化 DNS 过滤。只有孩子那几台设备走
  AdGuard Home 的 93 万条黑名单，其他设备正常上网。

| 项目 | 值 |
|---|---|
| 机型 | 京东云 AX6600（4G RAM + 128G ROM） |
| 固件 | bleachwrt stable 20260916（`R26.05.20`） / 底座 OpenWrt `24.10.5` |
| target / arch | `qualcommax/ipq60xx` / `aarch64_cortex-a53`，内核 6.12.93 |
| LuCI | 老式 Lua CBI 体系（`controller/*.lua` + `view/*.htm`，带 `luci-compat`） |

> ⚠️ 内核是 bleachwrt **自编译**的，`kmod-*` 依赖里写死了私有 ABI 指纹 →
> **官方源的任何内核模块包都装不上**，整机固件也只能用自己的 ImageBuilder。
> 所以这里的插件一律以 **ipk / 源码**分发。

```
AX6600-Trucy/
├── push.command / push.bat        一键推送到 GitHub
├── luci-app-openlist-assist/      ← 插件一
│   ├── Makefile / build-ipk.py    打包（SDK 用 / 离线用）
│   ├── install.sh / uninstall.sh  免 opkg 装机 / 卸载
│   ├── dist/                      打好的 ipk
│   ├── root/                      铺到路由器 / 的文件树（含 /usr/bin/diskctl）
│   └── tools/                     开发用：离线渲染仿真 + 合成设备数据
├── luci-app-adhfilter/            ← 插件二（同构）
├── tools/adhfilter                命令行后端（插件二只是它的界面）
├── scripts/                       运维脚本
├── patches/oaf/                   OpenAppFilter 白屏修复补丁
└── docs/                          操作手册 / 排障记录
```

---

# 插件一：luci-app-openlist-assist —— OpenList 助手

**解决什么**：路由器上插硬盘、用 OpenList 当网盘，本来要在 SSH 里敲
`mount -o iocharset=utf8` / `umount` / `fsck`。这个插件把它们变成界面上的一个开关。

## 怎么用

打开 **LuCI → 服务 → OpenList 助手**，插好盘点右上角「**刷新**」。

### 一块盘 = 一个开关

| 盘的状态 | 你看到的 | 点一下会怎样 |
|---|---|---|
| **未挂载** | 灰色开关 | 挂载（自动按文件系统选驱动和参数） |
| **已挂载** | 绿色开关 + 挂载点 | 卸载 |
| **没有文件系统** | 开关置灰 | 挂不上（正常，比如 16MB 的保留分区） |

名字、容量、剩余空间、文件系统类型都在左边一列。

### 次要功能收在每行右边的「⋯」里（默认折叠）

| 按钮 | 什么时候用 |
|---|---|
| **强力挂载** | 普通挂载失败时（典型：NTFS 被写了脏标记） |
| **强力卸载** | 普通卸载卸不掉时（自动转 `lazy` + 先停 OpenList） |
| **检查健康** | 看有没有脏标记（只读，不动数据） |
| **清除脏标记** | NTFS 被写脏了用它修（挂一次 → 刷缓存 → 卸掉 → 复核） |
| **格式化** | `exFAT` / `FAT32` / `ext4` 三选一，**要手打一遍设备名才执行** |

**整盘**那行还多一个 **安全弹出** —— 拔线 / 拿去电脑前点它：先卸掉所有分区、
刷干净缓存、再断开设备，免得下次被写脏标记。

### 一次处理多块盘

「**批量操作**」是独立面板，每块盘一个复选框（默认全勾）。范围写死为
**勾选的那些 USB 分区**（内置存储不参与）。里面还有「强制模式」，一次给所有盘带 force / stop。

### 和 OpenList 的联动 ⭐

盘正被某个 OpenList 存储用着时，行里显示蓝色徽章 `OpenList · /THW-4T`。这时点卸载会自动：

```
先停 OpenList  →  卸盘  →  自动把 OpenList 拉起来
```

不用手动停服务 —— 盘上有 OpenList 打开的文件，不停一定 `device busy`。

「**OpenList**」面板里能看到全部存储（挂载路径 / 实际根路径 / 驱动 / 状态），
也能一键**启动 / 停止 OpenList**、打开它的 Web 面板。刷新时一起更新。

#### 换盘了？点「改指向…」（v1.2.0 新增）

OpenList 的存储存的是**路径**（例如 `/mnt/sda2`），不认设备名也不认 UUID。
所以换盘、换 USB 口、盘符从 `sda` 变成 `sdb` 之后，旧指向就会失效 ——
网页上那个目录变成打不开的「根路径未挂载」。

存储表每行右边多了 **「改指向…」**（*路径没挂上时自动变成醒目的主按钮），
面板头多了 **「新建存储」**。点开是一个**动态列表**：列出当前真实存在的每一块盘
（设备名 / 挂载点 / 文件系统 / 容量），没挂载的置灰并提示先挂上，
**内置 eMMC 也在列表里**（带「内置 eMMC」标签，挂到 `/mnt/emmc`）。

> **为什么不做成「分区号 1~9 下拉」**：扩展分区盘的号不连续（`sda1` + `sda5`，
> 中间的 `2/3/4` 是空的）；换个 USB 口盘符会从 `sda` 变 `sdb`（选单里没有 "b"）；
> 小 U 盘压根没有分区表，设备名就是 `sda` 本身。**动态列真盘**这些情况全覆盖。

### 内置存储

路由器自己那颗 128G eMMC 里的**空白数据分区**单独一个面板，默认未挂载，
点开关挂到 `/mnt/emmc`。它**不允许格式化、不允许弹出**（保护系统分区）。

## 支持的格式

| 格式 | 挂载 | 格式化 | 备注 |
|---|---|---|---|
| **NTFS** | ✅ 内核 `ntfs3` | ❌ | 本固件无 fuse，装不了 `mkntfs`；但**挂载读写完全正常** |
| **exFAT** | ✅ 内核内置 | ✅ | 要装 `exfat-mkfs` |
| **FAT32** | ✅ 内核内置 | ✅ | 要装 `dosfstools` |
| **ext4** | ✅ 内核内置 | ✅ | 要装 `e2fsprogs` |

⭐ **驱动全是内核自带的** —— 挂载不用装任何包。只有**格式化 / 检查**的用户态工具要装，
界面上「工具自检 → **一键安装**」会一次装齐。

> **两个包名坑**（官方源跟常识不一样）：① 没有 `exfatprogs` 这个总包，是拆成
> **`exfat-mkfs` + `exfat-fsck`** 的；② `dosfstools` 装出来的命令叫
> **`mkfs.fat` / `fsck.fat`**，不叫 `mkfs.vfat`。

## 安装 / 卸载

```sh
# 方式一：ipk（推荐）
opkg install luci-app-openlist-assist_1.2.0-1_all.ipk
opkg install --force-depends luci-app-openlist-assist_1.2.0-1_all.ipk   # 依赖对不上时

# 方式二：源码直接铺文件（不依赖 opkg）
cd luci-app-openlist-assist && sh install.sh

# 卸载
sh luci-app-openlist-assist/uninstall.sh        # 或 opkg remove luci-app-openlist-assist
```

装完打开 **LuCI → 服务 → OpenList 助手**（菜单在 AdGuard Home 旁边），
第一次**强刷浏览器**（`Ctrl/Cmd+Shift+R`，LuCI 静态资源有缓存）。

**运行时前提**（插件只检查、不负责装）：

- `blkid` —— 探文件系统类型：`opkg update && opkg install blkid`
- **OpenList 本体** —— 插件只管启停它。装法见 `docs/OpenList-4T硬盘挂载-操作说明.md`

**卸载只删「界面 + `/usr/bin/diskctl`」**。`/etc/rc.local` 的挂载调用、
`/etc/hotplug.d/block/*`、`fstab`、OpenList 存储配置、**盘上数据**一律不动 ——
卸完界面，硬盘照样开机自动挂回来。

---

# 插件二：luci-app-adhfilter —— ADH设备过滤助手

给 `/usr/bin/adhfilter` 套一个 LuCI 界面。核心交互是**穿梭框**：左边「正常上网」、
右边「封禁 NSFW 站点」，点箭头**即生效（不弹确认框）**。

## 怎么用

打开 **LuCI → 服务 → ADH设备过滤助手**，会列出 LAN 上所有设备
（IP / 名字 / MAC / 在线 / 是否在名单）。四个动作：

| 操作 | 效果 |
|---|---|
| 设备**搬进右边** | `bind`（固定 IP）+ `add`（加过滤），立刻生效 |
| **搬回左边** | `del`（DNAT 规则 + 静态绑定一起撤） |
| 点 **🏷** | 写你自己的**备注**（支持中文） |
| 点 **✎** | 改「路由器侧写进 dnsmasq 的设备名」（只能字母数字 `_` `-`） |

可以**多选批量搬运**，顶部 5 张状态卡 + 一键自检。识别到随机化 MAC
（首字节第二 bit = 1）会提示你先关掉「私有 Wi-Fi 地址」。

## 🏷 备注 vs 设备名 —— 为什么必须有备注

列表里的设备名是**设备自己上报**的（手机「设置 → 关于本机 → 名称」那栏），
**孩子在自己手机上随手就能改掉** —— 今天叫 `Watch`，明天改叫 `MacBookAir`，
你在路由器这边看不出来。所以每台设备可以写一个**只有你写得了**的备注：

| 对比项 | 设备自报的名字 | 🏷 备注 |
|---|---|---|
| 谁改得了 | 设备自己（孩子） | **只有管理员** |
| 存哪 | DHCP 租约（临时） | `/etc/adhfilter.labels`（持久） |
| 中文 | 不行（会让 dnsmasq 崩） | **可以** |
| 主键 | IP | **MAC**（换 IP 也不丢） |
| 生效代价 | 重启 dnsmasq（5~15 秒） | **瞬间，不重启任何服务** |

> 只想自己认人 → 用 **🏷**；想让全家设备 / DNS 日志都显示这个名字 → 才用 **✎**。

## 安装 / 卸载

```sh
opkg install luci-app-adhfilter_1.1.0-1_all.ipk    # 或：cd luci-app-adhfilter && sh install.sh
sh luci-app-adhfilter/uninstall.sh                  # 或 opkg remove luci-app-adhfilter
```

**运行时前提**（插件不负责装）：`/usr/bin/adhfilter`（见 `tools/`）+ AdGuard Home 监听 `5335`。

卸载**只删界面**，已设好的过滤规则（firewall 锚点、dhcp 静态绑定）**一律保留**。
`uninstall.sh` 会额外删掉备注文件 `/etc/adhfilter.labels` —— 它只有界面能读写，
留着就是一份没主的数据，**舍不得就先备份**。

---

# 命令行工具

不用界面时，这两条命令能完成同样的事。

## `tools/adhfilter`

```sh
adhfilter devices / list / check                 # 列设备 / 列名单+锚点状态 / 五项自检
adhfilter bind <IP|名字> / add <IP|名字>          # 固定 IP / 加入过滤
adhfilter del  <IP|名字> / resync <IP|名字>       # 移出过滤（规则+绑定一起删） / 换 MAC 后刷新锚点
adhfilter rename <IP|名字> <新名>
```

**双锚设计**：每台设备建两条 DNAT 规则 —— IP 锚 `KidADH_<ip>` + MAC 锚 `KidADHM_<mac>`，
任一条失效另一条仍拦得住。锚点必须 `uci reorder ...=0` 排在 `Force-DNS-to-Router` 之前
（DNAT 首个匹配才生效）。LAN 地址是 `uci -q get network.lan.ipaddr` **动态读**的，
所以同一份脚本两台通用；写死会静默失效。

## `diskctl`（随插件一装到 `/usr/bin/diskctl`）

```sh
diskctl list / json                            # 列盘（整盘在前、分区缩进在后） / JSON
diskctl mount  sda2 [--force] [--ro]           # 挂载
diskctl umount sda2 [--force] [--stop]         # 卸载（--stop 先停 OpenList）
diskctl dirty  sda2 / clean sda2               # 查脏标记 / 清脏标记
diskctl eject  sda                             # 安全弹出（仅 USB，内置盘拒绝）
diskctl format sda2 exfat --yes                # exfat | vfat | ext4
diskctl openlist start|stop / olstorages       # 启停 OpenList / 列它的存储
diskctl tools [--install] / log 60             # 工具自检一键装 / 看操作日志
```

---

# 其他目录

## `scripts/`

| 脚本 | 用途 |
|---|---|
| `mount-data-disk.sh` | 4T 数据盘挂载（幂等；自带等设备、脏标记 force 兜底）。装到 `/root/` |
| `umount-data-disk.sh` | 安全弹出 4T 盘（**拔线前必做**）。`--stop` 会先停 OpenList |
| `99-mount-data-disk` | 热插拔自动挂载。装到 `/etc/hotplug.d/block/` |
| `change-lan-ip.sh` | 整体迁 LAN 网段，含 adhfilter 锚点同步（预览 / 备份 / 回滚） |
| `孩子设备换IP-movekid.sh` | 单台孩子设备换 IP |
| `ADH上游改为本机分流-set_adh_upstream.sh` | 把 ADH 上游切到本机分流链 |
| `扶正迁移-migrate-host.sh` | 主从角色互换时的迁移 |
| `openlist-fix-webdav-write.sh` | **修 OpenList「WebDAV 能读不能写（403）」**：登录 → 读权限位 → 只加 bit9(512) → 回写 → 复验，可选 WebDAV 真写实测。**上游默认 `0x71FF` 缺 bit9，装完就坏**。详见 `docs/OpenList-WebDAV写入403-根因与修复.md` |

前三个是给 OpenList 配「实体硬盘」的最小集（4T 盘 → `/mnt/sda2` → OpenList 存储 →
WebDAV，断电自动挂回来），配 `docs/OpenList-4T硬盘挂载-操作说明.md` 用。

## `docs/`

| 文档 | 讲什么 |
|---|---|
| `OpenList助手-界面与联动说明.md` | **插件一的完整说明书**：开关语义、批量范围、OpenList 联动、**换盘改指向**、内置 eMMC、安全边界、格式矩阵、部署回滚 |
| `OpenList-4T硬盘挂载-操作说明.md` | 把 4T 实体盘挂进 OpenList（含 WebDAV、热插拔、开机自动挂） |
| `OpenList-WebDAV写入403-根因与修复.md` | **WebDAV 写入 403 的真根因**：上游 admin 默认权限位 `0x71FF` 缺 bit9（WebDAV 写入）。完整权限位表、三种修法、三层验证（协议/挂载点/物理盘）、`/dav` 虚拟根不能写文件的坑 |
| `ADH按IP控制-防火墙规则速查.md` | 双锚规则的速查表 |
| `副路由器192.168.3.1-ADH过滤操作说明.md` | 在另一台机器上从零配过滤（含五个坑） |
| `孩子设备过滤-自己动手操作手册.md` | 手工操作版 |
| `改LAN网段-影响清单与操作步骤.md` | 换 LAN 网段会影响什么、ADH 要不要动 |
| `副机搬单位-改LAN与注意事项.md` | 副机搬去别的网络：改 LAN 只需 2 处、**单位网段撞段预检**、Tailscale 合规、换盘后 OpenList 认盘规律 |
| `新主机192.168.1.1-迁移与修复记录.md` | 主机迁移记录 |
| `OAF界面空白-修复记录.md` | OpenAppFilter 页面白屏的真根因与修法 |
| `AX6600从机192.168.3.1配置报告.md` | **从机交付报告**：源对齐、OpenList + iStore、ADH/OAF 分工策划、iPhone 专项调优、过滤库扩容到 93 万条、回滚清单 |

## `patches/oaf/`

OpenAppFilter 7.0「**页面能开、数据全空**」的修复补丁。根因是 `oaf.lua` 里的 `api`
中间节点没被 `entry()` 注册，成了 `auto=true` → 72 条 `/oaf/api/*` 接口全部 500
（`has no parent node`）。`oaf.lua` / `oaf_user.lua` 覆盖到 `/usr/lib/lua/luci/controller/`。
升级 `luci-app-oaf` 会被覆盖，**需要重打**。

---

# 维护

## 推仓库

双击 `push.command`（macOS）或 `push.bat`（Windows），提示填 commit 说明。
认证走 **SSH key**，不用 PAT、不会过期。首次：

```sh
ssh-keygen -t ed25519 -C "gnrsbassoutlook@users.noreply.github.com"
pbcopy < ~/.ssh/id_ed25519.pub        # Windows: type %USERPROFILE%\.ssh\id_ed25519.pub
```

公钥粘到 <https://github.com/settings/ssh/new>。没配好时脚本会自己检测并打开该页面。

两个坑：⚠️ `ssh -T git@github.com` **成功时退出码也是 1**（GitHub 不给 shell），
只能看输出里有没有 `successfully authenticated`；⚠️ 公开仓库的 `git ls-remote`
**不带凭据也返回 0**，要验身份就得用写操作（`git push --dry-run`）。

## 打 ipk

```sh
cd luci-app-openlist-assist && python3 build-ipk.py     # 只用标准库，不需要 SDK
```

现代 `.ipk` 是**三层嵌套**，外层 gzip 不能省：`gzip(tar(debian-binary + data.tar.gz + control.tar.gz))`。
踩过的四个坑：① 不是 ar 归档（旧 deb 风格，留了 `--legacy-ar`）；② 裸 tar 会被判
`Malformed package file`；③ control 里别写 `Section-Priority:`（opkg 会截断字段）；
④ 别把 macOS 的 `.DS_Store` 打进包（`build-ipk.py` 已内置过滤）。

## 历史

本仓库以前叫 `JustinBlockURL`，是按**客户端名**屏蔽的 ADH 规则库（5 行
`||bilibili.com^$client='Justin_iPhone'` 之类）。**2026-09 已整体退役** ——
客户端名改个名 / 丢绑定就失效，被 `luci-app-adhfilter` 的「IP + MAC 双锚」取代。
旧订阅还在的话，去 **AdGuard Home → 过滤器 → DNS 黑名单** 删掉 `Justin-Block-URL`。

---

MIT
