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

    # Mount to a folder path (e.g. C:\pcloud) instead of a drive letter so the
    # mount is visible in every logon session (RDP + AnyDesk), not just the
    # runner's session-0 where the mount command runs.
    # NOTE: rclone refuses to mount over an existing folder ("mountpoint path
    # already exists"), so we must NOT pre-create it — let rclone create it.
    if (Test-Path $MountPath) {
        $hasChildren = @(Get-ChildItem -LiteralPath $MountPath -Force -ErrorAction SilentlyContinue).Count -gt 0
        if ($hasChildren) {
            Write-Log "Mount point $MountPath already populated. Skipping mount."
            return
        }
    }

    # Capture rclone's output so failures are visible instead of a blind timeout.
    $outLog = Join-Path $env:TEMP 'rclone-mount.out.log'
    $errLog = Join-Path $env:TEMP 'rclone-mount.err.log'

    Write-Log "Mounting $Remote to $MountPath..."
    $mountArgs = @(
        'mount', $Remote, $MountPath,
        '--vfs-cache-mode', $MountSettings.vfsCacheMode,
        '--vfs-cache-max-size', $MountSettings.vfsCacheMaxSize,
        '--vfs-write-back', $MountSettings.vfsWriteBack,
        '--dir-cache-time', $MountSettings.dirCacheTime,
        '--poll-interval', $MountSettings.pollInterval,
        '--buffer-size', $MountSettings.bufferSize,
        '--no-console'
    )

    # Use Start-Process to run rclone in the background with logged output.
    $process = Start-Process -FilePath $RcloneExe -ArgumentList $mountArgs `
                             -PassThru -WindowStyle Hidden `
                             -RedirectStandardOutput $outLog -RedirectStandardError $errLog

    # Run rclone below-normal priority so backup I/O does not starve the RDP/AnyDesk session.
    try {
        $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
        Write-Log "rclone (PID $($process.Id)) set to BelowNormal priority."
    }
    catch {
        Write-Log "Could not set rclone priority: $_" -Level Warn
    }

    # The remote root contains a known 'Backup' folder from prior runs; its
    # presence through the mount proves the VFS is serving remote data.
    $probe = Join-Path $MountPath 'Backup'
    $timeout = 120
    $elapsed = 0
    $ready = $false
    while ($elapsed -lt $timeout) {
        Start-Sleep -Seconds 2
        $elapsed += 2

        if ($process.HasExited) {
            $err = if (Test-Path $errLog) { (Get-Content $errLog -Raw -ErrorAction SilentlyContinue) } else { '' }
            $out = if (Test-Path $outLog) { (Get-Content $outLog -Raw -ErrorAction SilentlyContinue) } else { '' }
            throw "rclone exited early (code $($process.ExitCode)).`nSTDERR: $err`nSTDOUT: $out"
        }

        $ready = Test-Path -LiteralPath $probe -ErrorAction SilentlyContinue
        if ($ready) { break }
    }

    if (-not $ready) {
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        $err = if (Test-Path $errLog) { (Get-Content $errLog -Raw -ErrorAction SilentlyContinue) } else { '' }
        throw "Mount failed for $MountPath (Timeout reached, probe '$probe' never appeared).`nSTDERR: $err"
    }

    Write-Log "pCloud mounted successfully at $MountPath (PID: $($process.Id))."
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
