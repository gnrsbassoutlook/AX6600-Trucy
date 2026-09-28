#!/bin/bash
# ============================================================
#  AX6600-Trucy  一键推送（macOS）
#  双击运行即可。首次会问 GitHub 账号，之后走钥匙串不再问。
# ============================================================
set -u

cd "$(dirname "$0")" || exit 1

# ★ 关掉分页器：否则 git 输出超过一屏会自动进 less，
#   停在 ":" 提示符上等你按 q，看起来像卡死了。
export GIT_PAGER=cat
export PAGER=cat

REPO_HTTPS="https://github.com/gnrsbassoutlook/AX6600-Trucy.git"
BRANCH="main"

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
    if [ "$CUR" != "$REPO_HTTPS" ]; then
        echo "🔄 远端地址已更新 -> $REPO_HTTPS"
        git remote set-url origin "$REPO_HTTPS"
    fi
else
    echo "🔗 添加远端 -> $REPO_HTTPS"
    git remote add origin "$REPO_HTTPS"
fi

# ---------- 2. 凭据助手 & 身份（只写本仓库，不动你的全局配置） ----------
git config credential.helper osxkeychain
[ -n "$(git config --get user.name)" ]  || git config user.name  "gnrsbassoutlook"
[ -n "$(git config --get user.email)" ] || git config user.email "gnrsbassoutlook@users.noreply.github.com"
git config core.quotepath false

# ---------- 3. 对齐远端 ----------
if ! git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    # 本地还是空仓库（首次跑）。★ 远端已有提交时，直接 push 必被拒
    #   （non-fast-forward），所以先把分支接到远端历史后面。
    #   --mixed：只动分支指针和索引，工作区文件一个不碰。
    echo "⏳ 读取远端历史..."
    if git fetch -q origin "$BRANCH" 2>/dev/null \
       && git rev-parse --verify -q "origin/$BRANCH" >/dev/null 2>&1; then
        git reset -q --mixed "origin/$BRANCH"
        echo "   ✅ 已接到远端 $BRANCH 分支之后"
    else
        echo "   （远端还没有内容，作为首个提交推上去）"
    fi
else
    # 已经有历史了，顺手把远端状态刷新一下（离线也不影响）
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

# ---------- 6. 推送 ----------
echo "⏳ 推送到 GitHub..."
echo
if git --no-pager push -u origin "$BRANCH"; then
    echo
    echo "🎉 推送成功！"
    echo "   https://github.com/gnrsbassoutlook/AX6600-Trucy"
else
    echo
    echo "⚠️  推送失败，试一次「拉取后重推」（一般是远端有新提交）..."
    if git --no-pager pull --rebase origin "$BRANCH"; then
        if git --no-pager push -u origin "$BRANCH"; then
            echo
            echo "🎉 重推成功！"
        else
            echo
            echo "❌ 还是推不上去。"
            echo "   如果报的是 Username / Authentication —— 那是没输 PAT。"
            echo "   注意：你的提交**已经在本地存好了**，重新跑本脚本会接着推，不会白做。"
        fi
    else
        echo
        echo "❌ 重放失败，有冲突要手动处理。"
        echo "   你的提交还在，没丢：  git --no-pager log --oneline | head"
    fi
fi

quit 0
