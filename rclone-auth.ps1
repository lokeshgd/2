#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Log {
    param([string]$Message, [ValidateSet('Info', 'Warn', 'Error')]$Level = 'Info')
    $prefix = switch ($Level) { 'Warn' { 'WARN' } 'Error' { 'ERROR' } default { 'INFO' } }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$prefix] $Message"
}

function Expand-ConfigPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    return [Environment]::ExpandEnvironmentVariables($Path)
}

function Get-Config {
    $configPath = Join-Path $PSScriptRoot 'config.json'
    if (-not (Test-Path $configPath)) {
        throw "config.json not found at $configPath"
    }
    return Get-Content $configPath -Raw | ConvertFrom-Json
}

function Ensure-Rclone {
    param($ToolConfig)
    $rcloneExe = Join-Path $ToolConfig.installDir 'rclone.exe'
    if (Test-Path $rcloneExe) {
        Write-Log "rclone already available at $rcloneExe"
        return $rcloneExe
    }

    Write-Log 'Installing rclone...'
    New-Item -ItemType Directory -Path $ToolConfig.installDir -Force | Out-Null
    $zipPath = Join-Path $env:TEMP 'rclone.zip'
    Invoke-WebRequest -Uri $ToolConfig.downloadUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 120
    Expand-Archive -Path $zipPath -DestinationPath $env:TEMP -Force

    $extracted = Get-ChildItem -Path $env:TEMP -Directory -Filter 'rclone-*-windows-amd64' | Select-Object -First 1
    if (-not $extracted) {
        throw 'Failed to locate extracted rclone directory in TEMP.'
    }

    Copy-Item -Path (Join-Path $extracted.FullName 'rclone.exe') -Destination $rcloneExe -Force
    $env:Path = "$($ToolConfig.installDir);$env:Path"
    Write-Log "rclone installed to $rcloneExe and added to PATH."
    return $rcloneExe
}

function Write-PCloudOAuthInstructions {
    Write-Log 'PCLOUD_CONFIG secret is missing — generating OAuth instructions.'
    Write-Log 'Skip pCloud mount for this run (non-fatal).' -Level Warn

    if ($env:GITHUB_STEP_SUMMARY) {
        @"
### pCloud Not Configured
The `PCLOUD_CONFIG` secret is not set, so the pCloud drive was not mounted and persistent file sync was skipped for this run.
Run the following on a machine with a browser to generate an rclone pcloud config block, then add it as the **PCLOUD_CONFIG** repository secret:

``````text
rclone config create pcloud pcloud
rclone authorize pcloud
``````
"@ | Out-File $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }
}

function Install-PCloudConfig {
    param(
        [string]$ConfigContent,
        [string]$ConfigDir,
        [string]$ConfigFile
    )

    if (-not (Test-Path $ConfigDir)) {
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    }

    if (Test-Path $ConfigFile) {
        $backup = "$ConfigFile.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
        Copy-Item $ConfigFile $backup -Force
        Write-Log "Existing rclone config backed up to $backup"
    }

    Set-Content -Path $ConfigFile -Value $ConfigContent -Encoding UTF8
    Write-Log "pCloud configuration written to $ConfigFile"
}

function Mount-PCloudDrive {
    param(
        [string]$RcloneExe,
        [string]$Remote,
        [string]$MountPath,
        $MountSettings
    )

    # Mount to a folder path (e.g. C:\pcloud). The mount MUST be owned by
    # Task Scheduler: the GitHub Actions Windows runner kills child processes
    # spawned by a step when that step ends, so a plain Start-Process rclone
    # mount vanished between steps (restore/backup never saw C:\pcloud). A
    # scheduled task survives step boundaries.
    # NOTE: rclone refuses to mount over an existing populated folder, so we
    # must NOT pre-create it — let rclone create the mount point.
    if (Test-Path $MountPath) {
        $hasChildren = @(Get-ChildItem -LiteralPath $MountPath -Force -ErrorAction SilentlyContinue).Count -gt 0
        if ($hasChildren) {
            Write-Log "Mount point $MountPath already populated. Skipping mount."
            return
        }
    }

    $taskName = 'PCloudMountRunner'
    $sharedConfig = Join-Path (Split-Path $RcloneExe -Parent) 'rclone.conf'
    if (-not (Test-Path $sharedConfig)) {
        throw "Shared rclone config not found at $sharedConfig."
    }

    $mountArgs = @(
        'mount', $Remote, $MountPath,
        '--config', "`"$sharedConfig`"",
        '--vfs-cache-mode', $MountSettings.vfsCacheMode,
        '--vfs-cache-max-size', $MountSettings.vfsCacheMaxSize,
        '--vfs-write-back', $MountSettings.vfsWriteBack,
        '--dir-cache-time', $MountSettings.dirCacheTime,
        '--poll-interval', $MountSettings.pollInterval,
        '--buffer-size', $MountSettings.bufferSize,
        '--no-console'
    )
    $argLine = $mountArgs -join ' '

    Write-Log "Mounting $Remote to $MountPath via scheduled task $taskName..."
    $action = New-ScheduledTaskAction -Execute $RcloneExe -Argument $argLine
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName

    # The remote root contains a known 'Backup' folder from prior runs; its
    # presence through the mount proves the VFS is serving remote data.
    $probe = Join-Path $MountPath 'Backup'
    $timeout = 120
    $elapsed = 0
    $ready = $false
    $taskInfo = $null
    while ($elapsed -lt $timeout) {
        Start-Sleep -Seconds 2
        $elapsed += 2

        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
        $ready = Test-Path -LiteralPath $probe -ErrorAction SilentlyContinue
        if ($ready) { break }
    }

    if (-not $ready) {
        $lastResult = if ($taskInfo) { $taskInfo.LastTaskResult } else { 'unknown' }
        throw "Mount failed for $MountPath (probe '$probe' never appeared within ${timeout}s; task last result: $lastResult)."
    }

    Write-Log "pCloud mounted successfully at $MountPath (task $taskName)."
    if ($env:GITHUB_STEP_SUMMARY) {
        "### pCloud Storage`n- **Status**: Mounted`n- **Remote**: ``$Remote```n- **Path**: ``$MountPath``" | Out-File $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }
}

try {
    Write-Log 'rclone-auth.ps1 starting...'
    $config = Get-Config
    $pcloudConfig = $env:PCLOUD_CONFIG

    if ([string]::IsNullOrWhiteSpace($pcloudConfig)) {
        Write-PCloudOAuthInstructions
        # Do NOT run 'rclone authorize' here: it blocks indefinitely on a
        # headless runner. Exit cleanly so the workflow continues.
        $LASTEXITCODE = 0
        exit 0
    }

    $rcloneExe = Ensure-Rclone -ToolConfig $config.tools.rclone

    $configDir = Expand-ConfigPath $config.rcloneConfigDir
    $configFile = Expand-ConfigPath $config.rcloneConfigFile

    # Mount tuning from config.performance.rclone (falls back to sane defaults).
    $mountSettings = $config.performance.rclone
    if (-not $mountSettings) {
        $mountSettings = @{
            vfsCacheMode    = 'writes'
            vfsCacheMaxSize = '2G'
            vfsWriteBack    = '5s'
            dirCacheTime    = '72h'
            pollInterval    = '15s'
            bufferSize      = '128M'
        }
    }

    Install-PCloudConfig -ConfigContent $pcloudConfig -ConfigDir $configDir -ConfigFile $configFile

    # Also write the config next to the rclone binary so interactive (RDP/AnyDesk)
    # sessions can mount pCloud with the same credentials via the PCloudMount task.
    $sharedConfigDir = $config.tools.rclone.installDir
    if (-not (Test-Path $sharedConfigDir)) { New-Item -ItemType Directory -Path $sharedConfigDir -Force | Out-Null }
    Copy-Item $configFile (Join-Path $sharedConfigDir 'rclone.conf') -Force

    Mount-PCloudDrive -RcloneExe $rcloneExe -Remote $config.pcloudRemote -MountPath $config.backupDrive -MountSettings $mountSettings

    Write-Log 'rclone-auth.ps1 completed successfully.'
    $LASTEXITCODE = 0
    exit 0
}
catch {
    Write-Log "rclone-auth.ps1 fatal error: $_" -Level Error
    $LASTEXITCODE = 1
    exit 1
}
