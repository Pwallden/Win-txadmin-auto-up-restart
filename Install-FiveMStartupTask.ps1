#Requires -RunAsAdministrator
# Registrerar automatisk FiveM-uppdatering + start vid Windows-uppstart.
# Använder alltid senaste build (Latest) från master-branchen.
& "$PSScriptRoot\Update-FiveMServer.ps1" -Channel Latest -InstallStartupTask
Write-Host ""
Write-Host "Klar. Uppgiften heter: FiveM_Server_AutoUpdate_Start"
Write-Host "Kanal: Latest (senaste build pa master)"
Write-Host "Ta bort med: .\Update-FiveMServer.ps1 -RemoveStartupTask"
Write-Host "Loggar: C:\Server\scripts\logs\"
