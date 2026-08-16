#Requires -Version 7.0
[CmdletBinding()]
param()

# Registers a "PCloudMount" scheduled task that mounts the pCloud drive in the
# interactive logon session of the RDP/AnyDesk user (Bullettemporary).
#
# Why: the workflow's own rclone mount (rclone-auth.ps1) lives in the runner's
# session-0 namespace, which a fresh RDP/AnyDesk logon session does NOT see.
# Mounting again on interactive logon makes pCloud appear as extra storage in
# the user's session and lets the synced backup data be browsed directly.
#
# Must run AFTER the RDP user is created (Enable RDP user and firewall step).

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

try {
    Write-Log 'setup-pcloud-interactive.ps1 starting...'
    $config = Get-Config
    $user = $config.anydesk.user

    if (-not (Get-LocalUser -Name $user -ErrorAction SilentlyContinue)) {
        Write-Log "User '$user' does not exist yet; skipping interactive pCloud mount task." -Level Warn
        $LASTEXITCODE = 0
        exit 0
    }

    $rcloneExe = Join-Path $config.tools.rclone.installDir 'rclone.exe'
    if (-not (Test-Path $rcloneExe)) {
        Write-Log "rclone not found at $rcloneExe; skipping interactive pCloud mount task." -Level Warn
        $LASTEXITCODE = 0
        exit 0
    }

    # Shared rclone config (also written by rclone-auth.ps1), readable by the
    # interactive user so no pCloud OAuth re-auth is needed at logon.
    $sharedConfig = Join-Path $config.tools.rclone.installDir 'rclone.conf'
    if (-not (Test-Path $sharedConfig)) {
        $appDataConfig = Expand-ConfigPath $config.rcloneConfigFile
        if (Test-Path $appDataConfig) {
            Copy-Item $appDataConfig $sharedConfig -Force
            Write-Log "Copied rclone config to shared location $sharedConfig"
        }
        elseif ($env:PCLOUD_CONFIG) {
            Set-Content -Path $sharedConfig -Value $env:PCLOUD_CONFIG -Encoding UTF8
            Write-Log "Wrote rclone config to shared location $sharedConfig"
        }
    }
    if (-not (Test-Path $sharedConfig)) {
        Write-Log 'No rclone config available; interactive pCloud mount will not be set up.' -Level Warn
        $LASTEXITCODE = 0
        exit 0
    }

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

    $mountPoint = $config.backupDrive
    $mountArgs = @(
        'mount', $config.pcloudRemote, $mountPoint,
        '--config', "`"$sharedConfig`"",
        '--vfs-cache-mode', $mountSettings.vfsCacheMode,
        '--vfs-cache-max-size', $mountSettings.vfsCacheMaxSize,
        '--vfs-write-back', $mountSettings.vfsWriteBack,
        '--dir-cache-time', $mountSettings.dirCacheTime,
        '--poll-interval', $mountSettings.pollInterval,
        '--buffer-size', $mountSettings.bufferSize,
        '--no-console'
    )
    $argLine = $mountArgs -join ' '

    $action = New-ScheduledTaskAction -Execute $rcloneExe -Argument $argLine
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName 'PCloudMount' -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

    Write-Log "Registered PCloudMount task: on logon of '$user', mount $($config.pcloudRemote) -> $mountPoint"
    if ($env:GITHUB_STEP_SUMMARY) {
        "### Interactive pCloud`n- **Task**: ``PCloudMount`` (on logon of ``$user``)`n- **Mount**: ``$mountPoint```n" | Out-File $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }

    Write-Log 'setup-pcloud-interactive.ps1 completed successfully.'
    $LASTEXITCODE = 0
    exit 0
}
catch {
    Write-Log "setup-pcloud-interactive.ps1 fatal error: $_" -Level Error
    $LASTEXITCODE = 1
    exit 1
}
