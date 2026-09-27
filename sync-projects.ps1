#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$SourcePath = 'C:\Users\Public\Desktop\RDP_Projects',
    [string]$RepoName = 'Data',
    [string]$RepoLocalPath = 'C:\rdp-sync\github-data'
)

# Backs up the shared RDP_Projects folder to a private GitHub repository using
# git (only changed files are transferred). The private repo is created on the
# first run via the GitHub API, then the folder is mirrored into it.
#
# Safe to run repeatedly: it reuses the local clone and commits only when
# something actually changed.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Log {
    param([string]$Message, [ValidateSet('Info', 'Warn', 'Error')]$Level = 'Info')
    $prefix = switch ($Level) { 'Warn' { 'WARN' } 'Error' { 'ERROR' } default { 'INFO' } }
    Write-Host "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [$prefix] $Message"
}

function Get-GitHubOwner {
    if ($env:GITHUB_REPOSITORY -match '^([^/]+)/') {
        return $Matches[1]
    }
    throw 'GITHUB_REPOSITORY environment variable is missing or invalid.'
}

function Ensure-DataRepo {
    param([string]$Owner, [string]$Repo, $Headers)
    try {
        $null = Invoke-RestMethod -Method GET -Uri "https://api.github.com/repos/$Owner/$Repo" -Headers $Headers
        Write-Log "Private repository $Owner/$Repo already exists."
    }
    catch {
        Write-Log "Creating private repository $Owner/$Repo ..."
        $body = @{
            name        = $Repo
            private     = $true
            description = 'RDP_Projects backups'
            auto_init   = $true
        } | ConvertTo-Json
        $null = Invoke-RestMethod -Method POST -Uri 'https://api.github.com/user/repos' `
            -Headers $Headers -ContentType 'application/json' -Body $body
        Write-Log "Repository $Owner/$Repo created."
    }
}

function Initialize-LocalClone {
    param([string]$Remote, [string]$LocalPath)
    if (Test-Path (Join-Path $LocalPath '.git')) { return }
    Write-Log "Cloning $RepoName into $LocalPath ..."
    New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null
    & git -C $LocalPath init | Out-Null
    & git -C $LocalPath remote add origin $Remote
    & git -C $LocalPath fetch origin
    & git -C $LocalPath checkout -B main
    & git -C $LocalPath pull origin main --allow-unrelated-histories --no-edit 2>$null | Out-Null
}

try {
    Write-Log 'sync-projects.ps1 starting...'

    $token = $env:GH_TOKEN
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Log 'GH_TOKEN missing; skipping backup.' -Level Warn
        $LASTEXITCODE = 0
        exit 0
    }

    if (-not (Test-Path $SourcePath)) {
        New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
        Write-Log "Created source folder $SourcePath"
    }

    $owner = Get-GitHubOwner
    $headers = @{
        Authorization          = "Bearer $token"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    Ensure-DataRepo -Owner $owner -Repo $RepoName -Headers $headers

    $remote = "https://x-access-token:$token@github.com/$owner/$RepoName.git"
    Initialize-LocalClone -Remote $remote -LocalPath $RepoLocalPath
    # Token can rotate between runs; always point origin at the current token.
    & git -C $RepoLocalPath remote set-url origin $remote

    # Mirror the project folder into the repo (backup mode reads locked files).
    $dest = Join-Path $RepoLocalPath 'RDP_Projects'
    Write-Log "Mirroring $SourcePath -> $dest ..."
    & robocopy $SourcePath $dest /MIR /R:2 /W:2 /B /XJ /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed with exit code $LASTEXITCODE"
    }

    & git -C $RepoLocalPath config user.email 'github-actions[bot]@users.noreply.github.com'
    & git -C $RepoLocalPath config user.name 'github-actions[bot]'
    & git -C $RepoLocalPath add -A
    $status = & git -C $RepoLocalPath status --porcelain
    if (-not $status) {
        Write-Log 'No changes to back up.'
        $LASTEXITCODE = 0
        exit 0
    }

    & git -C $RepoLocalPath commit -m "backup: RDP_Projects $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC [run $env:GITHUB_RUN_ID]" | Out-Null
    & git -C $RepoLocalPath pull origin main --rebase --no-edit 2>$null | Out-Null
    & git -C $RepoLocalPath push origin main
    Write-Log 'Backup pushed to GitHub.'

    $LASTEXITCODE = 0
    exit 0
}
catch {
    Write-Log "sync-projects.ps1 fatal error: $_" -Level Error
    $LASTEXITCODE = 1
    exit 1
}
