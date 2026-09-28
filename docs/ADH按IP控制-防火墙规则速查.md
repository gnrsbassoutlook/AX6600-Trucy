# 按 IP 控制色情网站过滤（方案 B · 已上线）

> 对象：从机 **192.168.3.1**（bleachwrt）
> 铁律：**192.168.1.1（当前主机）只读，绝不修改**
> 状态：**已于 2026-09-27 部署并实测通过**

---

## 一、现在的过滤架构

```
孩子设备（在名单内） → 从机:53 → DNAT → 从机:5335 (ADH) → 主机 192.168.1.1   ← 被过滤
其他设备             → 从机:53 → dnsmasq 正常解析     → 主机 192.168.1.1   ← 不过滤
```

具体改动：

| 位置 | 改成了什么 |
|---|---|
| `dnsmasq` | **摘除** `server=127.0.0.1#5335`，`noresolv=0` → 默认走 WAN 上游（主机 192.168.1.1） |
| `firewall` | 每台孩子设备加 **2 条** `redirect`（**双锚**）：① `src_ip=该设备` ② `src_mac=该设备MAC` → 都 DNAT 到 `192.168.3.1:5335` |
| `firewall` | 原有的 `Force-DNS-to-Router`（LAN→WAN/53 → DNAT 回 192.168.3.1:53）**保留**，防止改 DNS 绕过 |
| `dhcp` | 孩子设备做**静态绑定**（MAC → 固定 IP） |

**附带白捡的好处**：设备被 DNAT 到 ADH 时**源 IP 被完整保留**，所以 ADH 现在能看到**真实客户端 IP**
（过去是清一色 `127.0.0.1`）。查询日志、`ratelimit` 从此都准了。

---

## 二、加一台设备只要三步

```sh
# 1. 设备先连上 Wi-Fi，查它叫什么、IP 是多少
adhfilter devices

# 2. 绑定固定 IP（关键！否则 IP 一变规则就失效）
adhfilter bind iPhone          # 也可以用 IP: adhfilter bind 192.168.1.106

# 3. 加入过滤
adhfilter add iPhone
```

删掉：`adhfilter del iPhone` → 该设备恢复默认放行。

---

## 三、`adhfilter` 工具（已装在从机 `/usr/bin/adhfilter`）

| 命令 | 作用 |
|---|---|
| `adhfilter devices` | 列出所有有过租约的设备：**IP / 设备名 / MAC / 是否已被过滤 / 是否在线** |
| `adhfilter list` | 只列当前被过滤的设备，并显示 IP 锚 / MAC 锚是否完好 |
| `adhfilter bind <IP\|名称>` | 静态绑定固定 IP（自动读 MAC 和主机名） |
| `adhfilter add <IP\|名称>` | 加入色情过滤（**自动同时建 IP 锚 + MAC 锚**） |
| `adhfilter del <IP\|名称>` | 移出过滤（恢复放行，两条锚一起删） |
| `adhfilter resync <IP\|名称>` | **设备换 MAC 后**按当前租约刷新两条锚 |
| `adhfilter check` | 四项自检：IP 锚 / MAC 锚 / dnsmasq 是否已摘除 ADH / ADH 5335 是否在听 |

> 参数支持**设备名**（大小写不敏感）或直接给 IP。

### 为什么要两条锚？
`fw3` 的 `redirect` **也支持按 MAC 匹配**（`--mac-source`，实测确认）。所以每台设备下两条规则互相兜底：

```
-A zone_lan_prerouting -p tcp --dport 53 -m mac --mac-source f8:c3:cc:16:f2:f7 -j DNAT --to 192.168.3.1:5335   ← MAC 锚
-A zone_lan_prerouting -s 192.168.1.106/32 -p tcp --dport 53                  -j DNAT --to 192.168.3.1:5335   ← IP 锚
```

- 静态绑定丢了、设备拿到地址池里别的 IP → **MAC 锚仍然把它拽进 ADH**；
- 设备换了 MAC → **重跑 `adhfilter resync` 即可**，IP 锚在绑定更新后照样生效；
- 只有「MAC 变了 **且** 没重新绑定」才会裸奔。

> ✅ **2026-09-27 16:22 已实机验证 MAC 锚**：iPhone 关掉"私有 Wi-Fi 地址"换 MAC 后，因静态绑定还挂在旧 MAC 上，
> 它掉到了地址池的 `192.168.1.106`。此时**只有 MAC 锚能匹配它**——ADH 日志里随即出现了来自 `192.168.1.106`
> 的查询记录，证明 MAC 锚**独立生效**、设备**一刻没有裸奔**。
> 随后已把绑定改回 `新MAC → 192.168.1.106`，并删除失效的旧随机 MAC 锚。

#### 换 MAC 的标准处置流程（三分钟）
```sh
# ① 先加新 MAC 锚兜住（此刻设备可能已掉到别的 IP，且旧 IP 锚不再匹配）
# ② 重建静态绑定：改 dhcp.KidHost_<IP> 的 mac 字段为新 MAC
# ③ 删掉失效的旧 MAC 锚：uci -q delete firewall.KidADHM_<旧MAC下划线>
# ④ 清 /tmp/dhcp.leases 里旧 MAC / 旧 IP 的行，重启 dnsmasq
# ⑤ 让设备在 Wi-Fi 设置里关一下再开一下（强制重新 DHCP，拿回原 IP）
# ⑥ adhfilter check 确认两条锚都在
```
> 不做 ⑤ 的话，设备会一直用旧租约里的 IP 直到续约（可能数小时）。
> 但**因为有 MAC 锚，这段时间过滤照样生效**，不用紧张。

---

## 四、图形界面等价操作

| 想做的 | LuCI 位置 |
|---|---|
| 看设备叫什么、IP 多少 | **状态 → 概览 → DHCP 租约**（或 网络 → DHCP/DNS → 已分配租约） |
| 绑定固定 IP | **网络 → DHCP/DNS → 静态地址分配**，填 MAC + IP + 名称 |
| 加过滤规则 | **网络 → 防火墙 → 端口转发**（⚠️ 不是"通信规则"） |

⚠️ 端口转发的表单里"**内部区域**"建议留空；这类 DNAT 用命令行（`adhfilter`）更稳。

---

## 五、⚠️ 五个必须知道的坑

### 1. `src_ip` 绝对不能写多个 IP（最凶险）
`uci set ...src_ip="192.168.1.106 192.168.3.193"` **不会报错**，但 fw3 会**把整条源地址限制丢掉**，
规则退化成"**所有 LAN 设备**"——你以为只拦了孩子，其实全屋都被拽进 ADH。
**一台设备一条规则**。`adhfilter check` 就是专门抓这个的。

### 2. 规则里不能设"目标区域"
不设 `dest` 才能同时抓住"查路由器自身的 53"和"查外网 53"两种流量。
只写 `dest=wan` 会让"把 DNS 改成 8.8.8.8"的设备漏掉。

### 3. 规则必须排在 `Force-DNS-to-Router` 之前
否则被全屋劫持规则抢先，名单形同虚设。`adhfilter add` 已内置 `uci reorder ...=0`。

### 4. MAC 随机化 = 方案 B 的最大风险点
macOS / iOS 默认对每个 Wi-Fi 开"**私有 Wi-Fi 地址**"，MAC 会变 → 静态绑定失效 → IP 漂移。
现在有 **MAC 锚**兜底，但它**也认这个 MAC**，所以设备端把 MAC 定下来仍然是必须的。

**怎么一眼判断对方到底关了没有**（不用问，看证据）：
MAC 的**第一字节第二个 bit = 1** 就是随机化 MAC（本地管理地址），真实网卡该 bit 为 0。

| MAC 开头 | 含义 |
|---|---|
| `f6:` `02:` `72:` `de:` … | **随机化 MAC** → "私有 Wi-Fi 地址"仍开着（或设为"固定"） |
| `9c:` `dc:` `a4:` `f0:` …（真实 OUI） | 已用硬件真实 MAC → 确实关掉了 |

```sh
ip neigh show 192.168.1.106             # 看当前 MAC
grep 192.168.1.106 /tmp/dhcp.leases     # 看租约里的 MAC
```

> 关掉该开关后 iOS 会**立即重连并换 MAC**，ARP/租约表马上就能反映出来。
> 若 MAC 没变，那关的就是别的东西（见下条）。

### 5. iOS 上两个相邻开关，极容易关错 ⚠️
两个开关在**同一个「Wi-Fi 详情」页里上下相邻**，但作用完全不同：

| 开关 | 真正作用 | 影响本方案？ |
|---|---|---|
| **私有 Wi-Fi 地址**（新版叫"专用 Wi-Fi 地址"） | MAC 随机化，可选 关闭 / 固定 / 轮换 | ✅ **是**。改了要 `adhfilter resync <IP>` + 重新 `bind` |
| **限制 IP 地址跟踪** | 防止 Safari / 邮件里的已知跟踪器看到你的 IP，靠 iCloud 私密代理（**需 iCloud+**） | ❌ **否**。与 MAC、与本方案毫无关系 |

**它们不是一回事。** 没有 iCloud+ 的用户关"限制 IP 地址跟踪"基本等于没效果，也**不会**让过滤失效。

---

## 六、备份与回滚

| 项 | 位置 |
|---|---|
| 改前 firewall | `/root/firewall.bak.exp1790533600` |
| 改前 dhcp | `/root/dhcp.bak.exp1790533600` |
| 更早的 firewall | `/root/firewall.bak.exp1790533000`、`/etc/config/firewall.bak.1790488926` |

**整体回滚到"全屋过滤"（方案 A）**

```sh
uci set dhcp.cfg01411c.server='127.0.0.1#5335'
uci set dhcp.cfg01411c.noresolv='1'
uci commit dhcp
uci -q delete firewall.KidADH_192_168_1_106     # 以及其余 KidADH_* 规则
uci commit firewall
/etc/init.d/dnsmasq restart
/etc/init.d/firewall reload
```

---

## 七、以后"从机变主机"时要一起改

这台 192.168.3.1 将来会顶替成 192.168.1.1，届时以下都要跟着改：

1. `adhfilter` 脚本里的 `SELF=192.168.3.1` → `192.168.1.1`
2. 所有 `KidADH_*`（IP 锚）与 `KidADHM_*`（MAC 锚）规则里的 `dest_ip`
3. ADH 的上游（不能再指老主机 192.168.1.1）
4. `Force-DNS-to-Router` 里的 `dest_ip`
5. WAN 接入方式（当前是从老主机 DHCP 到 192.168.1.243）
6. `KidHost_*` 静态绑定**不用动**（MAC/IP 与网段无关），但若新主机网段变化则要整体改
7. 改完跑一次 `adhfilter check` 确认两条锚都在
