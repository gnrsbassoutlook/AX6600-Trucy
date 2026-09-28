#!/bin/sh
# movekid.sh —— 把孩子设备迁到一个新的固定 IP（MAC 锚自动继续生效，不用重建）
#
# 用法:  sh /tmp/movekid.sh <旧IP> <新IP> [新名字]
# 例:    sh /tmp/movekid.sh 192.168.1.121 192.168.1.106
#
# 做三件事：
#   ① 静态绑定 dhcp.KidHost_<旧IP> -> dhcp.KidHost_<新IP>（MAC/名字沿用）
#   ② 防火墙 IP 锚 KidADH_<旧IP> -> KidADH_<新IP>，并 reorder 到最前
#   ③ 清掉旧租约，手机重连时立刻拿新 IP
# MAC 锚 KidADHM_<MAC> 与 MAC 绑定，换 IP 不受影响。

OLDIP="${1:-}"
NEWIP="${2:-}"
NAME="${3:-}"
SELF=192.168.1.1
ADHPORT=5335

[ -z "$OLDIP" ] || [ -z "$NEWIP" ] && { echo "用法: sh movekid.sh <旧IP> <新IP> [新名字]"; exit 1; }

OH="KidHost_$(echo "$OLDIP" | tr . _)"
NH="KidHost_$(echo "$NEWIP" | tr . _)"
OS="KidADH_$(echo "$OLDIP" | tr . _)"
NS="KidADH_$(echo "$NEWIP" | tr . _)"

MAC="$(uci -q get dhcp.$OH.mac)"
[ -z "$MAC" ] && { echo "!! 找不到旧绑定 dhcp.$OH（或它没有 MAC 字段）"; exit 1; }
[ -z "$NAME" ] && NAME="$(uci -q get dhcp.$OH.name)"
# 名字净化：只能 [A-Za-z0-9_-]，否则 dnsmasq 会崩溃 -> 全屋断网
# ⚠️ 必须用 tr -cd（删除非法字符），不要用 tr -c ... '_'：
#    echo 会附一个换行，tr -c 会把换行也换成 '_'，名字尾部就多一个下划线。
NAME="$(printf '%s' "$NAME" | tr -cd 'A-Za-z0-9_-' | cut -c1-20)"
[ -z "$NAME" ] && NAME=device

TS=$(date +%s)
cp /etc/config/dhcp /root/dhcp.bak.move$TS
cp /etc/config/firewall /root/firewall.bak.move$TS
echo "备份: /root/dhcp.bak.move$TS   /root/firewall.bak.move$TS"
echo "迁移: $OLDIP  ->  $NEWIP    名字=$NAME   MAC=$MAC"

# ---------- ① 静态绑定 ----------
uci -q delete dhcp.$NH
uci set dhcp.$NH=host
uci set dhcp.$NH.name="$NAME"
uci set dhcp.$NH.mac="$MAC"
uci set dhcp.$NH.ip="$NEWIP"
uci -q delete dhcp.$OH
uci commit dhcp

# ---------- ② 防火墙 IP 锚 ----------
uci -q delete firewall.$NS
uci set firewall.$NS=redirect
uci set firewall.$NS.name="$NS"
uci set firewall.$NS.src='lan'
uci set firewall.$NS.src_ip="$NEWIP"
uci set firewall.$NS.proto='tcp udp'
uci set firewall.$NS.src_dport='53'
uci set firewall.$NS.dest_ip="$SELF"
uci set firewall.$NS.dest_port="$ADHPORT"
uci set firewall.$NS.target='DNAT'
uci set firewall.$NS.enabled='1'
uci -q delete firewall.$OS
uci commit firewall
uci reorder firewall.$NS=0
uci commit firewall

# ---------- ③ 清旧租约，让设备重连立刻拿新 IP ----------
if [ -f /tmp/dhcp.leases ]; then
  grep -v "$MAC" /tmp/dhcp.leases > /tmp/dhcp.leases.tmp 2>/dev/null
  cat /tmp/dhcp.leases.tmp > /tmp/dhcp.leases
  rm -f /tmp/dhcp.leases.tmp
fi

# ---------- 生效 ----------
/etc/init.d/dnsmasq restart >/dev/null 2>&1
/etc/init.d/firewall reload  >/dev/null 2>&1

echo "--- 校验（等规则落表）---"
i=0
while [ $i -lt 15 ]; do
  if iptables -t nat -S 2>/dev/null | grep -q -- "-s $NEWIP/32.*dport 53"; then break; fi
  sleep 1; i=$((i+1))
done

echo "[静态绑定]"
uci show dhcp 2>/dev/null | grep KidHost
echo "[IP 锚]"
iptables -t nat -S 2>/dev/null | grep -- "-s $NEWIP/32"
echo "[MAC 锚]"
iptables -t nat -S 2>/dev/null | grep -- "--mac-source $MAC"
echo "[顺序] 名单规则是否在 Force-DNS-to-Router 之前："
iptables -t nat -S PREROUTING 2>/dev/null | grep -n "zone_lan_prerouting"
iptables -t nat -L zone_lan_prerouting -n --line-numbers 2>/dev/null | grep -E "Kid|Force" | head -8

echo "--- dnsmasq 存活 ---"
if nslookup 127.0.0.1 >/dev/null 2>&1 || netstat -ln 2>/dev/null | grep -q ":53 "; then
  echo "OK  53 端口在服务"
else
  echo "!! 53 端口无监听，检查 logread | grep -i dnsmasq"
fi
