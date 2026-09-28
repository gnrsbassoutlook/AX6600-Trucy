#!/bin/sh
# migrate-host.sh --- 从机 192.168.3.1 扶正为主机 192.168.1.1 之后的配置迁移
#
#   预览(默认, 不改任何东西):   sh /usr/bin/migrate-host.sh
#   真正执行:                   sh /usr/bin/migrate-host.sh --apply
#
# 做五件事:
#   1) adhfilter 里的 SELF  改成 192.168.1.1
#   2) 防火墙所有 dest_ip=192.168.3.1 改成 192.168.1.1
#   3) IP 锚 KidADH_192_168_3_x 的 src_ip 改成 192.168.1.x, 段名同步重命名
#   4) 静态绑定 KidHost 的 ip 改成 192.168.1.x, 段名同步重命名
#   5) ADH 上游 192.168.1.1(原主机,已撤走) 改成公共 DNS
#
# 前提: 已在 LuCI 里把 LAN 的 IPv4 地址改成 192.168.1.1 且已能上网
# 不动: WAN 接入方式 / 梯子 / 包装 / 过滤表(与 IP 无关, 自动照旧)

OLD=192.168.3
NEW=192.168.1
SELF=$NEW.1
OLDMASTER=192.168.1.1
UP_NEW=223.5.5.5
APPLY=0
[ "$1" = "--apply" ] && APPLY=1
TS=$(date +%s)
OLDUS=$(echo $OLD | tr . _)
NEWUS=$(echo $NEW | tr . _)

say() { echo "$@"; }
run() { if [ "$APPLY" = "1" ]; then sh -c "$1"; else echo "  [预览] $1"; fi; }
redir() { uci show firewall 2>/dev/null | grep "=redirect" | cut -d. -f2 | cut -d= -f1; }

CUR=$(uci -q get network.lan.ipaddr)
say "当前 LAN : $CUR"
say "目标 LAN : $SELF"
if [ "$APPLY" = "1" ]; then say "模式     : 执行"; else say "模式     : 仅预览(不改动)"; fi
say ""
if [ "$CUR" != "$SELF" ]; then
  say "!! 警告: LAN 当前不是 $SELF"
  say "   请先在 LuCI 里把 LAN 的 IPv4 地址改成 $SELF 并应用, 再跑本脚本"
  [ "$APPLY" = "1" ] && exit 1
  say ""
fi

say "== 0) 备份 =="
for f in firewall dhcp network; do run "cp /etc/config/$f /root/$f.premig.$TS"; done
run "cp /etc/AdGuardHome.yaml /root/AdGuardHome.premig.$TS"
say "   -> /root/*.premig.$TS"
say ""

say "== 1) adhfilter 的 SELF =="
run "sed -i s#^SELF=.*#SELF=$SELF# /usr/bin/adhfilter"
say "   SELF=$SELF"
say ""

say "== 2) 防火墙 dest_ip =="
N=0
for s in $(redir); do
  D=$(uci -q get firewall.$s.dest_ip)
  if [ "$D" = "$OLD.1" ]; then
    say "   $s : dest_ip -> $SELF"
    run "uci set firewall.$s.dest_ip=$SELF"
    N=$((N + 1))
  fi
done
say "   共 $N 处"
say ""

say "== 3) IP 锚 src_ip + 段名 =="
for s in $(redir); do
  case "$s" in KidADH_*) ;; *) continue ;; esac
  IP=$(uci -q get firewall.$s.src_ip)
  case "$IP" in $OLD.*) ;; *) say "   $s ($IP) 已在新网段, 跳过"; continue ;; esac
  LAST=${IP##*.}
  NIP=$NEW.$LAST
  NS=KidADH_${NEWUS}_$LAST
  say "   $IP -> $NIP   ($s -> $NS)"
  run "uci rename firewall.$s=$NS"
  run "uci set firewall.$NS.src_ip=$NIP"
done
say ""

say "== 4) 静态绑定 ip + 段名 =="
for s in $(uci show dhcp 2>/dev/null | grep "=host" | cut -d. -f2 | cut -d= -f1); do
  IP=$(uci -q get dhcp.$s.ip)
  case "$IP" in $OLD.*) ;; *) continue ;; esac
  LAST=${IP##*.}
  NIP=$NEW.$LAST
  NS=$(echo "$s" | sed "s#_${OLDUS}_#_${NEWUS}_#")
  say "   $IP -> $NIP   ($s)"
  run "uci set dhcp.$s.ip=$NIP"
  if [ "$NS" != "$s" ]; then run "uci rename dhcp.$s=$NS"; fi
done
say ""

say "== 5) ADH 上游 $OLDMASTER -> $UP_NEW =="
if grep -q -- "- $OLDMASTER" /etc/AdGuardHome.yaml 2>/dev/null; then
  say "   找到上游行, 将替换"
  run "/etc/init.d/AdGuardHome stop"
  run "sed -i 's|^ *- *$OLDMASTER\$|    - $UP_NEW|' /etc/AdGuardHome.yaml"
  run "grep -n -A3 ^upstream_dns: /etc/AdGuardHome.yaml"
else
  say "   未找到 - $OLDMASTER 行, 跳过(可能已改过)"
fi
say ""

say "== 6) WAN 上游 DNS 显式指定 =="
# 为什么必须做: 光猫管理地址与新主机 LAN 同网段(都在 192.168.1.0/24),
# 内核里 192.168.1.0/24 的直连路由会优先走 br-lan, 导致路由器"路由不到"光猫 192.168.1.254,
# dnsmasq 用它当上游会超时(目前是靠 IPv6 DNS 兜着解析的, 很脆)。
say "   当前: peerdns=$(uci -q get network.wan.peerdns) dns=$(uci -q get network.wan.dns)"
run "uci set network.wan.peerdns=0"
run "uci set network.wan.dns='$UP_NEW 119.29.29.29'"
run "uci commit network"
say "   -> network.wan.dns = $UP_NEW 119.29.29.29"
say ""

say "== 7) 提交并生效 =="
run "uci commit firewall"
run "uci commit dhcp"
run "/etc/init.d/firewall reload >/dev/null 2>&1"
run "/etc/init.d/dnsmasq restart >/dev/null 2>&1"
run "/etc/init.d/AdGuardHome start"
if [ "$APPLY" = "1" ]; then
  say "   等 75 秒让 93 万条规则加载完..."
  sleep 75
  say ""
  /usr/bin/adhfilter devices
  echo
  /usr/bin/adhfilter check
  echo
  say "== 完成. 若 check 出现 BAD, 跑: adhfilter resync <设备IP> =="
else
  say ""
  say "预览结束. 确认无误后执行:   sh /usr/bin/migrate-host.sh --apply"
fi
