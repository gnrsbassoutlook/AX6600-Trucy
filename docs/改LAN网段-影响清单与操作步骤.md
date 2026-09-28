# 把主机 LAN 从 `192.168.1.1` 改成别的网段 —— 影响清单与操作步骤

> 结论先说：**能改，但不是零操作。**
> 路由器上的「核心三件套」——**ADH 本体、梯子 DNS 链、LuCI 插件**——都**不用进后台改**，
> 真正要手改的只有 **3 处 `firewall` 里的 `dest_ip`** 和 **静态租约里的 IP**。
>
> 本文基于 2026-09-28 对主机 `192.168.1.1` 的**实机配置审计**逐项核对，不是推测。

---

## 一、一句话回答「ADH 本体要不要在后台再设置？」

**不要。** 逐项证据如下（都是 `192.168.1.1` 上读出来的实际值）：

| ADH 配置项 | 实际值 | 换网段会怎样 |
|---|---|---|
| `dns.bind_hosts` | `0.0.0.0` | 通配监听，**自动跟**所有接口 |
| `http.address` | `0.0.0.0:3000` | 通配，**自动跟**；面板地址变成 `http://<新IP>:3000` |
| `dns.port` | `5335` | 只跟端口有关，与网段无关 |
| `allowed_clients` | `[]` | 空 = 不限制来源，**自动跟** |
| `disallowed_clients` | `[]` | 空 |
| `clients.persistent` | `[]` | **没有按 IP 给孩子设备单独配过东西** → 无需迁移 |
| 上游 DNS | `127.0.0.1:5333`（chinadns-ng） | 回环地址，与 LAN 段无关 |
| `ratelimit_whitelist` | `127.0.0.1` / `::1` | 回环，无关 |
| 6 张过滤表 | 全部是**域名黑名单**（URL 形态） | 按域名匹配，**跟设备 IP 无关** |

唯一的「按设备区分」的规则长这样（就在你那个 `Justin-Block-URL.txt` 里）：

```
||bilibili.com^$client='Justin_iPhone'
```

注意 `$client=` 后面跟的是**客户端名字**，不是 IP —— 所以**换网段也不受影响**。

> ⚠️ 反过来提一句：这条规则的生效前提是 ADH 能把你的 iPhone 识别成 `Justin_iPhone` 这个名字。
> 路由器侧的 dnsmasq 静态绑定名字是 `Kids-iPhone`（你自己起的），设备自报是 `Justin-iPhone`。
> ADH 的客户端识别走 `dhcp: true` 这个运行时来源，到底取到哪一个，值得你哪天在
> ADH 面板 → 客户端列表 里核对一次。**这不是换网段引入的问题，是原本就存在的隐患。**

---

## 二、逐项影响清单

### A. 你必须手改的（漏一个就出故障）

| # | 位置 | 现在的值 | 改成 | 不改的后果 |
|---|---|---|---|---|
| 1 | `network.lan.ipaddr` | `192.168.1.1` | 新 IP | —— 这就是「改 LAN IP」本身 |
| 2 | `firewall.KidADH_<ip>.dest_ip` | `192.168.1.1` | 新 IP | **孩子 DNS 被 DNAT 送到不存在的地址 → 孩子完全上不了网** |
| 3 | `firewall.KidADHM_<mac>.dest_ip` | `192.168.1.1` | 新 IP | 同上（MAC 锚是兜底的那条，更隐蔽） |
| 4 | `firewall` 中 `name=Force-DNS-to-Router` 的 `.dest_ip` | `192.168.1.1` | 新 IP | 所有设备的强制 DNS 失效 |
| 5 | `dhcp.KidHost_<ip>.ip` | `192.168.1.106` | 新段同末位 | dnsmasq 忽略该静态租约，孩子设备变随机 IP |
| 6 | 段名 `KidHost_192_168_1_106` / `KidADH_192_168_1_106` | 含旧 IP | 同步改名 | **段名是 adhfilter 用来定位的**；不改名的话以后 `adhfilter del <新IP>` 会找不到旧段 → **规则变孤儿，孩子永远解不掉过滤** |

> 第 6 项是最容易被忽略、后果最烦的一条。段名看着只是「名字」，但
> `adhfilter` 的 `del` / `resync` 是按 `KidHost_$(echo $IP | tr . _)` 去拼段名的。
> 迁移脚本已经帮你一并改名。

### B. 完全不用动的（自动跟随）

| 位置 | 为什么不用动 |
|---|---|
| ADH 本体 | 见第一节，全部通配或回环 |
| `chinadns-ng` / `dns2tcp` / `v2ray` | 全部 `127.0.0.1` |
| `dnsmasq` | 只有 `port=53`，没有 `listen_address`，自动跟 br-lan |
| `dnsmasq` 上游 | 有 `no-resolv` + `server=127.0.0.1#5333`（梯子接管），与网段无关 |
| `LuCI 插件 adhfilter.lua` | `SELF=$(uci -q get network.lan.ipaddr)` **动态读** |
| `/usr/bin/adhfilter` 脚本 | 同上，动态读 + 兜底 |
| LuCI 前端 `main.htm` | API 走相对路径，显示用的 `status.lan_ip` 是接口动态返回的 |
| `appfilter`（OAF） | 配置里没有任何 `192.168.x` |
| `uhttpd` | 配置里没有任何 `192.168.x` |
| 副路由器 `192.168.3.1` | WAN 是 dhcp，会自己重新拿新段的地址；它自己的 ADH 锚点指向 `192.168.3.1`（自己的 LAN），不受影响 |

### C. 视情况（你可能用了，也可能没用）

| 位置 | 现在 | 说明 |
|---|---|---|
| `/etc/config/openvpn` | `push 'dhcp-option DNS 192.168.1.1'`<br>`push 'route 192.168.1.0 255.255.255.0'` | **只有你在用 OpenVPN 服务器**给外部设备拨进来时才要改。没用就放着 |
| `/etc/config/eqos` | `# option ip "192.168.1.100"` | 是**注释行**，无影响 |

### D. 路由器之外的东西（别忘了）

| 对象 | 要做的事 |
|---|---|
| **你这台 Mac** | `en0` 现在是 `192.168.1.112`，得改成新段（或改成 DHCP） |
| 副路由器的管理访问 | 我远程操作副路由器时用的源地址 `192.168.3.193` 会变，`wssh.exp` 的第四个参数要跟着换 |
| 所有智能家居设备 | 会掉线几秒重新 DHCP 拿新 IP，属正常 |
| 任何手工设了静态 IP 的设备 | 都要改 |

---

## 三、改完之后的直接后果

1. **孩子设备 IP 全变**（DHCP 池从 `192.168.1.100-249` 变成新段同位置），
   但**过滤不会断** —— 因为每台设备都有 **MAC 锚**兜着。
   顺便说：这正是当初做「双锚」的价值，日常看不出，这种时候才显出来。
   > 唯一要注意：静态租约没了之后，孩子设备可能拿到池里的随机 IP，**不影响过滤**，但 IP 会变来变去。
   > 迁移脚本会把静态租约一起搬过去，避免这个情况。
2. **ADH 面板地址变成 `http://<新IP>:3000`**，记一下。
3. ⭐ **白捡的好处：光猫的网段重叠问题自动消失。**
   光猫是 `192.168.1.254`，和主机 LAN 同段时内核只认 LAN 直连路由，导致**内网路由不到光猫**（ping 不通）。
   把 LAN 换成 `192.168.2.1` 之后，WAN 仍在 `192.168.1.x`、LAN 在 `192.168.2.x`，
   两条路由不再打架 —— **以后能正常打开光猫管理页了**。
4. WAN 口地址不变（还是光猫发的 `192.168.1.72`），**外网访问不受影响**。

---

## 四、操作步骤

> ⚠️ **前提**：先备份。改 LAN IP 必然导致 SSH 断线，你会从 Mac 侧用新 IP 重连。

### 方式一：用脚本（推荐，已内置备份 + 重排 + 自检）

把 `change-lan-ip.sh` 传到路由器，然后：

```sh
# 1) 先预览，确认它要改的东西和你预期一致（什么都不写）
sh /root/change-lan-ip.sh 192.168.2.1

# 2) 确认无误后执行
sh /root/change-lan-ip.sh 192.168.2.1 --apply
```

脚本会：备份 → 改 5 类值 → 一次 commit → reload 网络 → 打印自检命令。
SSH 会在 reload 时断开，这是正常的。

**回滚**：脚本会告诉你备份目录，直接 `sh /root/change-lan-ip.sh --restore /root/lanip-backup-<时间戳>`。

### 方式二：手动（等效命令）

```sh
NEW=192.168.2.1
OLD_SEG=192.168.1
NEW_SEG=192.168.2

mkdir -p /root/lanip-backup
cp /etc/config/network /etc/config/firewall /etc/config/dhcp /root/lanip-backup/

# ① LAN IP
uci set network.lan.ipaddr=$NEW

# ② 三条 redirect 的 dest_ip（两条锚 + 强制DNS）
for S in $(uci show firewall | grep '=redirect' | cut -d. -f2 | cut -d= -f1); do
  case "$(uci -q get firewall.$S.name)" in
    Force-DNS-to-Router|KidADH_*|KidADHM_*) uci set firewall.$S.dest_ip=$NEW ;;
  esac
done

# ③ 静态租约搬段 + 段名改名
for H in $(uci show dhcp | grep '=host' | cut -d. -f2 | cut -d= -f1 | grep '^KidHost_'); do
  IP=$(uci -q get dhcp.$H.ip)
  case "$IP" in
    $OLD_SEG.*)
      NIP="$NEW_SEG.$(echo "$IP" | cut -d. -f4)"
      NH="KidHost_$(echo "$NIP" | tr . _)"
      uci set dhcp.$NH=host
      uci set dhcp.$NH.name="$(uci -q get dhcp.$H.name)"
      uci set dhcp.$NH.mac="$(uci -q get dhcp.$H.mac)"
      uci set dhcp.$NH.ip="$NIP"
      [ "$NH" != "$H" ] && uci -q delete dhcp.$H ;;
  esac
done

# ④ IP 锚段名跟着 src_ip 改名
for S in $(uci show firewall | grep '=redirect' | cut -d. -f2 | cut -d= -f1 | grep '^KidADH_'); do
  IP=$(uci -q get firewall.$S.src_ip)
  case "$IP" in
    $OLD_SEG.*)
      NIP="$NEW_SEG.$(echo "$IP" | cut -d. -f4)"
      NS="KidADH_$(echo "$NIP" | tr . _)"
      [ "$NS" != "$S" ] && uci rename firewall.$S=$NS ;;
  esac
done

# ⑤ 一次提交（避免中间态出现"DNS 指向黑洞"）
uci commit network; uci commit firewall; uci commit dhcp

# ⑥ 生效
/etc/init.d/network reload
```

### ⑥ 之后：立刻做的 4 项验证

```sh
# Mac 侧（路由器上没有 dig）：把 <新IP> 换成实际值
dig +short @192.168.2.1 -p 5335 pornhub.com A     # 期望: 0.0.0.0  ← 过滤在工作
dig +short @192.168.2.1 -p 5335 google.com A      # 期望: 真实 IP  ← 非黑名单放行
dig +short @192.168.2.1 pornhub.com A             # 非名单设备走的 dnsmasq，期望: 真实 IP
```

```sh
# 路由器上
adhfilter check          # 期望: == 全部正常 ==
adhfilter list           # 看两台锚是否都 IP:OK MAC:OK
uci show firewall | grep 192.168.1.1    # 期望: 只剩 openvpn 那两行（如果你没用 VPN，应完全为空）
```

> 🔴 **验证 ADH 的坑（踩过）**：**必须从 Mac 打路由器的 LAN 地址** `dig @<新IP> -p 5335`。
> 千万不要在路由器本地做 `REDIRECT --to-ports 5335` 再 `nslookup 127.0.0.1`，
> 因为 `127.0.0.1:5335` 上是梯子的 `dns2tcp`（不是 ADH），包会被送给它，
> 色情站会返回真实 IP —— 看起来像「过滤全挂」，而且包计数还正常递增，极易误判。
> 路由器上也没有 `dig`，BusyBox 的 `nslookup` 不支持 `-port=`。

---

## 五、建议

- **改之前先想清楚新网段**：`192.168.2.1` 可以；`10.0.0.1` 也行，
  但注意 `adhfilter` 脚本里的 `resolve()` 用 `case "$1" in 192.168.*)` 判断「这是不是一个 IP」，
  换成 `10.x` 之后按 IP 操作时会退化。**选 `192.168.x.1` 最省事。**
- **别在同一次操作里同时改网段和别的东西**。网段迁移本身就要断线、要重新 DHCP，混着改出了故障不好定位。
- 真正的语法安全检查：`network.lan.netmask` 是 `255.255.255.0`，新 IP 保持前三段一致才对应得上。
- 光猫那边顺便：既然网段分开了，可以的话把**光猫的 WiFi 关掉**（孩子连上光猫 WiFi 就绕过 ADH 了）。

---

*本文基于 2026-09-28 主机实机审计生成。执行前请再跑一次预览模式核对。*
