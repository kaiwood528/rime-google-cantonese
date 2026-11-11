@echo off
rem Double-click to install rime-google-cantonese (asks a few questions first).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Interactive
echo.
pause
