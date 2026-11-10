@echo off
setlocal EnableExtensions
cd /d "%~dp0"
set "PYTHONIOENCODING=utf-8"
set "PYTHONUTF8=1"
set "HF_ENDPOINT=https://hf-mirror.com"
set "HF_HUB_DISABLE_SYMLINKS_WARNING=1"
chcp 65001 >nul
title Запуск расшифровки видео [Whisper AI - Python 3.14 / 3.15]
color 0F

if not exist "translate_v4_argon.py" (
    color 0C
    echo [!] ОШИБКА: Файл translate_v4_argon.py не найден!
    echo [*] Сначала запустите файл "Install Whisper.bat" для скачивания нужных компонентов.
    echo.
    pause
    exit /b 1
)

set "REQ_PY=%~1"
set "PY_CMD="

if not "%REQ_PY%"=="" goto :HANDLE_REQ_PY

python --version >nul 2>&1
if not errorlevel 1 (
    set "PY_CMD=python"
    goto :RUN_NOW
)

py -3.14 --version >nul 2>&1
if not errorlevel 1 (
    set "PY_CMD=py -3.14"
    goto :RUN_NOW
)

py -3.15 --version >nul 2>&1
if not errorlevel 1 (
    set "PY_CMD=py -3.15"
    goto :RUN_NOW
)

py --version >nul 2>&1
if not errorlevel 1 (
    set "PY_CMD=py"
    goto :RUN_NOW
)

goto :NO_PYTHON

:HANDLE_REQ_PY
py -%REQ_PY% --version >nul 2>&1
if not errorlevel 1 (
    set "PY_CMD=py -%REQ_PY%"
    goto :RUN_NOW
)

set "SYS_VER="
for /f "delims=" %%v in ('python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2^>nul') do set "SYS_VER=%%v"
if "%SYS_VER%"=="%REQ_PY%" (
    set "PY_CMD=python"
    goto :RUN_NOW
)

color 0C
echo [!] ОШИБКА: Python %REQ_PY% не найден в системе!
echo [*] Запустите "Install Whisper (Python %REQ_PY%).bat" для установки.
echo.
pause
exit /b 1

:NO_PYTHON
color 0C
echo [!] ОШИБКА: Интерпретатор Python не найден в системе!
pause
exit /b 1

:RUN_NOW
echo [*] Запуск скрипта расшифровки через: %PY_CMD%
echo [*] Зеркало Hugging Face: %HF_ENDPOINT%
echo.
%PY_CMD% "translate_v4_argon.py"
echo.
pause
exit /b 0
