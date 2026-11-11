@echo off
rem Double-click to write rime-google-cantonese-report.txt to the Desktop (for bug reports).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnose.ps1" -Interactive
echo.
pause
