#!/bin/sh
# luci-app-openlist-assist 卸载
#
# 在路由器上执行：
#   sh uninstall.sh
#
# ★ 只删「界面 + diskctl 工具」这 5 个文件。
#   **绝不动**下面这些（它们是让 4T 盘断电后自动挂回来的关键）：
#     /root/mount-data-disk.sh
#     /root/umount-data-disk.sh
#     /etc/hotplug.d/block/99-mount-data-disk
#     /etc/rc.local 里那行挂载调用
#     /etc/config/fstab、OpenList 的存储配置、盘上的任何数据
#
#   卸掉界面之后，硬盘照样会开机自动挂上、照常给 OpenList 用。
#
#   要连挂载一起撤：
#     /root/umount-data-disk.sh --stop     # 先停 OpenList 再卸载
#   要退回 rc.local 原样，用之前备份的 /root/rc.local.bak.*

set -e

echo "== 卸载 luci-app-openlist-assist =="

rm -f  /usr/bin/diskctl
rm -f  /usr/lib/lua/luci/controller/openlist_assist.lua
rm -rf /usr/lib/lua/luci/view/openlist_assist
rm -rf /usr/lib/lua/luci/model/cbi/openlist_assist
rm -f  /usr/share/rpcd/acl.d/luci-app-openlist-assist.json

# 配置文件留着（万一以后重装，你的设置还在）。想彻底删：
#   rm -f /etc/config/openlist-assist
if [ -f /etc/config/openlist-assist ]; then
	echo "  ℹ️  保留了 /etc/config/openlist-assist（要彻底删：rm -f 它）"
fi

echo "  ℹ️  保留了 /tmp/diskctl.log（操作日志，重启自动清）"

# 清缓存，菜单才会消失
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo
echo "  已删除：diskctl、controller、view、acl"
echo "  未触碰：任何挂载配置、任何硬盘数据、OpenList 本身"
echo
echo "  确认一下硬盘还挂着："
grep -E "sd[a-z]" /proc/mounts || echo "    （当前没有 USB 盘挂载）"
echo
