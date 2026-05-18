@echo off
REM Manual update / start of the FiveM server
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-FiveMServer.ps1" -StartServer
pause
