@echo off
chcp 65001 >nul
title 素材收割球
cd /d "%~dp0"

echo ============================================
echo   素材收割球 · 启动器
echo ============================================
echo.

rem ---------- 1. 找 Python：内置 runtime > config.json > PATH ----------
set "PY="
if exist "%~dp0runtime\python\pythonw.exe" set "PY=%~dp0runtime\python\pythonw.exe"
if not defined PY if exist "%~dp0runtime\python\python.exe" set "PY=%~dp0runtime\python\python.exe"

rem config.json 里可指定 python 绝对路径（用 PowerShell 解析 JSON）
if not defined PY if exist "%~dp0config.json" (
    for /f "usebackq delims=" %%v in (`powershell -NoProfile -Command "try { $c = Get-Content -LiteralPath '%~dp0config.json' -Raw ^| ConvertFrom-Json; if ($c.python -and (Test-Path -LiteralPath $c.python)) { $c.python } } catch {}"`) do set "PY=%%v"
)

if not defined PY where pythonw >nul 2>&1 && set "PY=pythonw"
if not defined PY where python >nul 2>&1 && set "PY=python"
if not defined PY where py >nul 2>&1 && set "PY=py"

if not defined PY (
    echo [错误] 没找到 Python 3。
    echo   便携版应自带 runtime\python；若缺失，请重新解压完整包。
    echo   也可安装 Python 3 并勾选 "Add Python to PATH"，或在 config.json 里指定路径。
    echo.
    pause
    exit /b 1
)

rem ---------- 2. 依赖检查 ----------
echo [1/3] 检查 Python 依赖...
%PY% -c "import comtypes" >nul 2>&1
if errorlevel 1 (
    echo       正在安装 comtypes ...
    %PY% -m pip install comtypes
)

echo [2/3] 启动后端服务...
start "素材收割球后端" /min "%PY%" server.py

echo [3/3] 启动悬浮球...
timeout /t 2 /nobreak >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ball.ps1"

echo.
echo 已退出。
