#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads FiveM server artifacts, extracts, unblocks files, and starts FXServer.

.PARAMETER Channel
    Latest = highest build number on master
    Recommended = marked "LATEST RECOMMENDED" (stable)
    Optional = marked "LATEST OPTIONAL"

.PARAMETER Force
    Download and install even if the same version is already installed.

.PARAMETER StartServer
    Start FXServer after updating.

.PARAMETER InstallStartupTask
    Register a scheduled task that runs at system startup.

.EXAMPLE
    .\Update-FiveMServer.ps1 -Channel Recommended

.EXAMPLE
    .\Update-FiveMServer.ps1 -InstallStartupTask
#>
[CmdletBinding()]
param(
    [ValidateSet('Latest', 'Recommended', 'Optional')]
    [string] $Channel,

    [switch] $Force,
    [switch] $StartServer,
    [switch] $InstallStartupTask,
    [switch] $RemoveStartupTask,
    [string] $ConfigPath
)

Set-StrictMode -Version Latest
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $ScriptRoot 'fivem-updater.config.json'
}
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string] $Message, [ValidateSet('INFO', 'WARN', 'ERROR')] [string] $Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $line
    }
}

function Get-Config {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config not found: $Path"
    }
    $cfg = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($Channel) { $cfg.Channel = $Channel }
    return $cfg
}

function Get-SevenZipExecutable {
    $candidates = @(
        "${env:ProgramFiles}\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
        (Join-Path $ScriptRoot 'tools\7zr.exe'),
        (Join-Path $ScriptRoot 'tools\7z.exe')
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) { return $path }
    }

    $toolsDir = Join-Path $ScriptRoot 'tools'
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    $sevenZip = Join-Path $toolsDir '7zr.exe'
    if (-not (Test-Path -LiteralPath $sevenZip)) {
        Write-Log "Downloading 7zr.exe (required to extract server.7z)..."
        $zipUrl = 'https://www.7-zip.org/a/7zr.exe'
        Invoke-WebRequest -Uri $zipUrl -OutFile $sevenZip -UseBasicParsing
        Unblock-File -LiteralPath $sevenZip -ErrorAction SilentlyContinue
    }
    return $sevenZip
}

function Get-ArtifactIndexHtml {
    param([string] $BaseUrl)
    $url = $BaseUrl.TrimEnd('/') + '/'
    return (Invoke-WebRequest -Uri $url -UseBasicParsing).Content
}

function Get-BuildFolders {
    param([string] $Html)
    $matches = [regex]::Matches($Html, '(\d+-[a-f0-9]+)/server\.7z')
    $folders = foreach ($m in $matches) { $m.Groups[1].Value }
    return $folders | Sort-Object -Descending { [int]($_ -split '-')[0] } -Unique
}

function Get-ArtifactFolderFromButton {
    param(
        [string] $Html,
        [string] $Label
    )
  # Search backward from the button label so RECOMMENDED is not matched to the OPTIONAL link.
    $needle = "LATEST $Label"
    $idx = $Html.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase)
    if ($idx -lt 0) { return $null }

    $start = [Math]::Max(0, $idx - 500)
    $chunk = $Html.Substring($start, $idx - $start)
    $matches = [regex]::Matches($chunk, '(\d+-[a-f0-9]+)/server\.7z')
    if ($matches.Count -eq 0) { return $null }
    return $matches[$matches.Count - 1].Groups[1].Value
}

function Resolve-ArtifactFolder {
    param(
        [string] $Html,
        [string] $ChannelName,
        [string[]] $Folders
    )

    switch ($ChannelName) {
        'Recommended' {
            $hit = Get-ArtifactFolderFromButton -Html $Html -Label 'RECOMMENDED'
            if ($hit) { return $hit }
            throw 'Could not find LATEST RECOMMENDED on the artifacts page.'
        }
        'Optional' {
            $hit = Get-ArtifactFolderFromButton -Html $Html -Label 'OPTIONAL'
            if ($hit) { return $hit }
            throw 'Could not find LATEST OPTIONAL on the artifacts page.'
        }
        default {
            if (-not $Folders -or $Folders.Count -eq 0) {
                throw 'No artifacts found on the master branch.'
            }
            return $Folders[0]
        }
    }
}

function Stop-FxServer {
    param([string] $InstallPath)
    $procs = Get-CimInstance Win32_Process -Filter "Name='FXServer.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -like "$InstallPath*") }
    foreach ($proc in $procs) {
        Write-Log "Stopping FXServer (PID $($proc.ProcessId))..."
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
}

function Unblock-FiveMFiles {
    param([string] $Path)
    Write-Log "Unblocking files in $Path (removes 'Blocked from internet')..."
    Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue
        }
}

function Test-FxServerRunning {
    param([string] $InstallPath)
    $running = Get-Process -Name 'FXServer' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like "$InstallPath*" }
    return [bool]$running
}

function Start-FxServer {
    param($Config)
    $exe = Join-Path $Config.InstallPath 'FXServer.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "FXServer.exe not found: $exe"
    }

    $args = @('+set', 'serverProfile', $Config.ServerProfile)
    if ($Config.TxAdminPort) {
        $args += '+set', 'txAdminPort', [string]$Config.TxAdminPort
    }
    if ($Config.ExtraFxServerArgs) {
        $args += ($Config.ExtraFxServerArgs -split '\s+')
    }

    Write-Log "Starting FXServer with profile '$($Config.ServerProfile)'..."
    Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory $Config.InstallPath
}

function Start-FxServerIfNeeded {
    param(
        $Config,
        [bool] $ShouldStart
    )
    if (-not $ShouldStart) { return $false }
    if (Test-FxServerRunning -InstallPath $Config.InstallPath) {
        Write-Log 'FXServer is already running.'
        return $true
    }
    Start-FxServer -Config $Config
    return $true
}

function Install-StartupScheduledTask {
    param($Config)
    $taskName = 'FiveM_Server_AutoUpdate_Start'
    $scriptPath = Join-Path $ScriptRoot 'Update-FiveMServer.ps1'
    $delay = [int]$Config.StartupDelaySeconds
    if ($delay -lt 0) { $delay = 0 }

    $channelArg = if ($Config.Channel) { " -Channel $($Config.Channel)" } else { '' }
    $argList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`"$channelArg -StartServer"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argList -WorkingDirectory $ScriptRoot
    $trigger = New-ScheduledTaskTrigger -AtStartup
  if ($delay -gt 0) { $trigger.Delay = "PT${delay}S" }
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Write-Log "Scheduled task registered: $taskName (channel: $($Config.Channel), ${delay}s delay on startup)"
}

function Remove-StartupScheduledTask {
    $taskName = 'FiveM_Server_AutoUpdate_Start'
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "Scheduled task removed (if it existed): $taskName"
}

try {
    $config = Get-Config -Path $ConfigPath
    foreach ($dir in @($config.CachePath, $config.LogPath, $config.InstallPath)) {
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    $script:LogFile = Join-Path $config.LogPath ("fivem-updater_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
    Write-Log "FiveM artifact update starting (channel: $($config.Channel))"

    if ($RemoveStartupTask) {
        Remove-StartupScheduledTask
        return
    }
    if ($InstallStartupTask) {
        Install-StartupScheduledTask -Config $config
        return
    }

    $shouldStartAfterUpdate = $StartServer -or [bool]$config.StartServerAfterUpdate
    $shouldStartWhenCurrent = $StartServer -or (-not [bool]$config.CheckOnlyOnStartup -and [bool]$config.StartServerAfterUpdate)
    $updateFailed = $false

    try {
        $html = Get-ArtifactIndexHtml -BaseUrl $config.ArtifactBaseUrl
        $folders = @(Get-BuildFolders -Html $html)
        $artifactFolder = Resolve-ArtifactFolder -Html $html -ChannelName $config.Channel -Folders $folders
        $buildNumber = ($artifactFolder -split '-')[0]
        $versionFile = Join-Path $config.InstallPath '.fivem-artifact-version'
        $installedVersion = if (Test-Path -LiteralPath $versionFile) { Get-Content -LiteralPath $versionFile -Raw } else { '' }
        $installedVersion = $installedVersion.Trim()

        $shouldUpdate = $Force -or ($installedVersion -ne $artifactFolder)
        if (-not $shouldUpdate) {
            Write-Log "Already on build $buildNumber ($artifactFolder). No update needed."
            Start-FxServerIfNeeded -Config $config -ShouldStart $shouldStartWhenCurrent | Out-Null
            return
        }

        Write-Log "New artifact: $artifactFolder (build $buildNumber)"

        if ($config.StopRunningServerBeforeUpdate) {
            Stop-FxServer -InstallPath $config.InstallPath
        }

        $downloadUrl = "{0}/{1}/server.7z" -f $config.ArtifactBaseUrl.TrimEnd('/'), $artifactFolder
        $archivePath = Join-Path $config.CachePath ("server_{0}.7z" -f $artifactFolder)
        Write-Log "Downloading $downloadUrl"
        Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -UseBasicParsing
        Unblock-File -LiteralPath $archivePath -ErrorAction SilentlyContinue

        $sevenZip = Get-SevenZipExecutable
        Write-Log "Extracting to $($config.InstallPath) ..."
        $extractArgs = @(
            'x', $archivePath,
            "-o$($config.InstallPath)",
            '-y', '-aoa'
        )
        $proc = Start-Process -FilePath $sevenZip -ArgumentList $extractArgs -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            throw "7-Zip failed with exit code $($proc.ExitCode)"
        }

        if ($config.UnblockFiles) {
            Unblock-FiveMFiles -Path $config.InstallPath
        }

        Set-Content -LiteralPath $versionFile -Value $artifactFolder -NoNewline
        Write-Log "Update complete. Version saved: $artifactFolder"

        Start-FxServerIfNeeded -Config $config -ShouldStart $shouldStartAfterUpdate | Out-Null
    }
    catch {
        $updateFailed = $true
        Write-Log $_.Exception.Message 'ERROR'
        if ($_.ScriptStackTrace) { Write-Log $_.ScriptStackTrace 'ERROR' }
        Write-Log 'Artifact update/check failed. Falling back to starting the existing FXServer install if requested.' 'WARN'

        if (-not $shouldStartAfterUpdate) {
            exit 1
        }

        try {
            Start-FxServerIfNeeded -Config $config -ShouldStart $true | Out-Null
            Write-Log 'FXServer start fallback completed after update failure.' 'WARN'
        }
        catch {
            Write-Log $_.Exception.Message 'ERROR'
            if ($_.ScriptStackTrace) { Write-Log $_.ScriptStackTrace 'ERROR' }
            exit 1
        }
    }

    if ($updateFailed) {
        # Server may be running on the previous build; keep exit 0 so boot tasks are not marked failed.
        Write-Log 'Finished with update failure but FXServer start was attempted.' 'WARN'
    }
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    if ($_.ScriptStackTrace) { Write-Log $_.ScriptStackTrace 'ERROR' }
    exit 1
}
