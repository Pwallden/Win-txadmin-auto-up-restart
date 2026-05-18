@echo off
REM Manuell start / uppdatering av FiveM-servern
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-FiveMServer.ps1" -StartServer
pause
