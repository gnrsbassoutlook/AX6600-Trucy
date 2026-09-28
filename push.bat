@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
cd /d "%~dp0"

rem ■ 关掉分页器：否则 git 输出超过一屏会自动进 less，停在 ":" 等你按 q
set "GIT_PAGER=cat"
set "PAGER=cat"

rem ============================================================
rem  AX6600-Trucy  一键推送（Windows）
rem  ============================================================
set "REPO_HTTPS=https://github.com/gnrsbassoutlook/AX6600-Trucy.git"
set "BRANCH=main"

echo ==========================================
echo  AX6600-Trucy  GitHub 一键推送
echo ==========================================
echo.

rem ---------- 0. 环境 ----------
where git >nul 2>&1
if errorlevel 1 (
    echo [X] 没找到 git。先装 Git for Windows: https://git-scm.com/download/win
    pause
    exit /b 1
)

rem ---------- 1. 初始化 / 校正远端 ----------
if not exist ".git" (
    echo [1/6] 初始化 git 仓库...
    git init -q
    git branch -M %BRANCH%
)

for /f "delims=" %%a in ('git remote get-url origin 2^>nul') do set "CUR=%%a"
if "!CUR!"=="" (
    echo [1/6] 添加远端 -^> %REPO_HTTPS%
    git remote add origin %REPO_HTTPS%
) else if not "!CUR!"=="%REPO_HTTPS%" (
    echo [1/6] 远端地址已更新 -^> %REPO_HTTPS%
    git remote set-url origin %REPO_HTTPS%
)

rem ---------- 2. 身份（只写本仓库，不动全局配置） ----------
git config user.name  >nul 2>&1 || git config user.name  "gnrsbassoutlook"
git config user.email >nul 2>&1 || git config user.email "gnrsbassoutlook@users.noreply.github.com"

rem ---------- 3. 对齐远端历史 ----------
rem 远端可能已有提交，不先接上去直接 push 一定被拒
git rev-parse --verify -q HEAD >nul 2>&1
if errorlevel 1 (
    echo [2/6] 读取远端历史...
    git fetch -q origin %BRANCH% >nul 2>&1
    if not errorlevel 1 (
        git rev-parse --verify -q origin/%BRANCH% >nul 2>&1
        if not errorlevel 1 (
            git reset -q --mixed origin/%BRANCH%
            echo       已接到远端 %BRANCH% 分支之后
        )
    )
)

rem ---------- 4. 看改动 ----------
git add -A
echo.
echo [3/6] 改动：
git --no-pager diff --cached --quiet
if not errorlevel 1 (
    echo       ^(没有改动^)
    echo.
    echo [OK] 工作区是干净的，没有东西要推。
    echo.
    pause
    exit /b 0
)
git --no-pager diff --cached --stat
echo.
git --no-pager diff --cached --name-status | findstr /b "D" >nul 2>&1
if not errorlevel 1 (
    echo       删除项 —— 确认是你要删的：
    git --no-pager diff --cached --name-status | findstr /b "D"
    echo.
)

echo.
set "ok="
set /p ok=确认推送以上改动？[Y/n] 
if /i "!ok!"=="n" (
    echo 已取消。
    pause
    exit /b 0
)

set "msg="
set /p msg=Commit 说明（直接回车用默认）: 
if "!msg!"=="" (
    for /f %%a in ('powershell -NoProfile Get-Date -Format "yyyy-MM-dd HH:mm:ss"') do set "msg=Auto update: %%a"
)

rem ---------- 5. 提交并推送 ----------
echo.
echo [4/6] 提交中...
git commit -q -m "!msg!"
echo       !msg!

echo [5/6] 推送到 GitHub...
git push -u origin %BRANCH%
if not errorlevel 1 (
    echo.
    echo 推送成功！
    echo    https://github.com/gnrsbassoutlook/AX6600-Trucy
) else (
    echo.
    echo 推送被拒（一般是远端有新提交），试着重放一次...
    git pull --rebase origin %BRANCH%
    if errorlevel 1 (
        echo.
        echo [X] 重放失败，有冲突需要手动处理。
        echo     你的提交还在，没丢： git log --oneline
    ) else (
        git push -u origin %BRANCH%
        if errorlevel 1 (
            echo.
            echo [X] 推送仍然失败，把上面的报错发我看看。
        ) else (
            echo.
            echo 重放后推送成功！
        )
    )
)

echo.
pause
