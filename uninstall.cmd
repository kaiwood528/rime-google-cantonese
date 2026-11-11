@echo off
rem Double-click to remove rime-google-cantonese. Weasel and the Cantonese schema stay installed.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" -Interactive
echo.
pause
