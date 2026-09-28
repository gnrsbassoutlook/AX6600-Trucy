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
opkg install luci-app-adhfilter_1.0.0-1_all.ipk
# 如果报依赖问题（比如 rom 里包名对不上）：
opkg install --force-depends luci-app-adhfilter_1.0.0-1_all.ipk
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

首次推送会弹窗问 GitHub 账号 —— **用户名填 `gnrsbassoutlook`，
密码栏粘贴 Personal Access Token**（不是登录密码，GitHub 早就不收密码了）。
token 会被存进 macOS 钥匙串 / Windows 凭据管理器，以后不再问。

脚本用 `https://` 而不是 `git@` —— 因为这台机器上没配 SSH key。

---

## 许可

MIT
