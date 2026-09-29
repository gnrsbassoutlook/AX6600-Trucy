# 把副机 `192.168.3.1`（AX6600-TWS）搬去单位工作室 —— 操作清单

> 结论先说：**改 LAN IP 只有 2 处必改**，其余全部自动跟随。
> 🔴 **但"改成什么"取决于单位内网网段 —— 动手前必须先确认这一件事。**

---

## 〇、开工前唯一的前置检查：单位网段

副机的 **WAN 口会接在单位的网络上**（现在是接在主机 LAN 上）。所以：

| 单位内网 | 副机 LAN 应该设 |
|---|---|
| 不是 `192.168.1.x` | ✅ `192.168.1.1` 可以用 |
| **也是 `192.168.1.x`** | ❌ **绝对不能用** —— LAN 和 WAN 同段，路由会走错接口，表现为"能连上但上不了网/时通时断" → 改用 `192.168.2.1` |
| 是 `10.x` / `172.16~31.x` | ✅ `192.168.1.1` 可以用 |

**怎么查**：在单位随便找台电脑看它的 IP / 网关；或者把副机 WAN 先插上、登进 LuCI 看 WAN 拿到的地址段。

> `192.168.1.1` 在家里会和主机的 LAN 撞（两台都是 `.1.1`）—— 搬走之后就不冲突了，
> 但**副机在家调试时别改成 `.1.1`**。

---

## 一、必改的 2 处（就这两处）

| # | 位置 | 现值 | 改成 |
|---|---|---|---|
| 1 | `network.lan.ipaddr` | `192.168.3.1` | `192.168.1.1` |
| 2 | `firewall.force_dns.dest_ip` | `192.168.3.1` | `192.168.1.1` |

第 2 条是那条 `Force-DNS-to-Router` 的强制 DNS 重定向（`src=lan`、`src_dport=53`、`DNAT`）。
**漏改的后果**：LAN 内设备的 53 端口被 DNAT 送到一个不存在的地址 → **上不了网**。

### 命令

```sh
NEW=192.168.1.1

# 备份
mkdir -p /root/lanip-backup && cp /etc/config/network /etc/config/firewall /root/lanip-backup/

# ① LAN IP
uci set network.lan.ipaddr=$NEW

# ② 强制 DNS 规则
uci set firewall.force_dns.dest_ip=$NEW

# 一次提交 + 生效
uci commit network; uci commit firewall
/etc/init.d/network reload          # SSH 会断，用新地址重连
/etc/init.d/firewall reload
```

> ⚠️ 改完**从 Mac 侧**用新地址重连（`wssh.exp <新IP> <口令> ... <本机网卡IP>`）。

### 改完立刻验证

```sh
uci show firewall | grep 192.168.3      # 期望：完全为空
uci show network  | grep 192.168.3      # 期望：完全为空
/etc/init.d/AdGuardHome status          # ADH 仍在跑（它通配监听，自动跟）
netstat -ltn | grep -E ":53|:3000"      # 53 / 3000 在听
```

---

## 二、不用动的（已逐项核实过）

| 东西 | 为什么不用动 |
|---|---|
| `dhcp.lan` 地址池 | 用**相对** `start`/`limit`，不是绝对 IP |
| `dhcp` 静态租约 | 副机**一条都没有**（零过滤名单） |
| ADH 本体 | `bind_hosts=0.0.0.0`、`http 0.0.0.0:3000`、`allowed_clients=[]` 全通配 |
| `chinadns-ng` / `v2ray` / `dns2tcp` | 全走 `127.0.0.1` |
| **Tailscale** | 走 `100.x` 隧道地址，**和 LAN 网段无关** |
| **OpenList** | `:5244` 监听 `::`（通配） |
| `adhfilter` / OpenList 助手 | 动态读 `network.lan.ipaddr` |
| uci 段名（`KidADH_*` 等） | 副机**没有**这类段，不存在"孤儿规则"问题 |

> 对比主机：主机改 LAN 要动 **6 处**（含段名 `uci rename`），因为主机有孩子设备的双锚段。
> **副机干净得多，只有 2 处。**

---

## 三、另外要留意的 3 件事

### 1. 副机硬编码了 DNS
`network.wan.peerdns='0'` + `dns='223.5.5.5 119.29.29.29'`。
在单位这可能被判为"绕过单位 DNS 策略"。如果单位有统一 DNS/行为管理，**考虑改成跟随单位下发**（把 `peerdns` 设回 `1` 并删掉 `dns`）：

```sh
uci set network.wan.peerdns='1'; uci delete network.wan.dns; uci commit network
```

### 2. 单位网络本身可能不欢迎私接路由器
NAT 设备、端口准入（802.1x）、MAC 白名单都可能拦。这属于**单位规定**问题，不是技术问题。

### 3. 副机上的管理服务会一起"跟去"
LuCI `:80`、OpenList `:5244`、ADH `:3000` 都监听 `0.0.0.0` → 在单位网里，**同一网段的其他人可能能访问到它们**
（取决于单位是否隔离客户端 / 副机防火墙是否放行 WAN 侧入站）。默认 fw3 是挡 WAN 入站的，所以一般没事；
但若你为了从 LAN 访问而放行了，就会暴露。**搬过去之后建议在单位网里扫一下自己的端口确认。**

---

## 四、Tailscale 在单位用，危险吗？

**和 SMB 毫无关系**（SMB 是另一扇门）。Tailscale 本身：

| 维度 | 事实 |
|---|---|
| 通信方向 | **只出不进**。设备主动连 `controlplane.tailscale.com` + 必要时 DERP 中继，**不需要任何入站端口** |
| 加密 | 端到端 WireGuard；单位和 Tailscale 中继都**看不到隧道内容** |
| 地址 | `100.x`（CGNAT 段），**不是**从单位网里开洞 |
| 会不会桥接内网 | **不会** —— 副机没开 subnet route（`accept-routes=false`、LuCI 里"公开网段"留空）→ 单位内网其他机器**不会**被家里设备摸到 |

**单位侧能看到的是**：你的设备在连 `*.tailscale.com` / DERP 的 IP；以及到陌生公网 IP 的 **UDP 41641**（打洞）。
有行为管理/境外流量管控的单位，**有可能识别甚至阻断**。

**真正的风险是合规，不是技术**：
- 多数事业单位对"私自组网 / 未报备的隧道"是有规定的，属于违规项。
- 副机上还跑着 LuCI / OpenList / ADH 三个管理页，一旦被别人拿到访问，等于拿到了这台设备，而它在单位网里。

**要更保险的三个动作**（任选）：
```sh
/etc/init.d/tailscale stop && /etc/init.d/tailscale disable   # 干脆不开（最稳）
tailscale up --shields-up                                     # 拒绝别人主动连它，自己仍能出去
# 或在控制台用 ACL 限制哪些设备能连 ax6600-tws
```

---

## 五、换盘之后 OpenList 还能认到吗？

**机制**：OpenList 的"本机存储"里存的是**挂载路径**（副机现在是 `root = /mnt/sda1`），
**不认设备名、不认 UUID**。所以判断标准只有一条：**挂载路径还一不一样**。

**挂载路径由助手决定**（`/usr/bin/diskctl` 的 `mnt_target()`）：
- 内置白名单盘 → 固定 `${INTERNAL_MNT}`（默认 `/mnt/emmc`）
- **USB 盘 → `/mnt/<设备节点名>`**（`/mnt/sda1`、`/mnt/sdb1`）

### 结论

| 情况 | 挂载点 | OpenList |
|---|---|---|
| **单盘单分区**（U盘 ↔ 硬盘随便换） | 恒为 `/dev/sda1` → `/mnt/sda1` | ✅ **完全无感** |
| 盘有 2 个分区，数据区成 `sda2` | `/mnt/sda2` | ⚠️ 路径变了 → 把存储的 `root` 改过去 |
| 同时插两块盘 | 第二块成 `sdb1` | ⚠️ 同上 |

> 你说的"到单位插硬盘自然就变 `sda2`"—— **不一定**。单纯一块单分区硬盘还是 `sda1`；
> 变成 `sda2` 只在这块盘本身带 2 个分区时（比如从 PC 拆下来、含 EFI/恢复分区的盘）。
> **怎么一眼看**：助手页面上每个分区旁边就写着它挂到哪；或跑 `diskctl list` 看 `mount` 字段。

### 两点要注意

1. **卸载有联动**：助手卸载"正被存储引用"的盘时，会**自动把那个存储停掉**（避免 OpenList 报错）。
   重新挂载后，把存储开关再打开即可。
2. ⚠️ **副机没有热插拔自动挂载**（不像主机有 `mount-data-disk.sh` + `99-mount-data-disk`）
   → **重启后 USB 盘不会自动挂回来**，要在助手页面点一次「挂载」。
   （要不要给副机也加一套开机自动挂载？说一声，照主机那套抄一份即可。）

### 想彻底免疫换盘

给硬盘设一个**固定 label**，并把它写进 `/etc/config/fstab`（用 `uuid` 或 `label` + 固定 `target`），
让挂载点与设备节点名解耦 —— 这样节点名怎么变，路径都不变。

---

*2026-09-30 生成。执行前请再核一次单位网段。*
