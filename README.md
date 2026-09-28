# AX6600-Trucy

京东云 **AX6600**（IPQ60xx）在 **bleachwrt / OpenWrt 24.10.5** 上的自用插件与运维脚本合集。

主要解决一件事：**按设备差异化 DNS 过滤** —— 家里只有孩子那几台设备走 AdGuard Home 的黑名单，
其他设备正常上网。顺手也放了这个路由器上用到的其他补丁、脚本和排障记录。

---

## 硬件 / 固件

| 项目 | 值 |
|---|---|
| 机型 | 京东云 AX6600（4G RAM + 128G ROM） |
| 固件 | bleachwrt stable 20260916（`R26.05.20`） |
| 底座 | OpenWrt `24.10.5` |
| target | `qualcommax/ipq60xx` |
| arch | `aarch64_cortex-a53` |
| 内核 | 6.12.93 |
| LuCI | `git-26.159.06565`（老式 Lua CBI 体系，**有** `luci-compat`） |

> ⚠️ 因为 `kmod-oaf` 依赖 bleachwrt 私有的内核 ABI 指纹
> （`kernel (=6.12.93-1-d60beb79…)`），**这个项目没法用官方 ImageBuilder 打固件包**。
> 插件只能以 ipk / 源码形式分发，见下。

---

## 目录结构

```
AX6600-Trucy/
├── README.md
├── push.command / push.bat       一键推送到 GitHub
├── luci-app-adhfilter/           ← 主角：LuCI 插件
│   ├── Makefile                  OpenWrt SDK 用
│   ├── build-ipk.py              离线打包脚本（不需要 SDK）
│   ├── install.sh                一键装（不依赖 opkg）
│   ├── uninstall.sh              一键卸
│   ├── dist/                     打好的 ipk
│   └── root/                     实际会铺到路由器 / 的文件树
├── tools/
│   └── adhfilter                 后端命令行工具（插件是它的界面）
├── scripts/                      运维脚本
├── patches/oaf/                  OpenAppFilter 白屏修复补丁
└── docs/                         操作手册 / 排障记录
```

---

## luci-app-adhfilter —— ADH设备过滤助手

给 `/usr/bin/adhfilter` 套一个 LuCI 界面。
核心交互是**穿梭框**：左边「正常上网」、右边「封禁 NSFW 站点」，点箭头即生效。

### 它做了什么

- 列出 LAN 上所有设备（IP / 名字 / MAC / 是否在线 / 是否在过滤名单）
- 把设备搬进「封禁 NSFW」= 自动 `bind`（固定 IP）+ `add`（加过滤）
- 搬回左边 = `del`（规则 + 静态绑定一起撤）
- 支持手动填 IP、改名、一键自检
- 识别随机化 MAC（首字节第二 bit = 1），会提示你先关掉「私有 Wi-Fi 地址」
- **可多选批量搬运**（勾几台点一次，串行执行、逐台报结果）
- **🏷 自定义备注** —— 给设备起一个只有你看得懂的标记，**支持中文**

### 🏷 备注：为什么不能拿「设备名」认设备

列表里的设备名是**设备自己上报**的（手机「设置 → 通用 → 关于本机 → 名称」那一栏），
也就是说 —— **孩子在自己手机上随手就能把它改掉**。今天叫 `Watch`，明天改叫 `MacBookAir`，
你在路由器这边是看不出来的。

所以插件给每台设备加了一个**只有你写得了**的备注：

| | 设备自报的名字 | 🏷 备注 |
|---|---|---|
| 谁能改 | 设备自己（孩子） | **只有路由器管理员** |
| 存在哪 | DHCP 租约（临时） | `/etc/adhfilter.labels`（持久） |
| 中文 | 不行（会让 dnsmasq 崩溃） | **可以** |
| 主键 | IP | **MAC**（设备换 IP 也不丢） |
| 读写代价 | 改一次要重启 dnsmasq（5~15 秒） | **瞬间生效，不重启任何服务** |

点设备右侧的 **🏷** 就能写。写了备注的设备，名字会用蓝色 + 标签图标标出来，
下面一行仍然显示 IP 和 MAC —— **后两个才是设备真正的身份，改不掉**。

> 旁边的 **✎** 是另一回事：那是改「路由器侧写进 dnsmasq 的设备名」，
> 只能字母/数字/下划线/连字符，改一次要重启 dnsmasq。
> 只想自己认人 → 用 **🏷**；想让全家设备/DNS 日志里都显示这个名字 → 才用 **✎**。

### 依赖

```
libc, luci-base, luci-compat, luci-lua-runtime
```

外加**运行时前提**（插件不负责装）：

- `/usr/bin/adhfilter` —— 见 `tools/adhfilter`
- AdGuard Home 本体监听 `5335`，带黑名单表

### 安装

**方式一：ipk（推荐）**

```sh
opkg install luci-app-adhfilter_1.1.0-1_all.ipk
# 如果报依赖问题（比如 rom 里包名对不上）：
opkg install --force-depends luci-app-adhfilter_1.1.0-1_all.ipk
```

**方式二：源码直接铺文件**

```sh
cd luci-app-adhfilter && sh install.sh
```

装完打开 **LuCI → 服务 → ADH设备过滤助手**，菜单就在 AdGuard Home 旁边。
第一次打开记得**强刷浏览器**（LuCI 静态资源有缓存）。

### 卸载

```sh
sh luci-app-adhfilter/uninstall.sh
# 或者 opkg remove luci-app-adhfilter
```

两种方式都**只删界面**，已经设好的过滤规则（firewall 里的锚点、dhcp 里的静态绑定）**一律保留**。
要连过滤一起撤，用 `adhfilter del <IP>`。

`uninstall.sh` 会额外删掉 `/etc/adhfilter.labels`（🏷 备注文件）—— 那个文件只有界面能读写，
留着就是一份没主的数据。舍不得就先备份。

### 自己打包 ipk

```sh
cd luci-app-adhfilter
python3 build-ipk.py             # 出 dist/*.ipk（OpenWrt 24.10+ 格式）
python3 build-ipk.py --legacy-ar # 额外出一个老式 ar 归档，给很旧的 opkg
```

`build-ipk.py` 只用 Python 标准库，**不需要 OpenWrt SDK**。

**关于 ipk 格式**（2026-09 实测，踩了两个坑才有结论）：

现代 `.ipk` 是**三层嵌套**，外面那层 gzip 不能省：

```
gzip( tar( ./debian-binary + ./data.tar.gz + ./control.tar.gz ) )
```

- ❌ 不是 ar 归档（那是旧 deb 风格，只有老 opkg 才认，留了 `--legacy-ar`）
- ❌ 外面的 gzip **不能省**：裸 tar 会被 opkg 判 `Malformed package file`
- ❌ control 里**别写 `Section-Priority:`**：opkg 会打印
  `ERROR: truncating field 4 ... to 5 byte`（虽然装得上，但 DB 字段是截断的）
- ❌ **别把 macOS 的 `.DS_Store` 打进包**：Finder 每浏览一个目录就会生成一个，
  装到路由器上会凭空多出 `/.DS_Store`。`build-ipk.py` 已内置过滤
  （`JUNK_NAMES` + `._*`，且对目录用 `dirnames[:] = ...` 就地裁剪，否则 `os.walk` 照样递归进去）

复现方式见 `build-ipk.py` 顶部的注释。

---

## tools/adhfilter

命令行后端。用 shell 写的，无外部依赖。

```sh
adhfilter devices              # 列出所有设备
adhfilter list                 # 列出被过滤的设备 + 两条锚点的状态
adhfilter bind   <IP|名字>      # 绑定固定 IP（必须做，不等于加入过滤）
adhfilter rename <IP|名字> <新名>
adhfilter add    <IP|名字>      # 加入过滤
adhfilter del    <IP|名字>      # 移出过滤（规则 + 静态绑定一起删）
adhfilter resync <IP|名字>      # 按当前状态刷新锚点（设备换了 MAC 后用）
adhfilter check                # 五项自检
```

**设计要点：**

- 每台设备建 **两条** DNAT 规则（**双锚**）：IP 锚 `KidADH_<ip>` + MAC 锚 `KidADHM_<mac>`。
  任一条失效另一条仍然拦得住 —— 换 IP、丢 DHCP 绑定都不怕。
- 锚点必须 `uci reorder ...=0` 排在 `Force-DNS-to-Router` 之前（DNAT 首个匹配才生效）。
- 本机 LAN 地址是 `uci -q get network.lan.ipaddr` **动态读取**的，所以同一份脚本两台机器通用。
  写死会把 `dest_ip` 指到隔壁机器上，过滤**静默失效**。

---

## 已退役：`Justin-Block-URL.txt`

这个仓库以前叫 `JustinBlockURL`，是个**按客户端名屏蔽**的 AdGuard 规则库，内容就 5 行：

```
||bilibili.com^$client='Justin_iPhone'
||iqiyi.com^$client='Justin_iPhone'
||weibo.com^$client='Justin_iPhone'
||zhihu.com^$client='Justin_iPhone'
||163.com^$client='Justin_iPhone'
```

**2026-09 已整体退役**，文件和 ADH 里对应的订阅都已删除。原因是这套方案被本仓库的
`luci-app-adhfilter` 取代了，后者粒度更细：

| | 旧方案（`$client=`） | 现方案（`adhfilter`） |
|---|---|---|
| 匹配依据 | 客户端**名字**（改个名/丢绑定就失效） | LAN IP **+** MAC 双锚 |
| 作用范围 | 只能是「规则文件里写死的那几个站」 | 整份 93 万条 NSFW 黑名单 |
| 怎么改 | push 到 GitHub，等 ADH 拉取 | LuCI 界面点一下，即时生效 |

> 如果你在旧版本上还留着这条订阅，去 **AdGuard Home → 过滤器 → DNS 黑名单**
> 把名字为 `Justin-Block-URL` 的那条删掉即可。
> 或者命令行一条：
> ```sh
> curl -s -b /tmp/agh.jar -X POST -H 'Content-Type: application/json' \
>   -d '{"url":"https://raw.githubusercontent.com/gnrsbassoutlook/JustinBlockURL/refs/heads/main/Justin-Block-URL.txt"}' \
>   http://127.0.0.1:3000/control/filtering/remove_url
> ```
> （走 API 移除**不需要重启 ADH**，孩子的 DNS 不会断。）

---

## docs/

| 文档 | 讲什么 |
|---|---|
| `ADH按IP控制-防火墙规则速查.md` | 双锚规则的速查表 |
| `副路由器192.168.3.1-ADH过滤操作说明.md` | 在另一台机器上从零配过滤（含 adhfilter 一条命令版 + 手动 uci 等效版 + 五个坑） |
| `孩子设备过滤-自己动手操作手册.md` | 手工操作版 |
| `改LAN网段-影响清单与操作步骤.md` | 换 LAN 网段（如改成 `192.168.2.1`）会影响什么、ADH 要不要动 |
| `新主机192.168.1.1-迁移与修复记录.md` | 主机迁移记录 |
| `OAF界面空白-修复记录.md` | OpenAppFilter 页面白屏的真根因与修法 |

## scripts/

| 脚本 | 用途 |
|---|---|
| `change-lan-ip.sh` | 整体迁 LAN 网段，含 adhfilter 锚点同步（带预览 / 备份 / 回滚） |
| `孩子设备换IP-movekid.sh` | 单台孩子设备换 IP |
| `ADH上游改为本机分流-set_adh_upstream.sh` | 把 ADH 上游切到本机分流链 |
| `扶正迁移-migrate-host.sh` | 主从角色互换时的迁移 |

## patches/oaf/

OpenAppFilter 7.0 在 LuCI 上「页面能开、数据全空」的修复补丁。
根因是 `oaf.lua` 里 `api` 中间节点没被 `entry()` 注册成了 `auto=true`，
导致 72 条 `/oaf/api/*` 接口全部 500（`has no parent node`）。

- `oaf.lua` / `oaf_user.lua` → 覆盖到 `/usr/lib/lua/luci/controller/`
- 升级 `luci-app-oaf` 会覆盖补丁，**需要重打**

---

## 怎么推这个仓库

双击 `push.command`（macOS）或 `push.bat`（Windows）就行，会提示你填 commit 说明。
已经推过的提交、已经存在的东西，重跑不会白做。

认证走 **SSH key**，不用 Personal Access Token、不会过期。首次配置：

```sh
ssh-keygen -t ed25519 -C "gnrsbassoutlook@users.noreply.github.com"
pbcopy < ~/.ssh/id_ed25519.pub        # macOS
# Windows: type %USERPROFILE%\.ssh\id_ed25519.pub
ssh -T git@github.com                 # 出现 "successfully authenticated" 就通了
```

公钥粘到 <https://github.com/settings/ssh/new>。
**没配好时脚本会自己检测出来**，把公钥复制进剪贴板并打开这个页面。

两个坑写在这里省得下次再踩：

- ⚠️ `ssh -T git@github.com` **成功时退出码也是 1**（GitHub 不提供 shell 访问，
  故意返回非 0）→ 只能看输出里有没有 `successfully authenticated`，**不能判退出码**。
- ⚠️ 公开仓库的 `git ls-remote` **不带凭据也返回 0** → 拿它当"有没有身份"的探针
  永远报成功。要验身份就得用写操作（`git push --dry-run`）。
- ⚠️ 若 22 端口被网络封掉，`~/.ssh/config` 里备好了走 443 的配置（取消注释即可）。

---

## 许可

MIT
