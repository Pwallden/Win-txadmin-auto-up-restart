#Requires -RunAsAdministrator
# Registers automatic FiveM update + start on Windows boot.
# Always uses the Latest build from the master branch.
& "$PSScriptRoot\Update-FiveMServer.ps1" -Channel Latest -InstallStartupTask
Write-Host ""
Write-Host "Done. Task name: FiveM_Server_AutoUpdate_Start"
Write-Host "Channel: Latest (newest build on master)"
Write-Host "Remove with: .\Update-FiveMServer.ps1 -RemoveStartupTask"
Write-Host "Logs: C:\Server\scripts\logs\"
