#!/bin/bash
# ============================================================
#  AX6600-Trucy  GitHub 一键推送（macOS，双击运行）
#
#  首次运行会要一个 GitHub 个人访问令牌 (PAT)：
#    · 脚本会自动打开创建页面（浏览器里已登录 GitHub 的话几步就完）
#    · 粘进来之后存进 macOS 钥匙串，以后推送不再问
#
#  已经推过的提交、已经存在的东西，重跑不会白做。
# ============================================================
set -u

cd "$(dirname "$0")" || exit 1

# ★ 关掉分页器：否则 git 输出超过一屏会自动进 less，
#   停在 ":" 提示符上等你按 q，看起来像卡死了。
export GIT_PAGER=cat
export PAGER=cat

GH_USER="gnrsbassoutlook"
REPO_SLUG="gnrsbassoutlook/AX6600-Trucy"
REPO_HTTPS="https://github.com/${REPO_SLUG}.git"
BRANCH="main"

TOKEN=""
PUSH_URL="origin"          # origin = 走钥匙串；否则是带令牌的临时地址

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
[ -n "$(git config --get user.name)" ]  || git config user.name  "$GH_USER"
[ -n "$(git config --get user.email)" ] || git config user.email "${GH_USER}@users.noreply.github.com"
git config core.quotepath false

# ---------- 3. 对齐远端 ----------
if ! git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    # 本地还是空仓库（首次跑）。★ 远端已有提交时，直接 push 必被拒
    #   （non-fast-forward），所以先把分支接到远端历史后面。
    #   --mixed：只动分支指针和索引，工作区文件一个不碰。
    echo "⏳ 读取远端历史..."
    if GIT_TERMINAL_PROMPT=0 git fetch -q origin "$BRANCH" 2>/dev/null \
       && git rev-parse --verify -q "origin/$BRANCH" >/dev/null 2>&1; then
        git reset -q --mixed "origin/$BRANCH"
        echo "   ✅ 已接到远端 $BRANCH 分支之后"
    else
        echo "   （远端还没有内容，作为首个提交推上去）"
    fi
else
    # 已经有历史了，顺手把远端状态刷新一下（离线/没凭据也不影响）
    GIT_TERMINAL_PROMPT=0 git fetch -q origin "$BRANCH" 2>/dev/null || true
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
#  6. ★ 凭据：先探，缺了就问你要一次 PAT
#
#  ⚠️ 踩过的坑：这个仓库是**公开**的，所以 `git ls-remote` 不带凭据也返回 0。
#     拿它当"有没有身份"的探针 = 永远说 OK，然后 push 才失败。
#     · 查凭据 → `git credential fill`（问钥匙串，无凭据时报 fatal、退出码 128）
#     · 验令牌 → `git push --dry-run`（真写操作的握手，但不会真的推）
# ============================================================

# 钥匙串里到底有没有 GitHub 凭据
have_cred() {
    printf 'protocol=https\nhost=github.com\n\n' \
        | GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null \
        | grep -q '^password='
}

# ★ 用"真写操作的握手"验证令牌：--dry-run 会完整握手但不发更新，
#   所以能同时验出「令牌无效」和「令牌没给写权限」这两种失败。
verify_token() {
    local t="$1"
    GIT_TERMINAL_PROMPT=0 git -c credential.helper= --no-pager push --dry-run \
        "https://${GH_USER}:${t}@github.com/${REPO_SLUG}.git" \
        "HEAD:refs/heads/${BRANCH}" >/dev/null 2>&1
}

ask_pat() {
    echo
    echo "🔑 需要一次 GitHub 身份验证。"
    echo "   原因：这台机器的钥匙串里没有 GitHub 凭据，也没有配 SSH key，"
    echo "   git 不知道该以谁的名义推 —— 跟上不上网、文件对不对都没关系。"
    echo
    echo "   GitHub 早就不收登录密码了，HTTPS 推送要用「个人访问令牌 (PAT)」。"
    echo "   我帮你把创建页面打开（浏览器里已登录 GitHub 的话，四步就够）："
    echo "     1) Note 随便写（比如 AX6600-Trucy）"
    echo "     2) Expiration 选 90 days"
    echo "     3) ★ 勾选最上面那个 repo"
    echo "     4) 拉到底点 Generate token，然后**立刻复制**那一串"
    echo "        （离开页面就再也看不到了）"
    echo
    if [ -t 0 ]; then
        open "https://github.com/settings/tokens/new?scopes=repo&description=AX6600-Trucy" >/dev/null 2>&1 || true
        echo "   （浏览器应该已经弹出来了）"
        echo
    fi

    local i t
    for i in 1 2 3; do
        printf "   🔐 粘贴 PAT（输入时不显示，粘完直接回车；直接回车＝放弃）: "
        read -r -s t
        echo
        t=$(printf '%s' "$t" | tr -d '[:space:]')
        if [ -z "$t" ]; then
            echo "   （空的，取消）"
            return 1
        fi
        echo "   ⏳ 拿去 GitHub 试一次写权限（不会真的推）..."
        if verify_token "$t"; then
            TOKEN="$t"
            echo "   ✅ 令牌有效，且有写权限"
            return 0
        fi
        echo "   ❌ 没通过（第 $i 次）。可能原因："
        echo "        · 复制时漏了字符 / 前后带了空格"
        echo "        · 生成时**没勾 repo**（只读权限推不上去）"
        echo "        · 令牌已过期或被撤销"
    done
    return 1
}

echo
echo "⏳ 检查推送凭据..."

if have_cred; then
    echo "   ✅ 钥匙串里有 GitHub 凭据"
else
    echo "   🔑 钥匙串里没有凭据"
    if ask_pat; then
        # 存进钥匙串 → 以后不再问
        printf 'protocol=https\nhost=github.com\nusername=%s\npassword=%s\n\n' \
            "$GH_USER" "$TOKEN" | git credential-osxkeychain store >/dev/null 2>&1 || true
        if have_cred; then
            echo "   ✅ 已存入 macOS 钥匙串，以后推送不会再问。"
        else
            # 钥匙串没吃下去，本次就用带令牌的临时地址推（不会写进仓库配置）
            PUSH_URL="https://${GH_USER}:${TOKEN}@github.com/${REPO_SLUG}.git"
            echo "   ℹ️  本次用临时凭据推送（不会写进仓库配置）"
        fi
    else
        echo
        echo "❌ 没有凭据，推不上去。"
        echo "   你的提交**已经安全存在本地**，什么都没丢 —— 重新跑本脚本会接着推。"
        echo "   不想用 PAT 也行：跟我说一声，我给你配 SSH key（也是配一次、以后不再问）。"
        quit 1
    fi
fi

# ============================================================
#  7. 推送
# ============================================================
PUSH_LOG=$(mktemp /tmp/ax6600-push.XXXXXX)

do_push() {
    if [ "$PUSH_URL" = "origin" ]; then
        git --no-pager push origin "$BRANCH"
    else
        git --no-pager push "$PUSH_URL" "HEAD:refs/heads/$BRANCH"
    fi
}

echo
echo "⏳ 推送到 GitHub..."
echo

if do_push >"$PUSH_LOG" 2>&1; then
    cat "$PUSH_LOG"
    # 用临时地址推的时候 git 不认 origin，补一次 fetch 让 origin/main 跟上
    [ "$PUSH_URL" = "origin" ] || GIT_TERMINAL_PROMPT=0 git fetch -q origin "$BRANCH" >/dev/null 2>&1 || true
    echo
    echo "🎉 推送成功！"
    echo "   https://github.com/${REPO_SLUG}"
    git branch --set-upstream-to="origin/$BRANCH" "$BRANCH" >/dev/null 2>&1 || true
    rm -f "$PUSH_LOG"
    quit 0
fi

cat "$PUSH_LOG"

if grep -qiE 'could not read Username|Authentication failed|terminal prompts disabled|Invalid username|403' "$PUSH_LOG"; then
    echo
    echo "❌ 推送时被 GitHub 拒了身份。"
    echo "   常见的两种：钥匙串里存的是旧令牌（已过期/撤销），或者令牌没勾 repo（写入）权限。"
    if ask_pat; then
        # 顺手把新令牌存好，省得下次再输
        printf 'protocol=https\nhost=github.com\nusername=%s\npassword=%s\n\n' \
            "$GH_USER" "$TOKEN" | git credential-osxkeychain store >/dev/null 2>&1 || true
        if have_cred; then
            PUSH_URL="origin"
            echo "   ✅ 新令牌已存入钥匙串"
        else
            PUSH_URL="https://${GH_USER}:${TOKEN}@github.com/${REPO_SLUG}.git"
            echo "   ℹ️  本次用临时凭据推送（不会写进仓库配置）"
        fi
        echo
        echo "⏳ 用新令牌再推一次..."
        if do_push >"$PUSH_LOG" 2>&1; then
            cat "$PUSH_LOG"
            # 用临时地址推的时候不认 origin，补一次 fetch 让 origin/main 跟上
            [ "$PUSH_URL" = "origin" ] || GIT_TERMINAL_PROMPT=0 git fetch -q origin "$BRANCH" >/dev/null 2>&1 || true
            echo
            echo "🎉 推送成功！"
            echo "   https://github.com/${REPO_SLUG}"
        else
            cat "$PUSH_LOG"
            echo
            echo "❌ 还是没通过。把上面这几行发我。"
        fi
    else
        echo
        echo "❌ 没拿到可用令牌。提交还在本地，重跑脚本不会白做。"
    fi

elif grep -qiE 'non-fast-forward|rejected|fetch first|behind its remote' "$PUSH_LOG"; then
    echo
    echo "⚠️  远端有新提交，拉下来重放一次..."
    if GIT_TERMINAL_PROMPT=0 git fetch origin "$BRANCH" && git --no-pager rebase "origin/$BRANCH"; then
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
