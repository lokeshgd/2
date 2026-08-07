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

function Get-Config {
    $configPath = Join-Path $PSScriptRoot 'config.json'
    if (-not (Test-Path $configPath)) {
        throw "config.json not found at $configPath"
    }
    return Get-Content $configPath -Raw | ConvertFrom-Json
}

function Set-HighPriorityProcesses {
    param([string[]]$ProcessNames)

    foreach ($name in $ProcessNames) {
        try {
            $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
            foreach ($p in $procs) {
                try {
                    $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
                    Write-Log "Set '$name' (PID $($p.Id)) to High priority."
                }
                catch {
                    Write-Log "Could not set priority for '$name' (PID $($p.Id)): $_" -Level Warn
                }
            }
        }
        catch {
            Write-Log "Process lookup failed for '$name': $_" -Level Warn
        }
    }
}

try {
    Write-Log 'optimize.ps1 starting...'
    $config = Get-Config
    $names = @('mstsc', 'Tailscale', 'AnyDesk', 'svchost')

    if ($config.performance -and $config.performance.highPriorityProcesses) {
        $names = @($config.performance.highPriorityProcesses)
    }

    # 'svchost' is generic; only boost the Terminal Services host (TermService).
    Set-HighPriorityProcesses -ProcessNames ($names | Where-Object { $_ -ne 'svchost' })

    # Boost the Terminal Services host process so RDP stays smooth.
    try {
        $ts = Get-CimInstance Win32_Service -Filter "Name='TermService'" -ErrorAction SilentlyContinue
        if ($ts -and $ts.ProcessId -gt 0) {
            $proc = Get-Process -Id $ts.ProcessId -ErrorAction SilentlyContinue
            if ($proc) {
                $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
                Write-Log "Set TermService (PID $($ts.ProcessId)) to High priority."
            }
        }
    }
    catch {
        Write-Log "TermService priority boost failed: $_" -Level Warn
    }

    Write-Log 'optimize.ps1 completed successfully.'
    # Non-fatal utility: always report success so the workflow continues.
    $LASTEXITCODE = 0
    exit 0
}
catch {
    Write-Log "optimize.ps1 fatal error: $_" -Level Error
    $LASTEXITCODE = 0
    exit 0
}
