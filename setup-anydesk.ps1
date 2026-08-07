#Requires -Version 7.0
[CmdletBinding()]
param()

# Installs and configures AnyDesk AFTER persistent state has been restored.
# Runs after persistent-state.ps1 -Action Restore so that %ProgramData%\AnyDesk
# (service.conf / system.conf containing the machine ID) is in place before the
# AnyDesk service starts. This reuses the same AnyDesk ID across runners.

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

function Install-AnyDesk {
    param($ToolConfig, $AnyConfig, [string]$Password)
    try {
        $binary = Expand-ConfigPath $ToolConfig.binary
        if (Test-Path $binary) {
            Write-Log "AnyDesk already installed at $binary"
        }
        else {
            $installer = Join-Path $env:TEMP 'AnyDesk.exe'
            Write-Log "Downloading AnyDesk from $($ToolConfig.downloadUrl)..."
            Invoke-WebRequest -Uri $ToolConfig.downloadUrl -OutFile $installer -UseBasicParsing -TimeoutSec 120

            $installDir = $ToolConfig.installDir
            $args = @(
                '--install', "`"$installDir`"",
                '--start-with-win',
                '--create-shortcuts',
                '--silent'
            )
            Write-Log 'Installing AnyDesk silently...'
            $proc = Start-Process -FilePath $installer -ArgumentList ($args -join ' ') -PassThru
            if (-not $proc.WaitForExit(120000)) {
                Write-Log 'AnyDesk installer did not exit within 2 minutes; continuing.' -Level Warn
            }
            Start-Sleep -Seconds 5
        }

        if (-not (Test-Path $binary)) {
            throw "AnyDesk binary not found at $binary after installation."
        }

        # AnyDesk needs its service/process running before --set-password and --get-id work.
        # Start the service and wait until it reports Running (the daemon answers --get-id).
        $svc = Get-Service -Name 'AnyDesk' -ErrorAction SilentlyContinue
        if ($svc) {
            try {
                Write-Log "Starting AnyDesk service (current status: $($svc.Status))..."
                Start-Service -Name 'AnyDesk' -ErrorAction Stop
            }
            catch {
                Write-Log "Start-Service failed ($_), retrying via sc.exe..." -Level Warn
                sc.exe start AnyDesk 2>&1 | Out-Null
            }
            $deadline = (Get-Date).AddSeconds(60)
            while ((Get-Service -Name 'AnyDesk' -ErrorAction SilentlyContinue).Status -ne 'Running' -and (Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 3
            }
            $svc = Get-Service -Name 'AnyDesk' -ErrorAction SilentlyContinue
            Write-Log "AnyDesk service status now: $($svc.Status)"
        }
        else {
            Write-Log 'AnyDesk service not registered; relying on the GUI process instead.' -Level Warn
        }

        # Ensure a running AnyDesk process exists (the daemon responds to --get-id).
        if (-not (Get-Process -Name 'AnyDesk' -ErrorAction SilentlyContinue)) {
            Start-Process -FilePath $binary | Out-Null
            Start-Sleep -Seconds 5
        }

        if ($Password) {
            Write-Log "Configuring AnyDesk unattended access for user: $($AnyConfig.user)..."
            $Password | & $binary --set-password 2>&1 | Out-Null
            Start-Sleep -Seconds 3
        }

        # Retrieve the AnyDesk ID (longer retry window; a fresh VM can be slow).
        $anydeskId = ''
        for ($i = 1; $i -le 12; $i++) {
            $outFile = Join-Path $env:TEMP "anydesk-id-$i.txt"
            $errFile = Join-Path $env:TEMP "anydesk-err-$i.txt"
            $p = Start-Process -FilePath $binary -ArgumentList '--get-id' -NoNewWindow -Wait `
                -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru
            $raw = ''
            if (Test-Path $outFile) { $raw = (Get-Content $outFile -Raw -ErrorAction SilentlyContinue) }
            $anydeskId = (($raw.Trim() -split '\s+') | Where-Object { $_ -match '^\d{6,12}$' } | Select-Object -First 1)
            if ($anydeskId) { break }
            $anydeskId = ''
            if (-not (Get-Process -Name 'AnyDesk' -ErrorAction SilentlyContinue)) {
                Start-Process -FilePath $binary | Out-Null
            }
            Start-Sleep -Seconds 5
        }

        # Fallback: read the machine ID from system.conf if present.
        if (-not $anydeskId) {
            $systemConf = Join-Path $env:ProgramData 'AnyDesk\system.conf'
            if (Test-Path $systemConf) {
                $confLine = Get-Content $systemConf -ErrorAction SilentlyContinue | Where-Object { $_ -match 'ad\.anynet\.id' }
                if ($confLine) {
                    $anydeskId = (($confLine -split '=', 2)[1]).Trim()
                    Write-Log "AnyDesk ID read from system.conf: $anydeskId"
                }
            }
        }

        if ($anydeskId) {
            $anydeskId = $anydeskId.Trim()
            Write-Log "AnyDesk ID: $anydeskId"
            if ($env:GITHUB_STEP_SUMMARY) {
                "### AnyDesk`n- **ID**: ``$anydeskId```n- **User**: ``$($AnyConfig.user)``" | Out-File $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
            }
        }
        else {
            Write-Log "AnyDesk installed but the AnyDesk ID could not be retrieved after 12 attempts." -Level Warn
        }
    }
    catch {
        Write-Log "AnyDesk install/configure failed: $_" -Level Warn
    }
}

try {
    Write-Log 'setup-anydesk.ps1 starting (after restore, reusing machine ID)...'
    $config = Get-Config

    $password = $env:RDP_PASS
    if (-not $password -and $config.anydesk.passwordEnv) {
        $password = [Environment]::GetEnvironmentVariable($config.anydesk.passwordEnv)
    }

    Install-AnyDesk -ToolConfig $config.tools.anydesk -AnyConfig $config.anydesk -Password $password

    Write-Log 'setup-anydesk.ps1 completed successfully.'
    $LASTEXITCODE = 0
    exit 0
}
catch {
    Write-Log "setup-anydesk.ps1 fatal error: $_" -Level Error
    $LASTEXITCODE = 1
    exit 1
}
