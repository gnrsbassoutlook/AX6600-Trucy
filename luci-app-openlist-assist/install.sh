#!/bin/sh
# luci-app-openlist-assist 一键安装（不依赖 opkg，直接把文件铺上去）
#
# 在路由器上执行：
#   sh install.sh
#
# 只想用 ipk 的话：opkg install dist/luci-app-openlist-assist_*.ipk
# 卸载：sh uninstall.sh
#
# 前提：/usr/bin/diskctl 会被本脚本一起装好（它在 root/usr/bin/ 里）。
#       本插件**不碰**任何已有的挂载配置（/etc/rc.local、hotplug 脚本），
#       装完只是多一个界面。

set -e

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/root"

[ -d "$SRC" ] || { echo "!! 找不到 $SRC（请在含 root/ 子目录的插件目录里运行本脚本）"; exit 1; }

echo "== 安装 luci-app-openlist-assist（从源码目录直接铺文件）=="

# ---- 铺文件：用 tar 管道，保留目录结构与权限 ----
( cd "$SRC" && tar cf - . ) | ( cd / && tar xf - )

# diskctl 必须可执行
chmod 755 /usr/bin/diskctl 2>/dev/null || true

# ---- LuCI 缓存必须清，否则新菜单不出现 ----
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
/etc/init.d/rpcd   restart >/dev/null 2>&1 || true

echo "  已写入："
echo "    /usr/bin/diskctl"
echo "    /usr/lib/lua/luci/controller/openlist_assist.lua"
echo "    /usr/lib/lua/luci/view/openlist_assist/main.htm"
echo "    /usr/share/rpcd/acl.d/luci-app-openlist-assist.json"
echo "    /etc/config/openlist-assist"
echo

# ---- 依赖自检（只提示，不阻断）----
if [ ! -x /usr/bin/diskctl ]; then
	echo "  ⚠️  没找到 /usr/bin/diskctl —— 界面能打开，但所有按钮都会失败。"
else
	echo "  ✅ /usr/bin/diskctl 已就位"
fi

if [ ! -x /usr/sbin/blkid ] && [ ! -x /sbin/blkid ]; then
	echo "  ⚠️  没找到 blkid —— 探不出文件系统类型。装一下：opkg update && opkg install blkid"
else
	echo "  ✅ blkid 已就位"
fi

if grep -qw ntfs3 /proc/filesystems; then
	echo "  ✅ ntfs3 驱动内置可用"
else
	echo "  ⚠️  内核没有 ntfs3"
fi
if grep -qw exfat /proc/filesystems; then
	echo "  ✅ exfat 驱动内置可用"
else
	echo "  ⚠️  内核没有 exfat"
fi
echo "      （这两个都是内核自带的，挂载不需要额外装包）"
echo
echo "  ℹ️  格式化 / 检查用的用户态工具（可选，界面上「一键安装」也能装）："
echo "        opkg update && opkg install exfat-mkfs exfat-fsck dosfstools e2fsprogs"
echo "      ★ 官方源里没有 exfatprogs 这个总包，是拆成 exfat-mkfs / exfat-fsck 的；"
echo "        dosfstools 装出来的命令叫 mkfs.fat，不叫 mkfs.vfat。"
echo "      ★ NTFS 格式化在本固件上做不了（缺 mkntfs、没有 fuse），但 NTFS 的"
echo "        挂载与读写完全正常（内核自带 ntfs3）。"

echo
echo "  入口：LuCI → 服务 → OpenList 助手"
echo "    或直接打开 http://<路由器IP>/cgi-bin/luci/admin/services/openlist-assist"
echo
echo "  提示：装完请刷新一次浏览器（Ctrl/Cmd+Shift+R），LuCI 静态资源有缓存。"
