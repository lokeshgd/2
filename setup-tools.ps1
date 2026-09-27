#Requires -Version 7.0
[CmdletBinding()]
param()

# Installs the tools needed in every fresh RDP session and makes sure the
# shared project folder exists. Runs on each new runner (the machine is
# recreated every ~6h handoff, so this must be idempotent and fast).

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Log {
    param([string]$Message, [ValidateSet('Info', 'Warn', 'Error')]$Level = 'Info')
    $prefix = switch ($Level) { 'Warn' { 'WARN' } 'Error' { 'ERROR' } default { 'INFO' } }
    Write-Host "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [$prefix] $Message"
}

function Update-Path {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machinePath;$userPath"
}

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Install-Node {
    try {
        if (Test-CommandExists 'node') {
            Write-Log "Node.js already installed: $(node --version)"
            return
        }
        Write-Log 'Installing Node.js LTS (prerequisite for npm tools)...'
        & winget install --id OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements --silent
        Update-Path
    }
    catch {
        Write-Log "Node.js install failed: $_" -Level Warn
    }
}

function Install-Python {
    try {
        if (Test-CommandExists 'python') {
            Write-Log "Python already installed: $(python --version 2>&1)"
            return
        }
        Write-Log 'Installing Python...'
        & winget install --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements --silent
        Update-Path
    }
    catch {
        Write-Log "Python install failed: $_" -Level Warn
    }
}

function Install-NpmGlobal {
    param([string]$PackageName)
    try {
        if (-not (Test-CommandExists 'npm')) {
            Write-Log "Skipping $PackageName - npm not available." -Level Warn
            return
        }

        # System-wide prefix so the tools are also on PATH for the interactive
        # RDP/AnyDesk users, not just the runner account.
        $prefix = Join-Path $env:ProgramFiles 'nodejs'
        $modulePath = Join-Path $prefix "node_modules\$PackageName"

        if (Test-Path $modulePath) {
            Write-Log "$PackageName already installed."
            return
        }

        Write-Log "Installing $PackageName globally..."
        & npm install -g --prefix $prefix $PackageName --silent
        if ($LASTEXITCODE -ne 0) {
            throw "npm install failed with exit code $LASTEXITCODE"
        }
        Write-Log "$PackageName installed."
    }
    catch {
        Write-Log "$PackageName install failed: $_" -Level Warn
    }
}

try {
    Write-Log 'setup-tools.ps1 starting...'

    Install-Node
    Install-Python
    Install-NpmGlobal -PackageName 'astro'
    Install-NpmGlobal -PackageName 'wrangler'
    Install-NpmGlobal -PackageName 'opencode-ai'

    # Public desktop folder: visible in every session (console, AnyDesk, RDP).
    $projects = 'C:\Users\Public\Desktop\RDP_Projects'
    if (-not (Test-Path $projects)) {
        New-Item -ItemType Directory -Path $projects -Force | Out-Null
        Write-Log "Created project folder: $projects"
    }
    else {
        Write-Log "Project folder already exists: $projects"
    }

    Write-Log 'setup-tools.ps1 completed.'
    $LASTEXITCODE = 0
    exit 0
}
catch {
    Write-Log "setup-tools.ps1 fatal error: $_" -Level Error
    $LASTEXITCODE = 1
    exit 1
}
