#!/bin/sh
# ============================================================
#  mount-data-disk.sh —— 挂载 4T 数据盘 (NTFS) 给 OpenList 用
#  设备: /dev/sda2  (3.6T「Microsoft basic data」数据区)
#  挂载: /mnt/sda2  (ntfs3 + iocharset=utf8 → 中文不乱码)
#
#  幂等: 已挂载 → 直接返回 0，可安全重复调用
#  用法: mount-data-disk.sh [-q]     -q = 静默（热插拔时用）
#
#  为什么不用 `mount` 而要写 `busybox mount`?
#  本机装了 mount-utils(util-linux)，它的 /usr/bin/mount 与固件里的
#  libmount.so.1 ABI 不匹配，一执行就报
#  "Error relocating /usr/bin/mount: mnt_context_enable_onlyonce: symbol not found"
#  → PATH 里 /usr/bin 在前，裸 `mount` 会命中这个坏的。
#  所以此处一律显式走 busybox。（彻底修复 = opkg remove mount-utils）
# ============================================================

DEV="/dev/sda2"
MNT="/mnt/sda2"
LOGF="/tmp/data-disk.log"

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') [mountdata] $*" >> "$LOGF"
	if command -v logger >/dev/null 2>&1; then
		logger -t mountdata "$*" 2>/dev/null
	fi
}

QUIET=0
[ "$1" = "-q" ] && QUIET=1

# ---------- 1. 已经挂载了？ ----------
if grep -qs " $MNT " /proc/mounts; then
	[ "$QUIET" = "0" ] && log "already mounted: $DEV -> $MNT"
	exit 0
fi

# ---------- 2. 等设备出现（热插拔/开机枚举都要一点时间） ----------
i=0
while [ ! -b "$DEV" ] && [ $i -lt 15 ]; do
	sleep 2
	i=$((i + 1))
done
if [ ! -b "$DEV" ]; then
	log "SKIP: $DEV 不存在（硬盘没插？）"
	exit 1
fi

mkdir -p "$MNT"
command -v modprobe >/dev/null 2>&1 && modprobe ntfs3 2>/dev/null

# ---------- 3. 干净挂载 ----------
if busybox mount -t ntfs3 -o iocharset=utf8 "$DEV" "$MNT" 2>/tmp/.md.err; then
	log "OK: mounted clean  $DEV -> $MNT"
	[ "$QUIET" = "0" ] && df -h "$MNT"
	exit 0
fi

# ---------- 4. 干净挂载失败 → 多半是脏标记（断电/直接拔线） ----------
log "WARN: 干净挂载失败：$(cat /tmp/.md.err 2>/dev/null | tr '\n' ' ')"
log "WARN: 改用 force 强挂（NTFS 脏标记）—— 建议之后在 Windows 上 chkdsk /f 一次"
if busybox mount -t ntfs3 -o force,iocharset=utf8 "$DEV" "$MNT" 2>/tmp/.md.err; then
	log "OK: mounted FORCED $DEV -> $MNT"
	[ "$QUIET" = "0" ] && {
		echo "⚠️  已用 force 挂上（说明上次是非正常卸载）"
		echo "    日志: $LOGF"
		df -h "$MNT"
	}
	exit 0
fi

log "ERROR: 挂载彻底失败：$(cat /tmp/.md.err 2>/dev/null | tr '\n' ' ')"
exit 1
