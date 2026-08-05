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
        [string]$DriveLetter
    )

    $driveName = $DriveLetter.TrimEnd(':')
    if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
        Write-Log "Drive $DriveLetter is already in use. Skipping mount."
        return
    }

    Write-Log "Mounting $Remote to $DriveLetter..."
    $mountArgs = @(
        'mount', $Remote, $DriveLetter,
        '--vfs-cache-mode', 'full',
        '--vfs-cache-max-size', '2G',
        '--dir-cache-time', '72h',
        '--poll-interval', '15s',
        '--no-console'
    )

    # Use Start-Process to run rclone in the background
    $process = Start-Process -FilePath $RcloneExe -ArgumentList $mountArgs -PassThru -WindowStyle Hidden
    
    # Wait for mount to become available
    $timeout = 30
    $elapsed = 0
    while (-not (Test-Path $DriveLetter) -and $elapsed -lt $timeout) {
        Start-Sleep -Seconds 2
        $elapsed += 2
    }

    if (-not (Test-Path $DriveLetter)) {
        $exitCode = $process.ExitCode
        throw "Mount failed for $DriveLetter (Timeout reached). Rclone exit code: $exitCode"
    }

    Write-Log "pCloud mounted successfully at $DriveLetter (PID: $($process.Id))."
    if ($env:GITHUB_STEP_SUMMARY) {
        "### pCloud Storage`n- **Status**: Mounted`n- **Remote**: ``$Remote```n- **Drive**: ``$DriveLetter``" | Out-File $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
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

    Install-PCloudConfig -ConfigContent $pcloudConfig -ConfigDir $configDir -ConfigFile $configFile
    Mount-PCloudDrive -RcloneExe $rcloneExe -Remote $config.pcloudRemote -DriveLetter $config.backupDrive

    Write-Log 'rclone-auth.ps1 completed successfully.'
    $LASTEXITCODE = 0
    exit 0
}
catch {
    Write-Log "rclone-auth.ps1 fatal error: $_" -Level Error
    $LASTEXITCODE = 1
    exit 1
}
