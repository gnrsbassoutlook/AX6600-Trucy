#!/bin/sh
# set_adh_upstream.sh —— 把 ADH 的上游从"纯国内 DNS"改成"本机分流 DNS(chinadns-ng)"
#
# 为什么：ADH 上游写 223.5.5.5 时，名单设备解析被墙域名(GitHub 尚可，Google/HuggingFace/YouTube)
#         会拿到污染/异常 IP；改成 127.0.0.1:5333 后，ADH 继承 ssr-plus 的 DNS 分流：
#           国内域名 -> 223.5.5.5    国外域名 -> dns2tcp(经梯子) 8.8.8.8
#         于是名单设备"既被色情过滤，又能正常出海"。
# 影响面：只有 DNS 查询会进到 ADH 的设备（即名单设备，如 192.168.1.106）受影响。
#         其他设备走 dnsmasq -> chinadns-ng，完全不经过 ADH，零影响。
#
# 只改 upstream_dns 的第一条，其他字段(bootstrap/fallback/端口/ratelimit/aaaa/blocked_hosts)一律不动。

CONF=/etc/AdGuardHome.yaml
NEW='127.0.0.1:5333'
BIN=/usr/bin/AdGuardHome/AdGuardHome
TS=$(date +%s)
BAK1=/root/AdGuardHome.yaml.bak.up$TS
BAK2=/root/AdGuardHome.bin.bak.up$TS

# ---- 前置检查 ----
netstat -ln 2>/dev/null | grep -q "127.0.0.1:5333" || { echo "!! chinadns-ng 没在 127.0.0.1:5333 监听，中止（否则 ADH 会失去上游）"; exit 1; }
[ -f "$CONF" ] || { echo "!! 找不到 $CONF"; exit 1; }
grep -q "^  upstream_dns:" "$CONF" || { echo "!! 在 $CONF 里找不到 upstream_dns 段"; exit 1; }

cp "$CONF" "$BAK1" && cp "/usr/bin/AdGuardHome/AdGuardHome" "$BAK2" 2>/dev/null
echo "备份: $BAK1  $BAK2"

echo "--- 改前 ---"
grep -n -A4 '^  upstream_dns:' "$CONF"

# ---- 只替换 upstream_dns 下的条目 ----
awk -v new="$NEW" '
  /^  upstream_dns:[[:space:]]*$/ { print; inblk=1; done=0; next }
  inblk==1 {
    if ($0 ~ /^    - /) { if (done==0) { print "    - " new; done=1 } ; next }
    inblk=0
  }
  { print }
' "$CONF" > /tmp/adh.yaml.new

grep -q -- "- $NEW" /tmp/adh.yaml.new || { echo "!! 替换没写进去，中止"; rm -f /tmp/adh.yaml.new; exit 1; }
A=$(wc -l < "$CONF"); B=$(wc -l < /tmp/adh.yaml.new)
echo "行数: $A -> $B（必须相等）"
[ "$A" != "$B" ] && { echo "!! 行数变了，中止"; rm -f /tmp/adh.yaml.new; exit 1; }

# ---- 停机 / 换配置 / 校验 / 起机 ----
/etc/init.d/AdGuardHome stop >/dev/null 2>&1
sleep 2
cp /tmp/adh.yaml.new "$CONF"

CHK=$("$BIN" --check-config -c "$CONF" 2>&1)
echo "check-config: $CHK"
case "$CHK" in
  *[Ii]nvalid*|*[Ee]rror*)
     echo "!! 配置校验失败，回滚"
     cp "$BAK1" "$CONF"
     /etc/init.d/AdGuardHome start >/dev/null 2>&1
     exit 1;;
esac

/etc/init.d/AdGuardHome start >/dev/null 2>&1

echo "--- 改后 ---"
grep -n -A4 '^  upstream_dns:' "$CONF"

echo "--- 等 5335 重新监听（93 万条规则要 60~80 秒）---"
i=0
while [ $i -lt 180 ]; do
  netstat -ln 2>/dev/null | grep -q ":5335" && { echo "OK 5335 已监听（等了 ${i}s）"; break; }
  sleep 3; i=$((i+3))
done
if ! netstat -ln 2>/dev/null | grep -q ":5335"; then
  echo "!! 5335 一直没起来，回滚配置并重启"
  cp "$BAK1" "$CONF"
  /etc/init.d/AdGuardHome restart >/dev/null 2>&1
  exit 1
fi

echo "--- dnsmasq 是否被动过（应该有 53 监听、且不含 5335 指向）---"
netstat -ln 2>/dev/null | grep ":53 " | head -3
grep -rh "^server=127.0.0.1#5335" /tmp/dnsmasq.d/ 2>/dev/null && echo "!! dnsmasq 被写回了 5335 指向（方案 B 被破坏）" || echo "OK dnsmasq 没被写回 ADH 指向"
