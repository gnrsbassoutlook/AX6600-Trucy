#!/bin/sh
# luci-app-adhfilter 一键卸载
#
# 只删「界面」相关的文件，**不动**已经设好的过滤规则
# （firewall 里的 KidADH_* / KidADHM_* 锚点、dhcp 里的 KidHost_* 静态绑定一律保留）。
# 要连过滤一起撤，用 `adhfilter del <IP>`。

set -e

echo "== 卸载 luci-app-adhfilter =="

rm -f  /usr/lib/lua/luci/controller/adhfilter.lua
rm -rf /usr/lib/lua/luci/model/cbi/adhfilter
rm -rf /usr/lib/lua/luci/view/adhfilter
rm -f  /etc/config/adhfilter
rm -f  /usr/share/rpcd/acl.d/luci-app-adhfilter.json

# 备注（自定义标签）。只有界面能读写它，留着就是一份没主的数据 → 一并删掉。
rm -f  /etc/adhfilter.labels

# LuCI 缓存不删不生效
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
/etc/init.d/uhttpd restart >/dev/null 2>&1

echo "  已删除（菜单项会在下次刷新/重登后消失）"
echo "  保留：firewall 里的过滤锚点、dhcp 里的静态绑定"
echo "  工具 /usr/bin/adhfilter 也保留（命令行照旧可用）"
