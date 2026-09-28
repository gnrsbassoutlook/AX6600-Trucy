#!/bin/sh
# luci-app-adhfilter 一键安装（不依赖 opkg，直接把文件铺上去）
#
# 在路由器上执行：
#   sh install.sh
#
# 只想用 ipk 的话：opkg install dist/luci-app-adhfilter_*.ipk
# 卸载：sh uninstall.sh
#
# 前提：/usr/bin/adhfilter 已就位（见 ../tools/adhfilter）。
#       脚本只会提示，不会替你去装它。

set -e

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/root"

[ -d "$SRC" ] || { echo "!! 找不到 $SRC（请在含 root/ 子目录的插件目录里运行本脚本）"; exit 1; }

echo "== 安装 luci-app-adhfilter（从源码目录直接铺文件）=="

# ---- 铺文件（5 个路径）----
# 用 tar 管道，保留目录结构与权限
( cd "$SRC" && tar cf - . ) | ( cd / && tar xf - )

# ---- LuCI 缓存必须清，否则新菜单不出现 ----
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo "  已写入："
echo "    /usr/lib/lua/luci/controller/adhfilter.lua"
echo "    /usr/lib/lua/luci/model/cbi/adhfilter/main.lua"
echo "    /usr/lib/lua/luci/view/adhfilter/main.htm"
echo "    /usr/share/rpcd/acl.d/luci-app-adhfilter.json"
echo "    /etc/config/adhfilter"
echo

# ---- 依赖自检（只提示，不阻断）----
if [ ! -x /usr/bin/adhfilter ]; then
	echo "  ⚠️  没找到 /usr/bin/adhfilter —— 界面能打开，但所有按钮都会失败。"
	echo "     请先把 ../tools/adhfilter 放到 /usr/bin/ 并 chmod +x。"
else
	echo "  ✅ /usr/bin/adhfilter 已就位"
fi

if [ ! -x /usr/bin/AdGuardHome/AdGuardHome ]; then
	echo "  ⚠️  没找到 AdGuard Home 本体 —— 界面能开，但过滤不会生效。"
fi

echo
echo "  入口：LuCI → 服务 → ADH设备过滤助手"
echo "    或直接打开 http://<路由器IP>/cgi-bin/luci/admin/services/adhfilter"
echo
echo "  提示：装完请刷新一次浏览器（Ctrl/Cmd+Shift+R），LuCI 静态资源有缓存。"
