@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Clear-SegmentCopyLogs.ps1" %*
exit /b %ERRORLEVEL%
