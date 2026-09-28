#Requires -Version 7.0
[CmdletBinding()]
param(
    # How many of the newest workflow runs to keep. Everything older is
    # deleted so the run history cannot grow forever during the 6-hour loop.
    [int]$Keep = 5
)

# Best-effort housekeeping: any failure is logged and swallowed so pruning can
# never break the RDP session. Runs while a job is executing, so the current
# run is always part of the newest $Keep and is never deleted.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Log {
    param([string]$Message, [ValidateSet('Info', 'Warn')]$Level = 'Info')
    $prefix = if ($Level -eq 'Warn') { 'WARN' } else { 'INFO' }
    Write-Host "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [$prefix] $Message"
}

try {
    $repo  = $env:GITHUB_REPOSITORY
    $token = "$env:GH_TOKEN".Trim()

    if (-not $repo -or -not $token) {
        Write-Log 'prune-runs.ps1: missing GITHUB_REPOSITORY or GH_TOKEN; skipping.' -Level Warn
        return
    }
    if ($Keep -lt 1) { $Keep = 1 }

    $headers = @{
        Authorization = "Bearer $token"
        Accept        = 'application/vnd.github+json'
        'User-Agent'  = 'rdp-run-pruner'
    }

    $runs = @()
    for ($page = 1; $page -le 10; $page++) {
        $uri  = "https://api.github.com/repos/$repo/actions/runs?per_page=100&page=$page"
        $resp = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
        if (-not $resp.workflow_runs -or $resp.workflow_runs.Count -eq 0) { break }
        $runs += $resp.workflow_runs
        if ($resp.workflow_runs.Count -lt 100) { break }
    }

    Write-Log "Found $($runs.Count) run(s); keeping the newest $Keep."

    $ordered = $runs | Sort-Object { [datetime]$_.created_at } -Descending
    $victims = $ordered | Select-Object -Skip $Keep

    $deleted = 0
    foreach ($r in $victims) {
        if ($r.status -ne 'completed') {
            Write-Log "Skip run $($r.run_number) (id $($r.id)): status=$($r.status)." -Level Warn
            continue
        }
        try {
            Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/actions/runs/$($r.id)" `
                -Headers $headers -Method Delete | Out-Null
            $deleted++
            Write-Log "Deleted run $($r.run_number) (id $($r.id), $($r.created_at))."
        }
        catch {
            Write-Log "Could not delete run $($r.run_number): $($_.Exception.Message)" -Level Warn
        }
    }

    Write-Log "prune-runs.ps1 done; deleted $deleted run(s)."
}
catch {
    Write-Log "prune-runs.ps1 failed: $_" -Level Warn
}
