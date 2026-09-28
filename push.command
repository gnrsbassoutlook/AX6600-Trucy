#!/bin/bash
# ============================================================
#  AX6600-Trucy  GitHub 一键推送（macOS，双击运行）
#
#  认证走 SSH key（~/.ssh/id_ed25519），不需要 PAT、不会过期。
#  首次需要把公钥加到 GitHub 账号上一次 —— 脚本会检测到并给出
#  公钥 + 打开添加页面。
#
#  已经推过的提交、已经存在的东西，重跑不会白做。
# ============================================================
set -u

# ⚠️ 改这个脚本时的坑：中文全角标点紧跟在 $VAR 后面（比如 `$CUR）`），
#    bash 会把那个多字节字符当成变量名的一部分 → "unbound variable" 直接中断
#    （配合 set -u 更致命）。**变量一律写成 ${VAR} 形式**。
#    同理别写 `$REPO_SSH。`、`$AHEAD，` 这种。

cd "$(dirname "$0")" || exit 1

# ★ 关掉分页器：否则 git 输出超过一屏会自动进 less，
#   停在 ":" 提示符上等你按 q，看起来像卡死了。
export GIT_PAGER=cat
export PAGER=cat

GH_USER="gnrsbassoutlook"
REPO_SLUG="gnrsbassoutlook/AX6600-Trucy"
REPO_SSH="git@github.com:${REPO_SLUG}.git"
BRANCH="main"
SSH_KEY="$HOME/.ssh/id_ed25519"
SSH_ADD_PAGE="https://github.com/settings/ssh/new"

echo "=========================================="
echo " 🚀 AX6600-Trucy  GitHub 一键推送"
echo "=========================================="
echo

quit() {
    echo
    read -n 1 -s -r -p "按任意键退出窗口..."
    echo
    exit "${1:-0}"
}

# ---------- 0. 环境 ----------
if ! command -v git >/dev/null 2>&1; then
    echo "❌ 没找到 git。装一下 Xcode 命令行工具：xcode-select --install"
    quit 1
fi

# ---------- 1. 初始化 / 校正远端 ----------
if [ ! -d .git ]; then
    echo "📦 初始化 git 仓库..."
    git init -q
    git branch -M "$BRANCH"
fi

if git remote get-url origin >/dev/null 2>&1; then
    CUR=$(git remote get-url origin)
    if [ "$CUR" != "$REPO_SSH" ]; then
        echo "🔄 远端地址更新 -> $REPO_SSH"
        echo "   （原来是 ${CUR}）"
        git remote set-url origin "$REPO_SSH"
    fi
else
    echo "🔗 添加远端 -> $REPO_SSH"
    git remote add origin "$REPO_SSH"
fi

# ---------- 2. 身份（只写本仓库，不动你的全局配置） ----------
[ -n "$(git config --get user.name)" ]  || git config user.name  "$GH_USER"
[ -n "$(git config --get user.email)" ] || git config user.email "${GH_USER}@users.noreply.github.com"
git config core.quotepath false
# 走 SSH 了，钥匙串助手用不上，清掉免得以后混着 HTTPS 又去问令牌
git config --unset credential.helper 2>/dev/null || true

# ---------- 3. 对齐远端 ----------
if ! git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    # 本地还是空仓库（首次跑）。★ 远端已有提交时，直接 push 必被拒
    #   （non-fast-forward），所以先把分支接到远端历史后面。
    #   --mixed：只动分支指针和索引，工作区文件一个不碰。
    echo "⏳ 读取远端历史..."
    if GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10" \
         git fetch -q origin "$BRANCH" 2>/dev/null \
       && git rev-parse --verify -q "origin/$BRANCH" >/dev/null 2>&1; then
        git reset -q --mixed "origin/$BRANCH"
        echo "   ✅ 已接到远端 $BRANCH 分支之后"
    else
        echo "   （远端还没有内容，或暂时连不上；继续往下走）"
    fi
else
    GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10" \
        git fetch -q origin "$BRANCH" 2>/dev/null || true
fi

# ---------- 4. 暂存 & 统计 ----------
git add -A

HAS_STAGED=0
git --no-pager diff --cached --quiet || HAS_STAGED=1

AHEAD=0
if git rev-parse --verify -q "origin/$BRANCH" >/dev/null 2>&1; then
    AHEAD=$(git --no-pager rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo 0)
fi

# 既没有新改动，也没有"提交了但没推上去"的 → 真的没事做
if [ "$HAS_STAGED" = "0" ] && [ "$AHEAD" = "0" ]; then
    echo "✅ 没有东西要推。"
    echo "   （工作区干净，本地也没有未推送的提交）"
    quit 0
fi

CMD=""
if [ "$HAS_STAGED" = "1" ]; then
    STAT=$(git --no-pager diff --cached --name-status)
    N_A=$(printf '%s\n' "$STAT" | grep -c '^A' || true)
    N_M=$(printf '%s\n' "$STAT" | grep -c '^M' || true)
    N_D=$(printf '%s\n' "$STAT" | grep -c '^D' || true)
    N_R=$(printf '%s\n' "$STAT" | grep -c '^R' || true)

    echo "📊 改动：新增 $N_A 个  修改 $N_M 个  删除 $N_D 个  重命名 $N_R 个"
    echo

    if [ "$N_A" != "0" ]; then
        echo "   新增："
        printf '%s\n' "$STAT" | grep '^A' | sed 's/^A[[:space:]]*/     + /'
        echo
    fi
    if [ "$N_M" != "0" ]; then
        echo "   修改："
        printf '%s\n' "$STAT" | grep '^M' | sed 's/^M[[:space:]]*/     ~ /'
        echo
    fi
    if [ "$N_D" != "0" ]; then
        echo "   ⚠️  删除 —— 确认这几个是你要删的："
        printf '%s\n' "$STAT" | grep '^D' | sed 's/^D[[:space:]]*/     - /'
        echo
    fi

    read -r -p "👉 确认推送以上改动？[Y/n] " ok
    case "$ok" in
        n|N|no|NO) echo "已取消。"; quit 0 ;;
    esac
    CMD="commit"
else
    echo "ℹ️  这次没有文件改动，但有 $AHEAD 个本地提交还没推上去。"
    echo
fi

# ---------- 5. 提交 ----------
if [ "$CMD" = "commit" ]; then
    read -r -p "👉 Commit 说明（直接回车用默认）: " msg
    [ -z "$msg" ] && msg="Auto update: $(date '+%Y-%m-%d %H:%M:%S')"
    echo
    echo "⏳ 提交中..."
    if ! git commit -q -m "$msg"; then
        echo "❌ 提交失败，先把上面的报错发我看看。"
        quit 1
    fi
    echo "   $msg"
fi

# ============================================================
#  6. ★ SSH 凭据自检
#
#  ⚠️ 坑：`ssh -T git@github.com` 即使「成功」退出码也是 1
#     （GitHub 不提供 shell，故意返回非 0）。所以只能看输出里
#     有没有 "successfully authenticated"，绝不能判退出码。
# ============================================================
ssh_ok() {
    ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 git@github.com 2>&1
}

check_ssh() {
    if [ ! -f "$SSH_KEY" ]; then
        echo "   ❌ 这台机器上还没有 SSH key（${SSH_KEY}）"
        echo "      跟我说一声，我给你配一把：生成密钥 → 复制公钥 → 打开 GitHub 添加页。"
        return 1
    fi

    local out
    out=$(ssh_ok)

    if printf '%s' "$out" | grep -q "successfully authenticated"; then
        echo "   ✅ $(printf '%s' "$out" | head -1)"
        return 0
    fi

    echo "   ❌ SSH 连不上 GitHub（或这把 key 还没加进账号）"
    printf '%s\n' "$out" | sed 's/^/      /'
    echo

    case "$out" in
        *"Permission denied"*)
            echo "   👉 这把 key 还没加到你的 GitHub 账号上。"
            echo "      公钥我帮你放进剪贴板了，粘到下面这个页面就行："
            echo "        $SSH_ADD_PAGE"
            echo
            echo "      当前公钥（指纹 $(ssh-keygen -lf "$SSH_KEY.pub" 2>/dev/null | awk '{print $2}')）："
            sed 's/^/        /' "$SSH_KEY.pub"
            if [ -t 0 ]; then
                pbcopy < "$SSH_KEY.pub" 2>/dev/null || true
                open "$SSH_ADD_PAGE" >/dev/null 2>&1 || true
                echo
                echo "      （公钥已复制、页面已打开）"
            fi
            echo
            echo "      页面里：Title 随便写（比如 Mac Studio），Key type 保持"
            echo "      Authentication Key，公钥整串粘进 Key 框，点 Add SSH key。"
            echo "      加完等十几秒再重跑本脚本 —— GitHub 有时要缓存一会儿。"
            ;;
        *"onnection timed out"*|*"Connection refused"*|*"unreachable"*|*"Operation timed out"*)
            echo "   👉 这是网络问题（22 端口不通），不是 key 的问题。"
            echo "      打开 ~/.ssh/config，把最后那段「备用通道」的注释去掉，"
            echo "      就会改走 443 端口（GitHub 的 SSH over HTTPS）。"
            ;;
    esac
    return 1
}

echo
echo "⏳ 检查 SSH 凭据..."
if ! check_ssh; then
    echo
    echo "❌ SSH 没配好，先不推。"
    echo "   你的提交**已经安全存在本地**，什么都没丢 —— 配好后重跑本脚本会接着推。"
    quit 1
fi

# ============================================================
#  7. 推送
# ============================================================
PUSH_LOG=$(mktemp /tmp/ax6600-push.XXXXXX)

do_push() {
    git --no-pager push origin "$BRANCH"
}

echo
echo "⏳ 推送到 GitHub..."
echo

if do_push >"$PUSH_LOG" 2>&1; then
    cat "$PUSH_LOG"
    echo
    echo "🎉 推送成功！"
    echo "   https://github.com/${REPO_SLUG}"
    git branch --set-upstream-to="origin/$BRANCH" "$BRANCH" >/dev/null 2>&1 || true
    rm -f "$PUSH_LOG"
    quit 0
fi

cat "$PUSH_LOG"

if grep -qiE 'publickey|Permission denied|Host key verification failed' "$PUSH_LOG"; then
    echo
    echo "❌ 身份被拒 —— SSH key 那边有问题："
    check_ssh || true

elif grep -qiE 'non-fast-forward|rejected|fetch first|behind its remote' "$PUSH_LOG"; then
    echo
    echo "⚠️  远端有新提交，拉下来重放一次..."
    if git fetch origin "$BRANCH" && git --no-pager rebase "origin/$BRANCH"; then
        if do_push >"$PUSH_LOG" 2>&1; then
            cat "$PUSH_LOG"
            echo
            echo "🎉 重放后推送成功！"
        else
            cat "$PUSH_LOG"
            echo
            echo "❌ 推送仍然失败，把上面这几行发我。"
        fi
    else
        echo
        echo "❌ 重放有冲突，需要手动处理。"
        echo "   你的提交没丢：  git --no-pager log --oneline | head"
    fi

else
    echo
    echo "❌ 推送失败，报错不是身份问题 —— 把上面这几行发我看看。"
fi

rm -f "$PUSH_LOG"
quit 0
