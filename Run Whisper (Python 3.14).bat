@echo off
cd /d "%~dp0"
call "%~dp0Run Whisper.bat" --py 3.14 %*
