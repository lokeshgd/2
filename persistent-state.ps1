#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Restore', 'Backup')]
    [string]$Action
)

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

function Test-BackupAvailable {
    param([string]$BackupRoot, [string]$DriveLetter)
    if (-not (Test-Path $DriveLetter)) {
        Write-Log "Backup drive $DriveLetter is not mounted." -Level Warn
        return $false
    }
    return $true
}

function Sync-Directory {
    param(
        [string]$LocalPath,
        [string]$RemotePath,
        [ValidateSet('Restore', 'Backup')]
        [string]$Direction
    )

    if ($Direction -eq 'Restore') {
        $from = $RemotePath
        $to = $LocalPath
    }
    else {
        $from = $LocalPath
        $to = $RemotePath
    }

    if (-not (Test-Path $from)) {
        Write-Log "Skipping sync: source path missing ($from)" -Level Warn
        return
    }

    if (-not (Test-Path $to)) {
        New-Item -ItemType Directory -Path $to -Force | Out-Null
    }

    Write-Log "Syncing ($Direction): $from -> $to"
    
    # Robocopy options: /MIR (Mirror), /R:2 (Retry), /W:2 (Wait), /NFL (No File List), /NDL (No Dir List)
    $robocopyArgs = @($from, $to, '/MIR', '/R:2', '/W:2', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    
    # robocopy returns 0-7 for success, 8+ for failure
    & robocopy @robocopyArgs | Out-Null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ge 8) {
        throw "Robocopy failed with exit code $exitCode during $Direction."
    }
    Write-Log "Sync completed successfully."
}

function Get-GitHubOwner {
    if ($env:GITHUB_REPOSITORY -match '^([^/]+)/') {
        return $Matches[1]
    }
    throw 'GITHUB_REPOSITORY environment variable is missing or invalid.'
}

function Ensure-DataRepo {
    param(
        [string]$RepoName,
        [string]$Token,
        [string]$LocalPath
    )

    $owner = Get-GitHubOwner
    $headers = @{
        Authorization = "Bearer $Token"
        Accept        = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }

    $repoUrl = "https://api.github.com/repos/$owner/$RepoName"
    try {
        $null = Invoke-RestMethod -Method GET -Uri $repoUrl -Headers $headers
        Write-Log "Verified GitHub repository: $owner/$RepoName"
    }
    catch {
        Write-Log "Repository $owner/$RepoName not found. Attempting to create private repo..."
        $body = @{
            name       = $RepoName
            private    = $true
            description = 'Persistent DevOps Configuration and Metadata'
            auto_init  = $true
        } | ConvertTo-Json
        $null = Invoke-RestMethod -Method POST -Uri "https://api.github.com/user/repos" -Headers $headers -Body $body
        Write-Log "Repository $owner/$RepoName created."
    }

    $remote = "https://x-access-token:$Token@github.com/$owner/$RepoName.git"
    if (-not (Test-Path (Join-Path $LocalPath '.git'))) {
        Write-Log "Initializing local Data repository at $LocalPath..."
        New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null
        Push-Location $LocalPath
        try {
            & git init
            & git remote add origin $remote
            & git fetch origin
            & git checkout -B main
            & git pull origin main --allow-unrelated-histories 2>$null
        }
        finally {
            Pop-Location
        }
    }
}

function Publish-DataRepo {
    param(
        [string]$RepoName,
        [string]$Token,
        [string]$LocalPath,
        [string]$BackupRoot
    )

    if ([string]::IsNullOrWhiteSpace($Token)) {
        Write-Log 'GH_TOKEN missing. Skipping Data repository sync.' -Level Warn
        return
    }

    Ensure-DataRepo -RepoName $RepoName -Token $Token -LocalPath $LocalPath

    # Create a clean snapshot of configuration and state metadata
    $snapshotDir = Join-Path $LocalPath 'state-snapshot'
    if (Test-Path $snapshotDir) { Remove-Item $snapshotDir -Recurse -Force }
    New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null

    # Copy config.json
    Copy-Item (Join-Path $PSScriptRoot 'config.json') (Join-Path $snapshotDir 'config.json') -Force

    # Generate metadata manifest
    $manifest = @{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        backupRoot = $BackupRoot
        sourceRepository = $env:GITHUB_REPOSITORY
        workflowRunId = $env:GITHUB_RUN_ID
        tools = @{
            pwshVersion = $PSVersionTable.PSVersion.ToString()
            os = [Environment]::OSVersion.VersionString
        }
    } | ConvertTo-Json -Depth 5
    Set-Content -Path (Join-Path $snapshotDir 'manifest.json') -Value $manifest -Encoding UTF8

    Write-Log "Pushing state snapshot to GitHub..."
    Push-Location $LocalPath
    try {
        & git config user.email 'github-actions[bot]@users.noreply.github.com'
        & git config user.name 'github-actions[bot]'
        & git add -A
        $status = & git status --porcelain
        if (-not $status) {
            Write-Log 'No changes detected in Data repository.'
            return
        }

        & git commit -m "State backup: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC [Run $env:GITHUB_RUN_ID]"
        & git push origin main
        Write-Log "Data repository updated successfully."
    }
    finally {
        Pop-Location
    }
}

try {
    Write-Log "persistent-state.ps1 starting (Action=$Action)..."
    $config = Get-Config
    $backupRoot = Expand-ConfigPath $config.backupRoot
    $backupDrive = $config.backupDrive
    $dataRepoLocal = Expand-ConfigPath $config.dataRepoLocalPath
    $token = $env:GH_TOKEN

    if ($Action -eq 'Restore') {
        if (-not (Test-BackupAvailable -BackupRoot $backupRoot -DriveLetter $backupDrive)) {
            Write-Log 'Backup drive unavailable. Starting with clean state.' -Level Warn
        }
        else {
            foreach ($entry in $config.syncPaths.PSObject.Properties) {
                $paths = $entry.Value
                Sync-Directory -LocalPath (Expand-ConfigPath $paths.local) `
                               -RemotePath (Expand-ConfigPath $paths.remote) `
                               -Direction 'Restore'
            }
        }
    }
    else {
        # Backup Action
        if (-not (Test-BackupAvailable -BackupRoot $backupRoot -DriveLetter $backupDrive)) {
            Write-Log 'Backup drive unavailable. Skipping file sync.' -Level Warn
        }
        else {
            if (-not (Test-Path $backupRoot)) { New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null }
            foreach ($entry in $config.syncPaths.PSObject.Properties) {
                $paths = $entry.Value
                Sync-Directory -LocalPath (Expand-ConfigPath $paths.local) `
                               -RemotePath (Expand-ConfigPath $paths.remote) `
                               -Direction 'Backup'
            }
        }

        # Always try to publish metadata to Data repo if token is present
        Publish-DataRepo -RepoName $config.dataRepo -Token $token -LocalPath $dataRepoLocal -BackupRoot $backupRoot
    }

    Write-Log "persistent-state.ps1 completed successfully (Action=$Action)."
    $LASTEXITCODE = 0
    exit 0
}
catch {
    Write-Log "persistent-state.ps1 fatal error: $_" -Level Error
    $LASTEXITCODE = 1
    exit 1
}
