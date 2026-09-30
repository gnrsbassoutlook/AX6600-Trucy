#!/bin/sh
# ============================================================
#  openlist-fix-webdav-write.sh
#
#  修 OpenList / Alist 的「WebDAV 能读、不能写」（PUT / MKCOL / MOVE / DELETE → 403）。
#
#  ── 根因（一句话）──────────────────────────────────────────
#  不是客户端（RaiDrive / Finder / Windows 映射）的问题，是服务端权限位：
#  admin 账号的 permission 缺 **bit9 = 512 = WebDAV 写入**。
#  而上游**默认值就是** Permission = 0x71FF = 29183，恰好不含 bit9
#  → 任何一台新装的 OpenList，WebDAV 写入天生就是 403。
#  源码：OpenList `internal/bootstrap/data/user.go`，v4.2.6 与 main 分支**都一样**。
#
#  ── 本脚本只做一件事 ──────────────────────────────────────
#  登录 → 读权限位 → **只加上 bit9** → 回写 → 重新登录复验。
#  其他权限位一个不动，其他任何配置都不碰。
#
#  ── 用法 ─────────────────────────────────────────────────
#    ./openlist-fix-webdav-write.sh                              # 默认 http://127.0.0.1:5244
#    ./openlist-fix-webdav-write.sh http://192.168.1.1:5244
#    ./openlist-fix-webdav-write.sh http://192.168.1.1:5244 admin
#    OL_PASS=你的密码 ./openlist-fix-webdav-write.sh http://192.168.3.1:5244 admin
#    ./openlist-fix-webdav-write.sh -n http://192.168.1.1:5244    # 只体检，不改
#    ./openlist-fix-webdav-write.sh -d THW-4T http://192.168.1.1:5244
#                                                                # 改完顺便用 WebDAV 真写一把
#    -h 看帮助
#
#  依赖：只剩 curl + sed + awk（路由器上就有）。有 jq 会优先用 jq。
#
#  ⚠️ 两个必须知道的副作用
#   ① 回写用的是**完整对象**（OpenList 的 user/update 就是这个接口）——
#      所以脚本会把读到的字段原样带回去，**不改的字段保证不变**。
#   ② 改完 admin 的**已发 token 会立即失效** → 面板网页要重新登录一次。
# ============================================================
set -u

OL_URL=""; OL_USER="admin"; OL_PASS="${OL_PASS:-}"
DRY=0; DAV_TEST=""

usage() { sed -n '2,40p' "$0"; }

while [ $# -gt 0 ]; do
	case "$1" in
		-n) DRY=1 ;;
		-d) shift; DAV_TEST="${1:-}" ;;
		-h|--help) usage; exit 0 ;;
		*) if [ -z "${OL_URL}" ]; then OL_URL="$1"; elif [ "${OL_USER}" = "admin" ]; then OL_USER="$1"; else OL_PASS="$1"; fi ;;
	esac
	shift
done

[ -n "${OL_URL}" ] || OL_URL="http://127.0.0.1:5244"
case "${OL_URL}" in
	http://*|https://*) ;;
	*) OL_URL="http://${OL_URL}" ;;
esac
case "${OL_URL#*://}" in
	*:*) ;;
	*) OL_URL="${OL_URL}:5244" ;;
esac
OL_URL="${OL_URL%/}"

if [ -z "${OL_PASS}" ]; then
	printf 'OpenList 密码（用户 %s）：' "${OL_USER}"
	if [ -t 0 ]; then stty -echo 2>/dev/null; read -r OL_PASS; stty echo 2>/dev/null; printf '\n'; else read -r OL_PASS; fi
fi
[ -n "${OL_PASS}" ] || { echo "✗ 密码为空"; exit 1; }

command -v curl >/dev/null 2>&1 || { echo "✗ 没找到 curl"; exit 1; }

have_jq() { command -v jq >/dev/null 2>&1; }

# 从一行扁平的 JSON 里取某个 key 的**原始 token**（字符串带引号，数字/布尔原样）
jraw() { printf '%s' "$2" | sed -n "s/.*\"$1\":\([^,}]*\).*/\1/p" | head -1; }
# 取字符串 key 的值（去掉引号）
jstr() { jraw "$1" "$2" | tr -d '"'; }

# ---------- ① 登录 ----------
login() {
	curl -s -m 15 -X POST "${OL_URL}/api/auth/login" \
		-H 'Content-Type: application/json' \
		-d "{\"username\":\"${OL_USER}\",\"password\":\"${OL_PASS}\"}"
}

echo "=========================================="
echo " OpenList WebDAV 写入权限体检 / 修复"
echo " 目标：${OL_URL}    用户：${OL_USER}    模式：$([ ${DRY} = 1 ] && echo '只体检（-n）' || echo '体检并修复')"
echo "=========================================="

resp=$(login)
tok=$(printf '%s' "${resp}" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' | head -1)
if [ -z "${tok}" ]; then
	echo "✗ 登录失败。原始响应："
	printf '%s\n' "${resp}" | cut -c1-300
	echo "  排查：地址/端口对不对；用户名默认 admin；密码是不是 OpenList 面板那个（不是路由器 SSH 那个）。"
	exit 1
fi
echo "✓ 登录成功"

# ---------- ② 读管理员权限位 ----------
list=$(curl -s -m 15 "${OL_URL}/api/admin/user/list" -H "Authorization: ${tok}")

if have_jq && printf '%s' "${list}" | jq -e . >/dev/null 2>&1; then
	admin=$(printf '%s' "${list}" | jq -c '.data.content[] | select(.role==2)' | head -1)
else
	admin=$(printf '%s' "${list}" | awk '{ gsub(/\},\{/,"}\n{"); print }' | grep '"role":2' | head -1)
fi
if [ -z "${admin}" ]; then
	echo "✗ 读不到管理员记录。原始响应："
	printf '%s\n' "${list}" | cut -c1-300
	exit 1
fi

id=$(jraw id "${admin}"); uname=$(jstr username "${admin}"); bpath=$(jstr base_path "${admin}")
role=$(jraw role "${admin}"); dis=$(jraw disabled "${admin}"); ldap=$(jraw allow_ldap "${admin}")
sso=$(jraw sso_id "${admin}")
perm=$(jraw permission "${admin}")
echo "✓ 管理员：id=${id} 用户=${uname}  当前 permission=${perm}  (0x$(printf '%X' "${perm}"))"

have_bit9() { [ $(( ${1} & 512 )) -ne 0 ]; }

echo
echo "── 权限位对照（上游 model/user.go 注释）────────────"
for b in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
	v=$(( 1 << b ))
	name=""
	case $b in
		0) name="查看隐藏文件" ;;  1) name="无需密码访问" ;;  2) name="添加离线下载任务" ;;
		3) name="创建目录 / 上传" ;; 4) name="重命名" ;; 5) name="移动" ;; 6) name="复制" ;; 7) name="删除" ;;
		8) name="WebDAV 读取" ;; 9) name="WebDAV 写入 ★" ;; 10) name="FTP/SFTP 读取" ;; 11) name="FTP/SFTP 写入" ;;
		12) name="读取压缩包" ;; 13) name="解压压缩包" ;; 14) name="分享" ;;
	esac
	if [ $(( ${perm} & v )) -ne 0 ]; then mark="[√]"; else mark="[ ]"; fi
	if [ "${b}" = 9 ] && [ $(( ${perm} & 512 )) -eq 0 ]; then mark="${mark} ◀ 缺的就是它"; fi
	printf '  bit%-2s %-5s %-18s %s\n' "$b" "$v" "${name}" "${mark}"
done

if have_bit9 "${perm}"; then
	echo
	echo "✓ bit9 已就位 —— WebDAV 写入应该是正常的，本脚本无需改动。"
	NEWPERM="${perm}"; CHANGED=0
else
	NEWPERM=$(( ${perm} | 512 ))
	echo
	echo "✗ 缺 bit9（512）→ 这就是 WebDAV 写入 403 的原因。"
	echo "  ${perm} → ${NEWPERM}  (0x$(printf '%X' "${perm}") → 0x$(printf '%X' "${NEWPERM}"))"
	CHANGED=1
fi

if [ "${CHANGED}" = 1 ]; then
	if [ "${DRY}" = 1 ]; then
		echo "· 演练模式：不改。去掉 -n 再跑一次即生效。"
	else
		body=$(printf '{"id":%s,"username":"%s","password":"","base_path":"%s","role":%s,"disabled":%s,"permission":%s,"sso_id":%s,"allow_ldap":%s}' \
			"${id}" "${uname}" "${bpath}" "${role}" "${dis}" "${NEWPERM}" "${sso:-\"\"}" "${ldap:-true}")
		echo "· 提交：POST /api/admin/user/update  (只改 permission)"
		upd=$(curl -s -m 15 -X POST "${OL_URL}/api/admin/user/update" \
			-H "Authorization: ${tok}" -H 'Content-Type: application/json' -d "${body}")
		printf '%s\n' "${upd}" | cut -c1-200
		case "${upd}" in
			*'"code":200'*) ;;
			*) echo "✗ 回写失败，权限位未改，请把上面响应发出来"; exit 1 ;;
		esac
		# 复验（admin 的旧 token 已失效 → 重新登录）
		resp2=$(login)
		tok2=$(printf '%s' "${resp2}" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' | head -1)
		after=$(curl -s -m 15 "${OL_URL}/api/admin/user/list" -H "Authorization: ${tok2}")
		if have_jq && printf '%s' "${after}" | jq -e . >/dev/null 2>&1; then
			aperm=$(printf '%s' "${after}" | jq -r --arg u "${uname}" '.data.content[]|select(.username==$u)|.permission' | head -1)
		else
			aperm=$(printf '%s' "${after}" | awk '{ gsub(/\},\{/,"}\n{"); print }' | grep '"role":2' | head -1 | sed -n 's/.*"permission":\([0-9-]*\).*/\1/p' | head -1)
		fi
		if have_bit9 "${aperm}"; then
			echo "✓ 复验通过：permission=${aperm}，bit9 已就位"
		else
			echo "✗ 复验失败：permission=${aperm}（bit9 仍未生效）"; exit 1
		fi
		echo "⚠️ 注意：admin 的旧 token 已失效，面板网页需要重新登录一次。"
	fi
fi

# ---------- ③ 可选：WebDAV 真写一把 ----------
if [ -n "${DAV_TEST}" ]; then
	echo
	echo "── WebDAV 实测（存储 ${DAV_TEST}）────────────"
	dav="${OL_URL}/dav/${DAV_TEST}"
	tf="${TMPDIR:-/tmp}/olperm.$$"
	echo "openlist-webdav-write-check $(date 2>/dev/null || echo)" > "${tf}"
	c1=$(curl -s -u "${OL_USER}:${OL_PASS}" -o /dev/null -w '%{http_code}' -T "${tf}" "${dav}/_olperm_check.txt")
	c2=$(curl -s -u "${OL_USER}:${OL_PASS}" -o /dev/null -w '%{http_code}' "${dav}/_olperm_check.txt")
	c3=$(curl -s -u "${OL_USER}:${OL_PASS}" -o /dev/null -w '%{http_code}' -X MKCOL "${dav}/_olperm_dir")
	c4=$(curl -s -u "${OL_USER}:${OL_PASS}" -o /dev/null -w '%{http_code}' -X MOVE -H "Destination: ${dav}/_olperm_dir/moved.txt" "${dav}/_olperm_check.txt")
	c5=$(curl -s -u "${OL_USER}:${OL_PASS}" -o /dev/null -w '%{http_code}' -X DELETE "${dav}/_olperm_dir/moved.txt")
	c6=$(curl -s -u "${OL_USER}:${OL_PASS}" -o /dev/null -w '%{http_code}' -X DELETE "${dav}/_olperm_dir")
	rm -f "${tf}"
	printf '  PUT     -> %s  (想要 201)\n' "${c1}"
	printf '  GET     -> %s  (想要 200)\n' "${c2}"
	printf '  MKCOL   -> %s  (想要 201)\n' "${c3}"
	printf '  MOVE    -> %s  (想要 201)\n' "${c4}"
	printf '  DELETE  -> %s / %s  (想要 204)\n' "${c5}" "${c6}"
	if [ "${c1}" = 201 ] && [ "${c3}" = 201 ] && [ "${c5}" = 204 ]; then
		echo "✓ 写 / 建目录 / 改名 / 删除 全通 —— 收工"
	else
		echo "✗ 还有不通的，看上面状态码；403 = 权限位，404 = 路径写错了（/dav 是虚拟根，要带存储名）"
		exit 1
	fi
	[ "${DRY}" = 1 ] || echo "（测试文件已删除，盘上不留东西）"
fi

echo
echo "=========================================="
echo " 完成。别忘了：客户端里如果连的是 /dav 根，"
echo " 地址要写成  ${OL_URL}/dav/<存储名>  —— 见文档说明。"
echo "=========================================="
