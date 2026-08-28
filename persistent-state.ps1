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
        [int]$InterPacketGap = 10,
        [string[]]$ExcludeDirs = @()
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
    #   /XJ   exclude junction points / symbolic links. User profiles (runneradmin,
    #         Bullettemporary) are full of AppData junctions; /MIR treats them as
    #         real directories, which can explode the copy or loop forever.
    #   /IPG:<n> inter-packet gap (ms) throttles the copy so RDP stays smooth
    #   /XD <dirs> excludes directories (junk/temp/VCS) during mirroring
    $robocopyArgs = @($from, $to, '/MIR', '/R:2', '/W:2', '/B', '/XJ', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    if ($InterPacketGap -gt 0) {
        $robocopyArgs += "/IPG:$InterPacketGap"
    }
    if ($ExcludeDirs.Count -gt 0) {
        $robocopyArgs += '/XD'
        $robocopyArgs += $ExcludeDirs
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

    # robocopy expects <SourceDir> <DestDir> <FileSpec>, not full file paths.
    $fromDir = Split-Path $from -Parent
    $fileName = Split-Path $from -Leaf

    $robocopyArgs = @($fromDir, $toDir, $fileName, '/R:2', '/W:2', '/B', '/XJ', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
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
                       -InterPacketGap $InterPacketGap `
                       -ExcludeDirs $Entry.excludeDirs
    }
    catch {
        Write-Log "Sync failed for '$($Entry.Name)': $_" -Level Warn
    }
}

# ---------------------------------------------------------------------------
# Indexed, incremental sync engine.
#
# Instead of robocopy /MIR on the whole tree every run, keep a small JSON index
# per sync path (rel path -> { size, lastWriteTimeUtc ticks }) in the backup.
# Backup walks the source, copies ONLY files whose size or mtime changed, then
# writes the fresh index. Restore reads the index and copies only what is
# missing or differs locally. This keeps every run fast and only touches the
# directories/files that actually changed.
# ---------------------------------------------------------------------------

function Read-FileIndex {
    param([string]$Path)
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    try {
        $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($json -and $json.files) {
            foreach ($p in $json.files.PSObject.Properties) {
                $map[$p.Name] = [pscustomobject]@{
                    size       = [long]$p.Value.size
                    mtimeTicks = [long]$p.Value.mtimeTicks
                }
            }
        }
    }
    catch {
        Write-Log "Failed to read index $Path : $_" -Level Warn
    }
    return $map
}

function Write-FileIndex {
    param([string]$Path, [hashtable]$Index)
    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $obj = [pscustomobject]@{
        version = 1
        updated = (Get-Date).ToUniversalTime().ToString('o')
        files   = $Index
    }
    $json = $obj | ConvertTo-Json -Depth 4 -Compress
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Copy-FileRobust {
    param([string]$Src, [string]$Dst, [int]$InterPacketGap = 0)
    $dstDir = Split-Path -Path $Dst -Parent
    if (-not (Test-Path -LiteralPath $dstDir)) {
        New-Item -ItemType Directory -Path $dstDir -Force -ErrorAction SilentlyContinue | Out-Null
    }
    try {
        [System.IO.File]::Copy($Src, $Dst, $true)
        $mtime = [System.IO.File]::GetLastWriteTimeUtc($Src)
        [System.IO.File]::SetLastWriteTimeUtc($Dst, $mtime)
        return $true
    }
    catch {
        # Locked / in-use file (Chrome SQLite, open logs, etc.): fall back to
        # robocopy backup mode (/B) which can read files held open by processes.
        $srcDir = Split-Path -Path $Src -Parent
        $name = Split-Path -Path $Src -Leaf
        $args = @($srcDir, $dstDir, $name, '/R:2', '/W:2', '/B', '/XJ', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
        if ($InterPacketGap -gt 0) {
            $args += "/IPG:$InterPacketGap"
        }
        & robocopy @args | Out-Null
        if ($LASTEXITCODE -ge 8) { return $false }
        return $true
    }
}

function Get-TreeFiles {
    param(
        [string]$Root,
        [string[]]$ExcludeDirs = @(),
        [string[]]$ExcludeNames = @()
    )
    $results = [System.Collections.Generic.List[object]]::new()
    $excludeNamesLower = @($ExcludeNames | ForEach-Object { $_.ToLowerInvariant() })
    $excludeDirsLower  = @($ExcludeDirs | ForEach-Object { $_.ToLowerInvariant() })
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')

    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $relDir = ''
        if ($dir.Length -gt $rootFull.Length) {
            $relDir = $dir.Substring($rootFull.Length).TrimStart('\', '/')
        }

        # Prune whole directories whose (relative) path segment matches a name
        # in the exclusion list (cache dirs, temp, node_modules, ...).
        $skipDir = $false
        foreach ($seg in ($relDir -split '[\\/]')) {
            if ($seg -eq '') { continue }
            if ($excludeNamesLower -contains $seg.ToLowerInvariant()) { $skipDir = $true; break }
            foreach ($ex in $excludeDirsLower) {
                if ($seg.ToLowerInvariant() -like "*$ex*") { $skipDir = $true; break }
            }
            if ($skipDir) { break }
        }
        if ($skipDir) { continue }

        $subDirs  = @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)
        $subFiles = @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue)

        foreach ($d in $subDirs) {
            # Never descend into junctions / symlinks (profile AppData is full
            # of them; following them can loop or escape the tree).
            if ($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            $stack.Push($d.FullName)
        }

        foreach ($f in $subFiles) {
            if ($f.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            $full = [System.IO.Path]::GetFullPath($f.FullName)
            if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $rel = $full.Substring($rootFull.Length).TrimStart('\', '/')

            $skip = $false
            foreach ($seg in ($rel -split '[\\/]')) {
                if ($excludeNamesLower -contains $seg.ToLowerInvariant()) { $skip = $true; break }
                foreach ($ex in $excludeDirsLower) {
                    if ($seg.ToLowerInvariant() -like "*$ex*") { $skip = $true; break }
                }
                if ($skip) { break }
            }
            if ($skip) { continue }

            $results.Add([pscustomobject]@{
                Rel        = $rel
                Size       = [long]$f.Length
                MtimeTicks = [long]$f.LastWriteTimeUtc.Ticks
            })
        }
    }
    return $results
}

function Sync-IndexedDirectory {
    param(
        [string]$Name,
        [string]$LocalPath,
        [string]$RemotePath,
        [string]$IndexFile,
        [ValidateSet('Restore', 'Backup')]
        [string]$Direction,
        [string[]]$ExcludeDirs = @(),
        [string[]]$ExcludeNames = @(),
        [int]$InterPacketGap = 0
    )

    if ($Direction -eq 'Restore') {
        if (-not (Test-Path -LiteralPath $RemotePath)) {
            Write-Log "Remote backup missing for '$Name'; skipping restore." -Level Warn
            return
        }
        # First run after this engine ships: there is no index yet, but the
        # legacy robocopy /MIR tree may exist. Fall back to a full robocopy.
        if (-not (Test-Path -LiteralPath $IndexFile)) {
            Write-Log "No index for '$Name' yet; falling back to full robocopy restore."
            if (-not (Test-Path -LiteralPath $LocalPath)) {
                New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null
            }
            $args = @($RemotePath, $LocalPath, '/E', '/R:2', '/W:2', '/B', '/XJ', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
            & robocopy @args | Out-Null
            if ($LASTEXITCODE -ge 8) {
                throw "Robocopy fallback restore failed with exit code $LASTEXITCODE."
            }
            Write-Log "Restore (fallback) completed for '$Name'."
            return
        }

        $index = Read-FileIndex $IndexFile
        if ($index.Count -eq 0) {
            Write-Log "Index empty for '$Name'; skipping restore."
            return
        }
        if (-not (Test-Path -LiteralPath $LocalPath)) {
            New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null
        }

        $copied = 0
        $skipped = 0
        $i = 0
        foreach ($rel in ($index.Keys | Sort-Object)) {
            $i++
            $src = Join-Path $RemotePath $rel
            $dst = Join-Path $LocalPath $rel

            $need = $true
            if (Test-Path -LiteralPath $dst) {
                $dstInfo = Get-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
                if ($dstInfo -and -not $dstInfo.PSIsContainer -and
                    $dstInfo.Length -eq $index[$rel].size -and
                    $dstInfo.LastWriteTimeUtc.Ticks -eq $index[$rel].mtimeTicks) {
                    $need = $false
                }
            }
            if ($need -and (Test-Path -LiteralPath $src)) {
                if (Copy-FileRobust -Src $src -Dst $dst) {
                    $copied++
                }
                else {
                    Write-Log "Restore failed for '$rel'." -Level Warn
                }
            }
            else {
                $skipped++
            }
            if ($i % 500 -eq 0) {
                Write-Log "Restore '$Name': $i/$($index.Count) files processed..."
            }
        }
        Write-Log "Restore '$Name' done: $copied copied, $skipped skipped (of $($index.Count) indexed)."
    }
    else {
        # Backup
        if (-not (Test-Path -LiteralPath $LocalPath)) {
            Write-Log "Local path missing for '$Name'; skipping backup." -Level Warn
            return
        }
        if (-not (Test-Path -LiteralPath $RemotePath)) {
            New-Item -ItemType Directory -Path $RemotePath -Force | Out-Null
        }

        Write-Log "Indexing local tree for '$Name'..."
        $files = Get-TreeFiles -Root $LocalPath -ExcludeDirs $ExcludeDirs -ExcludeNames $ExcludeNames
        Write-Log "Local files indexed for '$Name': $($files.Count)"

        $oldIndex = @{}
        if (Test-Path -LiteralPath $IndexFile) {
            $oldIndex = Read-FileIndex $IndexFile
        }

        $changed = [System.Collections.Generic.List[string]]::new()
        foreach ($f in $files) {
            $cached = $null
            if ($oldIndex.ContainsKey($f.Rel)) { $cached = $oldIndex[$f.Rel] }
            if (-not $cached -or $cached.size -ne $f.Size -or $cached.mtimeTicks -ne $f.MtimeTicks) {
                $changed.Add($f.Rel)
            }
        }
        Write-Log "Files changed/new for '$Name': $($changed.Count)"

        $copied = 0
        $failed = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($rel in $changed) {
            $src = Join-Path $LocalPath $rel
            $dst = Join-Path $RemotePath $rel
            if (Test-Path -LiteralPath $src) {
                if (Copy-FileRobust -Src $src -Dst $dst -InterPacketGap $InterPacketGap) {
                    $copied++
                }
                else {
                    $failed.Add($rel) | Out-Null
                }
            }
        }

        # Write the fresh index. Files that failed to copy are deliberately NOT
        # indexed so the next run retries them.
        $newIndex = @{}
        foreach ($f in $files) {
            if (-not $failed.Contains($f.Rel)) {
                $newIndex[$f.Rel] = @{ size = $f.Size; mtimeTicks = $f.MtimeTicks }
            }
        }
        Write-FileIndex -Path $IndexFile -Index $newIndex

        Write-Log "Backup '$Name' done: $copied copied, $($failed.Count) failed, $($newIndex.Count) indexed."
        if ($failed.Count -gt 0) {
            Write-Log "$($failed.Count) file(s) could not be copied for '$Name' (will retry next run)." -Level Warn
        }
    }
}

function Sync-ConfiguredPaths {
    param(
        $Config,
        [string]$BackupRoot,
        [ValidateSet('Restore', 'Backup')]
        [string]$Direction,
        [int]$InterPacketGap,
        [int]$RestoreIpg
    )

    $ipg = if ($Direction -eq 'Restore') { $RestoreIpg } else { $InterPacketGap }

    foreach ($entry in $Config.syncPaths.PSObject.Properties) {
        $paths = $entry.Value
        $excludeDirs = @()
        if ($paths.PSObject.Properties['excludeDirs']) {
            $excludeDirs = @($paths.excludeDirs)
        }
        $excludeNames = @()
        if ($paths.PSObject.Properties['excludeNames']) {
            $excludeNames = @($paths.excludeNames)
        }
        $isIndexed = $false
        if ($paths.PSObject.Properties['indexed'] -and $paths.indexed) {
            $isIndexed = $true
        }

        $local = Expand-ConfigPath $paths.local
        $remote = Expand-ConfigPath $paths.remote

        if ($isIndexed) {
            $indexFile = Join-Path (Join-Path $BackupRoot 'index') ($entry.Name + '.json')
            try {
                Sync-IndexedDirectory -Name $entry.Name -LocalPath $local -RemotePath $remote `
                    -IndexFile $indexFile -Direction $Direction -ExcludeDirs $excludeDirs `
                    -ExcludeNames $excludeNames -InterPacketGap $ipg
            }
            catch {
                Write-Log "Indexed sync failed for '$($entry.Name)': $_" -Level Warn
            }
        }
        else {
            Sync-SyncPathEntry -Entry ([pscustomobject]@{ Name = $entry.Name; local = $paths.local; remote = $paths.remote; excludeDirs = $excludeDirs }) `
                               -Direction $Direction -InterPacketGap $ipg
        }
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

    # Restore runs before any interactive session exists, so throttling only
    # slows it down for no benefit. Use no /IPG on restore; keep the throttle
    # on backup so a still-connected RDP/AnyDesk session stays smooth.
    $restoreIpg = 0

    if ($Action -eq 'Restore') {
        if (-not (Test-BackupAvailable -BackupRoot $backupRoot -DriveLetter $backupDrive)) {
            Write-Log 'Backup drive unavailable. Starting with clean state.' -Level Warn
        }
        else {
            # Restore configured sync paths, then deep-scanned items.
            Sync-ConfiguredPaths -Config $config -BackupRoot $backupRoot -Direction 'Restore' -InterPacketGap $ipg -RestoreIpg $restoreIpg

            if ($config.deepScan.enabled) {
                foreach ($item in (Invoke-DeepScanDiscovery $config.deepScan)) {
                    try {
                        $isDir = $item.Local -and (Test-Path $item.Local) -and (Get-Item $item.Local).PSIsContainer
                        if ($isDir) {
                            Sync-Directory -LocalPath $item.Local -RemotePath $item.Remote -Direction 'Restore' -InterPacketGap $restoreIpg
                        }
                        else {
                            Sync-FileEntry -LocalFile $item.Local -RemoteFile $item.Remote -Direction 'Restore' -InterPacketGap $restoreIpg
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
        # Stop AnyDesk while its files are backed up: a running AnyDesk service
        # keeps system.conf/service.conf open, so robocopy exits 8/9/11 on them
        # and the machine ID / password hash never reach the backup. Restart the
        # service after the backup completes (the run is ending anyway).
        $restartAnyDesk = $false
        $anydeskService = Get-Service -Name 'AnyDesk' -ErrorAction SilentlyContinue
        if ($anydeskService -and $anydeskService.Status -eq 'Running') {
            Write-Log 'Stopping AnyDesk service for a clean backup...'
            Stop-Service -Name 'AnyDesk' -Force -ErrorAction SilentlyContinue
            $restartAnyDesk = $true
            Start-Sleep -Seconds 3
        }
        # A stopped service can still leave the AnyDesk GUI/daemon running, and
        # that process keeps %APPDATA%\AnyDesk files locked (robocopy exits 11).
        # Kill any leftovers so every file is readable; the service restart
        # below brings AnyDesk back for the next handoff.
        Get-Process -Name 'AnyDesk' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2

        if (-not (Test-BackupAvailable -BackupRoot $backupRoot -DriveLetter $backupDrive)) {
            Write-Log 'Backup drive unavailable. Skipping file sync.' -Level Warn
        }
        else {
            if (-not (Test-Path $backupRoot)) { New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null }
            Sync-ConfiguredPaths -Config $config -BackupRoot $backupRoot -Direction 'Backup' -InterPacketGap $ipg -RestoreIpg $restoreIpg

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

        if ($restartAnyDesk) {
            try {
                Start-Service -Name 'AnyDesk' -ErrorAction Stop
                Write-Log 'AnyDesk service restarted after backup.'
            }
            catch {
                Write-Log "Failed to restart AnyDesk service after backup: $_" -Level Warn
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
