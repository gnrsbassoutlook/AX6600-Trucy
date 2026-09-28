#!/bin/sh
# change-lan-ip.sh — 把本机 LAN 整体迁到新网段（含 adhfilter 过滤锚点同步）
#
# 在路由器上执行：
#   sh change-lan-ip.sh                       预览：只打印要改什么，一个字都不写
#   sh change-lan-ip.sh 192.168.2.1 --apply   真正执行
#   sh change-lan-ip.sh --restore <备份目录>   回滚到备份状态
#
# 本脚本改 5 类东西，全部在一次 uci commit 里提交
# （不留"孩子 DNS 被 DNAT 到黑洞"的中间窗口）：
#   1) network.lan.ipaddr                            -> 新 IP
#   2) firewall KidADH_*    .dest_ip                 -> 新 IP   （IP 锚）
#   3) firewall KidADHM_*   .dest_ip                 -> 新 IP   （MAC 锚）
#   4) firewall name=Force-DNS-to-Router .dest_ip    -> 新 IP
#   5) dhcp.KidHost_*  .ip 前三段 -> 新段（末位不变），并把段名一起改名
#   6) firewall KidADH_* 段名跟着 src_ip 改名
#      ★ 第 6 条必须做：段名是 adhfilter 定位规则用的，
#        不改名的话以后 `adhfilter del <新IP>` 找不到旧段 -> 规则变孤儿 -> 设备永远解不掉过滤
#
# 明确**不动**的东西（它们跟 LAN 网段无关，已在主机上逐项核对）：
#   ADH 本体：bind_hosts=0.0.0.0 / http 0.0.0.0:3000 / port 5335 /
#             上游 127.0.0.1:5333 / allowed_clients 空 / clients.persistent 空
#   chinadns-ng、dns2tcp、v2ray、dnsmasq、LuCI 插件 adhfilter（动态读 network.lan.ipaddr）
#
# 用法说明与影响清单见同目录：改LAN网段-影响清单与操作步骤.md

set -u

APPLY=0
NEW="$1"
BAK=""

# ---------- 参数解析 ----------
case "${1:-}" in
  --restore)
    BAK="${2:-}"
    [ -z "$BAK" ] && { echo "用法: sh $0 --restore <备份目录>"; exit 1; }
    [ -d "$BAK" ] || { echo "!! 备份目录不存在: $BAK"; exit 1; }
    for f in network firewall dhcp; do
      [ -f "$BAK/$f" ] || { echo "!! 备份里缺少 $f"; exit 1; }
    done
    echo "== 正在回滚 =="
    cp "$BAK/network"  /etc/config/network
    cp "$BAK/firewall" /etc/config/firewall
    cp "$BAK/dhcp"     /etc/config/dhcp
    rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
    /etc/init.d/network reload 2>/dev/null
    sleep 3
    /etc/init.d/dnsmasq restart 2>/dev/null
    /etc/init.d/firewall reload 2>/dev/null
    echo "OK 已回滚到 $BAK"
    echo "   已还原 network.lan.ipaddr = $(uci -q get network.lan.ipaddr)"
    exit 0
    ;;
esac

[ "${2:-}" = "--apply" ] && APPLY=1

case "$NEW" in
  [0-9]*.[0-9]*.[0-9]*.[0-9]*) : ;;
  *) echo "用法: sh $0 <新LAN IP> [--apply]      例: sh $0 192.168.2.1 --apply"
     echo "     sh $0                     # 预览"
     echo "     sh $0 --restore <备份目录>   # 回滚"
     exit 1 ;;
esac

OLD=$(uci -q get network.lan.ipaddr 2>/dev/null)
[ -z "$OLD" ] && { echo "!! 读不到 network.lan.ipaddr"; exit 1; }
MASK=$(uci -q get network.lan.netmask 2>/dev/null)
OLD_SEG=$(echo "$OLD" | cut -d. -f1-3)
NEW_SEG=$(echo "$NEW" | cut -d. -f1-3)
NEW_LAST=$(echo "$NEW" | cut -d. -f4)

if [ "$OLD_SEG" != "$NEW_SEG" ] && [ "$NEW_LAST" = "1" ]; then :; else
  echo "!! 新 IP 必须是「新网段的 .1」形式，例如 192.168.2.1（用 /$MASK 掩码）"
  echo "   你给的是: $NEW"
  exit 1
fi
if [ "$OLD_SEG" = "$NEW_SEG" ]; then
  echo "网段没变（$OLD_SEG -> $NEW_SEG），无需操作。"
  echo "（如果你只是想改主机在网段里的末位，直接 uci set network.lan.ipaddr=$NEW 即可）"
  exit 0
fi

echo "======================================================"
echo " LAN 网段迁移预览"
echo "   旧: $OLD   (段 $OLD_SEG.0/24)"
echo "   新: $NEW   (段 $NEW_SEG.0/24)"
echo "   模式: $([ "$APPLY" = 1 ] && echo '★ 真实执行' || echo '预览，不写入任何东西')"
echo "======================================================"
echo

change_list=""

# ---------- 1) 三条 redirect 的 dest_ip ----------
for S in $(uci show firewall 2>/dev/null | grep '=redirect' | cut -d. -f2 | cut -d= -f1); do
  NM=$(uci -q get firewall.$S.name)
  case "$NM" in
    Force-DNS-to-Router|KidADH_*|KidADHM_*)
      CUR=$(uci -q get firewall.$S.dest_ip)
      if [ "$CUR" != "$NEW" ]; then
        echo "[dest_ip] firewall.$S  ($NM)  $CUR -> $NEW"
        change_list="$change_list dest_ip:$S"
        [ "$APPLY" = 1 ] && uci set firewall.$S.dest_ip="$NEW"
      fi ;;
  esac
done

# ---------- 2) 静态租约搬段 + 段名改名 ----------
for H in $(uci show dhcp 2>/dev/null | grep '=host' | cut -d. -f2 | cut -d= -f1 | grep '^KidHost_'); do
  IP=$(uci -q get dhcp.$H.ip)
  case "$IP" in
    $OLD_SEG.*)
      NIP="$NEW_SEG.$(echo "$IP" | cut -d. -f4)"
      NH="KidHost_$(echo "$NIP" | tr . _)"
      echo "[host   ] dhcp.$H  $IP -> $NIP   (段名 $( [ "$NH" != "$H" ] && echo "$H -> $NH" || echo "不变" ))"
      change_list="$change_list host:$H"
      if [ "$APPLY" = 1 ]; then
        uci set dhcp.$NH=host
        uci set dhcp.$NH.name="$(uci -q get dhcp.$H.name)"
        uci set dhcp.$NH.mac="$(uci -q get dhcp.$H.mac)"
        uci set dhcp.$NH.ip="$NIP"
        [ "$NH" != "$H" ] && uci -q delete dhcp.$H
      fi ;;
  esac
done

# ---------- 3) IP 锚段名跟着 src_ip 改名（关键：否则 adhfilter del 会漏删） ----------
for S in $(uci show firewall 2>/dev/null | grep '=redirect' | cut -d. -f2 | cut -d= -f1 | grep '^KidADH_'); do
  IP=$(uci -q get firewall.$S.src_ip)
  case "$IP" in
    $OLD_SEG.*)
      NIP="$NEW_SEG.$(echo "$IP" | cut -d. -f4)"
      NS="KidADH_$(echo "$NIP" | tr . _)"
      if [ "$NS" != "$S" ]; then
        echo "[段名   ] firewall.$S -> $NS   (src_ip $IP -> $NIP)"
        change_list="$change_list rename:$S"
        if [ "$APPLY" = 1 ]; then
          uci set firewall.$S.src_ip="$NIP"
          uci rename firewall.$S="$NS"
        fi
      fi ;;
  esac
done

echo

if [ -z "$change_list" ]; then
  echo "没有发现需要改的带旧网段的东西。"
  echo "（只改 network.lan.ipaddr 本身）"
fi

echo "[network] network.lan.ipaddr  $OLD -> $NEW"
echo

# ---------- 预览到此为止 ----------
if [ "$APPLY" != 1 ]; then
  echo "======================================================"
  echo " 以上是预览。确认无误后执行："
  echo "   sh $0 $NEW --apply"
  echo
  echo " 执行后 SSH 会断线（网段变了），请从 Mac 侧用新 IP 重连。"
  echo "======================================================"
  exit 0
fi

# ---------- 真实执行 ----------
TS=$(date +%Y%m%d-%H%M%S)
BAKDIR="/root/lanip-backup-$TS"
mkdir -p "$BAKDIR"
cp /etc/config/network  "$BAKDIR/network"
cp /etc/config/firewall "$BAKDIR/firewall"
cp /etc/config/dhcp     "$BAKDIR/dhcp"
echo "== 备份已存到 $BAKDIR =="
echo "   回滚命令: sh $0 --restore $BAKDIR"
echo

uci set network.lan.ipaddr="$NEW"

# 一次性提交，避免中间态
uci commit network
uci commit firewall
uci commit dhcp

# 清 LuCI 缓存（插件里显示的 lan_ip 是动态取的，但缓存清一下更保险）
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache

echo "== 正在生效，SSH 即将断开 =="
/etc/init.d/firewall reload  >/dev/null 2>&1
/etc/init.d/dnsmasq restart  >/dev/null 2>&1
/etc/init.d/network reload   >/dev/null 2>&1

sleep 6

echo
echo "== 迁移后自检（在新 IP 上重连后执行） =="
echo "   adhfilter check"
echo "   adhfilter list"
echo "   uci show firewall | grep $OLD_SEG.        # 期望：为空（除非你用了 OpenVPN）"
echo
echo "== 从 Mac 侧验证 ADH 过滤（路由器上没有 dig） =="
echo "   dig +short @$NEW -p 5335 pornhub.com A    # 期望 0.0.0.0"
echo "   dig +short @$NEW -p 5335 google.com A     # 期望 真实 IP"
echo
echo "== 别忘了同步改这些（不在路由器上） =="
echo "   · 你这台 Mac 的静态 IP（en0 原为 ${OLD_SEG}.112）"
echo "   · 如果用了 OpenVPN：/etc/config/openvpn 里的 push DNS 与 route"
echo
echo "OK 迁移完成。当前 network.lan.ipaddr = $(uci -q get network.lan.ipaddr)"
