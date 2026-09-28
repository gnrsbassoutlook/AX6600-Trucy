#!/bin/sh
# ============================================================
#  umount-data-disk.sh —— 安全弹出 4T 数据盘（拔线/拿去电脑修前必做）
#
#  拔线或断电前跑一次，让 ntfs3 把缓存刷回盘、清掉脏标记。
#  不跑就直接拔 → NTFS 被写脏标记 → 下次要 force 才能挂。
#
#  用法:
#     umount-data-disk.sh              # 正常卸载
#     umount-data-disk.sh --stop       # 先停 OpenList 再卸载（最稳）
# ============================================================

DEV="/dev/sda2"
MNT="/mnt/sda2"
LOGF="/tmp/data-disk.log"

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') [umountdata] $*" >> "$LOGF"
	if command -v logger >/dev/null 2>&1; then
		logger -t umountdata "$*" 2>/dev/null
	fi
}

# ---------- 可选：先停 OpenList 解除占用 ----------
if [ "$1" = "--stop" ]; then
	if pgrep -f "openlist server" >/dev/null 2>&1; then
		echo "== 停止 OpenList =="
		killall openlist 2>/dev/null
		sleep 2
		pgrep -f "openlist server" >/dev/null 2>&1 && killall -9 openlist 2>/dev/null
		sleep 1
	fi
	echo "（重启 OpenList: cd /root/openlist_run && ./openlist server >/tmp/openlist.log 2>&1 &）"
fi

# ---------- 根本没挂？ ----------
if ! grep -qs " $MNT " /proc/mounts; then
	echo "当前未挂载 $MNT —— 无需操作。"
	exit 0
fi

echo "== 卸载 $MNT =="
if busybox umount "$MNT" 2>/tmp/.um.err; then
	log "umounted clean: $MNT"
	sync
	echo "✅ 已安全卸载，现在可以拔线了。"
	exit 0
fi

echo "⚠️  正常卸载失败（有文件被占用）：$(cat /tmp/.um.err 2>/dev/null | tr '\n' ' ')"
echo "    → 用 --stop 先停 OpenList 再试；或下面走延迟卸载。"
echo
printf "   现在执行「延迟卸载 (-l)」吗？拔线后后台可能还在刷缓存 [y/N] "
read ans
case "$ans" in
	y|Y|yes|YES)
		if busybox umount -l "$MNT" 2>/tmp/.um.err; then
			log "umounted lazy: $MNT"
			echo "⚠️  已延迟卸载。缓存可能还在刷，请再等 10 秒后拔线。"
			exit 0
		fi
		echo "❌ 延迟卸载也失败：$(cat /tmp/.um.err 2>/dev/null)"
		log "ERROR: lazy umount failed"
		exit 1
		;;
	*)
		echo "已取消，硬盘仍挂载中。"
		exit 1
		;;
esac
