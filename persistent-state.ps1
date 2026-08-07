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
        [string]$Direction,
        [int]$InterPacketGap = 10
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

    # Robocopy options:
    #   /MIR  mirror, /R:2 retry, /W:2 wait, /NFL no file list, /NDL no dir list,
    #   /NJH no job header, /NJS no job summary, /NP no progress
    #   /B    backup mode: copy files held open by running services (AnyDesk),
    #         requires admin rights (the GitHub runner has them)
    #   /IPG:<n> inter-packet gap (ms) throttles the copy so RDP stays smooth
    $robocopyArgs = @($from, $to, '/MIR', '/R:2', '/W:2', '/B', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    if ($InterPacketGap -gt 0) {
        $robocopyArgs += "/IPG:$InterPacketGap"
    }

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

# Deep Scan engine: auto-discovers hidden session/login data, .env files and
# token-like files across the configured scan roots (home, AppData, Temp).
function Invoke-DeepScanDiscovery {
    param($DeepScanConfig)

    if (-not $DeepScanConfig -or -not $DeepScanConfig.enabled) {
        Write-Log 'Deep Scan disabled or not configured.'
        return @()
    }

    $discovered = @()
    $remoteRoot = Expand-ConfigPath $DeepScanConfig.remoteRoot

    # 1) Known high-value directories (dotfiles, app config dirs).
    foreach ($target in $DeepScanConfig.targetDirs) {
        foreach ($root in $DeepScanConfig.scanRoots) {
            $rootPath = Expand-ConfigPath $root
            if (-not $rootPath -or -not (Test-Path $rootPath)) { continue }
            $candidate = Join-Path $rootPath $target
            if (Test-Path $candidate) {
                # Store real (short) name key
                $name = "deep_$((Split-Path $target -Leaf) -replace '[^a-zA-Z0-9]', '_')"
                $discovered += [pscustomobject]@{
                    Name   = $name
                    Local  = $candidate
                    Remote = Join-Path $remoteRoot $name
                }
            }
        }
    }

    # 2) File-level scan for token/session files under each scan root.
    $tokenRegex = $DeepScanConfig.tokenFileRegex
    $extensions = $DeepScanConfig.tokenFileExtensions
    $maxDepth   = [int]$DeepScanConfig.maxDepth
    $maxFiles   = [int]$DeepScanConfig.maxScanFiles
    $maxBytes   = ([double]$DeepScanConfig.maxFileSizeMB) * 1MB
    $excludeDirs = @($DeepScanConfig.excludeDirs)
    $count = 0

    foreach ($root in $DeepScanConfig.scanRoots) {
        if ($count -ge $maxFiles) { break }
        $rootPath = Expand-ConfigPath $root
        if (-not $rootPath -or -not (Test-Path $rootPath)) { continue }

        Write-Log "Deep scanning $rootPath for token/session files..."
        try {
            $files = Get-ChildItem -Path $rootPath -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.FullName.Length -le 600 -and
                    $_.Length -gt 0 -and
                    $_.Length -le $maxBytes
                }
            foreach ($f in $files) {
                if ($count -ge $maxFiles) { break }

                # Skip excluded directories
                $skip = $false
                foreach ($ex in $excludeDirs) {
                    if ($f.FullName -match [regex]::Escape($ex)) { $skip = $true; break }
                }
                if ($skip) { continue }

                # Depth guard
                $relDepth = ($f.FullName.Substring($rootPath.Length) -split '[\\/]').Count
                if ($relDepth -gt $maxDepth) { continue }

                # Only files whose name looks like a token/session/.env file.
                # (A bare extension catch-all would pull in thousands of
                # irrelevant package.json files, so require a name match.)
                $isEnvFile  = $f.Name -eq '.env' -or $f.Name -like '.env.*'
                $nameMatches = $f.Name -match $tokenRegex
                if (-not $isEnvFile -and -not $nameMatches) { continue }

                $count++
                $relPath = $f.FullName.Substring($rootPath.Length).TrimStart('\', '/')
                $discovered += [pscustomobject]@{
                    Name   = "deep_file_$($f.Name -replace '[^a-zA-Z0-9]', '_')_$count"
                    Local  = $f.FullName
                    Remote = Join-Path (Join-Path $remoteRoot 'files') ($relPath -replace '[\\/:*?"<>|]', '_')
                }
            }
        }
        catch {
            Write-Log "Deep scan failed for $rootPath : $_" -Level Warn
        }
    }

    Write-Log "Deep Scan discovered $($discovered.Count) items."
    return $discovered
}

# Copy a single file to its remote (robocopy file->file keeps /IPG throttling
# consistent for every copy path; exit code 8+ means failure).
function Sync-FileEntry {
    param(
        [string]$LocalFile,
        [string]$RemoteFile,
        [ValidateSet('Restore', 'Backup')]
        [string]$Direction,
        [int]$InterPacketGap = 10
    )

    if ($Direction -eq 'Restore') {
        $from = $RemoteFile
        $to = $LocalFile
    }
    else {
        $from = $LocalFile
        $to = $RemoteFile
    }

    if (-not (Test-Path $from)) {
        Write-Log "Skipping file sync: source missing ($from)" -Level Warn
        return
    }

    $toDir = Split-Path $to -Parent
    if (-not (Test-Path $toDir)) {
        New-Item -ItemType Directory -Path $toDir -Force | Out-Null
    }

    $robocopyArgs = @($from, $to, '/R:2', '/W:2', '/B', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    if ($InterPacketGap -gt 0) {
        $robocopyArgs += "/IPG:$InterPacketGap"
    }

    & robocopy @robocopyArgs | Out-Null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ge 8) {
        throw "Robocopy file copy failed with exit code $exitCode during $Direction."
    }
    Write-Log "Synced file ($Direction): $from -> $to"
}

function Sync-SyncPathEntry {
    param(
        $Entry,
        [ValidateSet('Restore', 'Backup')]
        [string]$Direction,
        [int]$InterPacketGap
    )

    try {
        Sync-Directory -LocalPath (Expand-ConfigPath $Entry.local) `
                       -RemotePath (Expand-ConfigPath $Entry.remote) `
                       -Direction $Direction `
                       -InterPacketGap $InterPacketGap
    }
    catch {
        Write-Log "Sync failed for '$($Entry.Name)': $_" -Level Warn
    }
}

try {
    Write-Log "persistent-state.ps1 starting (Action=$Action)..."
    $config = Get-Config
    $backupRoot = Expand-ConfigPath $config.backupRoot
    $backupDrive = $config.backupDrive
    $dataRepoLocal = Expand-ConfigPath $config.dataRepoLocalPath
    $token = $env:GH_TOKEN
    $ipg = 10
    if ($config.performance -and $config.performance.robocopyIPG) {
        $ipg = [int]$config.performance.robocopyIPG
    }

    if ($Action -eq 'Restore') {
        if (-not (Test-BackupAvailable -BackupRoot $backupRoot -DriveLetter $backupDrive)) {
            Write-Log 'Backup drive unavailable. Starting with clean state.' -Level Warn
        }
        else {
            # Restore configured sync paths, then deep-scanned items.
            foreach ($entry in $config.syncPaths.PSObject.Properties) {
                $paths = $entry.Value
                Sync-SyncPathEntry -Entry ([pscustomobject]@{ Name = $entry.Name; local = $paths.local; remote = $paths.remote }) `
                                   -Direction 'Restore' -InterPacketGap $ipg
            }

            if ($config.deepScan.enabled) {
                foreach ($item in (Invoke-DeepScanDiscovery $config.deepScan)) {
                    try {
                        $isDir = $item.Local -and (Test-Path $item.Local) -and (Get-Item $item.Local).PSIsContainer
                        if ($isDir) {
                            Sync-Directory -LocalPath $item.Local -RemotePath $item.Remote -Direction 'Restore' -InterPacketGap $ipg
                        }
                        else {
                            Sync-FileEntry -LocalFile $item.Local -RemoteFile $item.Remote -Direction 'Restore' -InterPacketGap $ipg
                        }
                    }
                    catch {
                        Write-Log "Deep-scan restore failed for '$($item.Name)': $_" -Level Warn
                    }
                }
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
                Sync-SyncPathEntry -Entry ([pscustomobject]@{ Name = $entry.Name; local = $paths.local; remote = $paths.remote }) `
                                   -Direction 'Backup' -InterPacketGap $ipg
            }

            if ($config.deepScan.enabled) {
                foreach ($item in (Invoke-DeepScanDiscovery $config.deepScan)) {
                    try {
                        $isDir = $item.Local -and (Test-Path $item.Local) -and (Get-Item $item.Local).PSIsContainer
                        if ($isDir) {
                            Sync-Directory -LocalPath $item.Local -RemotePath $item.Remote -Direction 'Backup' -InterPacketGap $ipg
                        }
                        else {
                            Sync-FileEntry -LocalFile $item.Local -RemoteFile $item.Remote -Direction 'Backup' -InterPacketGap $ipg
                        }
                    }
                    catch {
                        Write-Log "Deep-scan backup failed for '$($item.Name)': $_" -Level Warn
                    }
                }
            }
        }

        # Always try to publish metadata to Data repo if token is present
        try {
            Publish-DataRepo -RepoName $config.dataRepo -Token $token -LocalPath $dataRepoLocal -BackupRoot $backupRoot
        }
        catch {
            Write-Log "Data repository publish failed: $_" -Level Warn
        }
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
