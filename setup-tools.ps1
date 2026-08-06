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

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Update-Path {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machinePath;$userPath"
    Write-Log "Updated session PATH."
}

function Install-Git {
    param($ToolConfig)
    try {
        if (Test-CommandExists 'git') {
            Write-Log "Git already installed: $(git --version)"
            return
        }

        Write-Log 'Installing Git...'
        if (Test-CommandExists 'winget') {
            Write-Log "Using winget to install Git (${ToolConfig.wingetId})..."
            & winget install --id $ToolConfig.wingetId --accept-package-agreements --accept-source-agreements --silent
            Update-Path
        }
        else {
            Write-Log "winget not found. Falling back to direct download..."
            $installer = Join-Path $env:TEMP 'Git-installer.exe'
            Invoke-WebRequest -Uri $ToolConfig.fallbackUrl -OutFile $installer -UseBasicParsing -TimeoutSec 120
            Write-Log "Running Git installer..."
            Start-Process -FilePath $installer -ArgumentList '/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-' -Wait
            Update-Path
        }

        if (-not (Test-CommandExists 'git')) {
            throw 'Git installation completed but git command is still unavailable.'
        }
        Write-Log "Git installed: $(git --version)"
    }
    catch {
        Write-Log "Git install failed: $_" -Level Warn
    }
}

function Install-Node {
    param($ToolConfig)
    try {
        if (Test-CommandExists 'node') {
            Write-Log "Node.js already installed: $(node --version)"
            return
        }

        Write-Log 'Installing Node.js via winget...'
        if (Test-CommandExists 'winget') {
            & winget install --id $ToolConfig.wingetId --accept-package-agreements --accept-source-agreements --silent
            Update-Path
        }
        else {
            Write-Log 'Node.js is required but winget is unavailable.' -Level Warn
        }
    }
    catch {
        Write-Log "Node.js install failed: $_" -Level Warn
    }
}

function Install-NpmGlobal {
    param([string]$PackageName)
    try {
        if (-not (Test-CommandExists 'npm')) {
            Write-Log "Skipping $PackageName — npm not available." -Level Warn
            return
        }

        Write-Log "Checking $PackageName..."
        $installed = (& npm list -g $PackageName --depth=0 2>$null) -match $PackageName
        if ($installed) {
            Write-Log "$PackageName already installed globally."
            return
        }

        Write-Log "Installing $PackageName globally..."
        & npm install -g $PackageName --silent
        Write-Log "$PackageName installed successfully."
    }
    catch {
        Write-Log "$PackageName install failed: $_" -Level Warn
    }
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
        try {
            $svc = Get-Service -Name 'AnyDesk' -ErrorAction SilentlyContinue
            if ($svc) {
                Start-Service -Name 'AnyDesk' -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Log "AnyDesk service start failed: $_" -Level Warn
        }

        if ($Password) {
            Write-Log "Configuring AnyDesk unattended access for user: $($AnyConfig.user)..."
            $Password | & $binary --set-password 2>&1 | Out-Null
            Start-Sleep -Seconds 3
        }

        # Retrieve the AnyDesk ID (start the process and retry if needed).
        $anydeskId = ''
        for ($i = 1; $i -le 6; $i++) {
            $anydeskId = & $binary --get-id 2>$null
            if ($anydeskId) { break }
            if (-not (Get-Process -Name 'AnyDesk' -ErrorAction SilentlyContinue)) {
                Start-Process -FilePath $binary | Out-Null
            }
            Start-Sleep -Seconds 3
        }

        if ($anydeskId) {
            $anydeskId = $anydeskId.Trim()
            Write-Log "AnyDesk ID: $anydeskId"
            if ($env:GITHUB_STEP_SUMMARY) {
                "### AnyDesk`n- **ID**: ``$anydeskId```n- **User**: ``$($AnyConfig.user)``" | Out-File $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
            }
        }
        else {
            Write-Log 'AnyDesk installed but the AnyDesk ID could not be retrieved.' -Level Warn
        }
    }
    catch {
        Write-Log "AnyDesk install/configure failed: $_" -Level Warn
    }
}

function Install-WinFsp {
    param($ToolConfig)
    try {
        if (Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue) {
            Write-Log 'WinFsp already installed.'
            return
        }
        Write-Log "Downloading WinFsp from $($ToolConfig.downloadUrl)..."
        $installer = Join-Path $env:TEMP 'winfsp.msi'
        Invoke-WebRequest -Uri $ToolConfig.downloadUrl -OutFile $installer -UseBasicParsing -TimeoutSec 120
        Write-Log 'Installing WinFsp silently (required for rclone mount)...'
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList '/i', "`"$installer`"", '/qn', '/norestart' -PassThru
        if (-not $proc.WaitForExit(180000)) {
            Write-Log 'WinFsp installer did not exit within 3 minutes.' -Level Warn
        }
        Start-Sleep -Seconds 5
        if (Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue) {
            Start-Service 'WinFsp.Launcher' -ErrorAction SilentlyContinue
            Write-Log 'WinFsp installed successfully.'
        }
        else {
            Write-Log 'WinFsp installation finished but service not detected.' -Level Warn
        }
    }
    catch {
        Write-Log "WinFsp install failed: $_" -Level Warn
    }
}

function Install-Antigravity {
    param($ToolConfig)
    try {
        $binary = Expand-ConfigPath $ToolConfig.binary
        if (Test-Path $binary) {
            Write-Log "Antigravity IDE already installed at $binary"
            return
        }

        Write-Log "Downloading Antigravity IDE from $($ToolConfig.downloadUrl)..."
        $installer = Join-Path $env:TEMP 'Antigravity-IDE-Installer.exe'
        Invoke-WebRequest -Uri $ToolConfig.downloadUrl -OutFile $installer -UseBasicParsing -TimeoutSec 120
        if (-not (Test-Path $installer)) {
            throw 'Antigravity installer download produced no file.'
        }

        Write-Log "Installing Antigravity IDE silently (non-blocking)..."
        # Never block the workflow: launch the installer and only wait briefly for the binary.
        Start-Process -FilePath $installer -ArgumentList '/S', '/allusers' | Out-Null
        $deadline = (Get-Date).AddMinutes(3)
        while (-not (Test-Path $binary) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 10
        }

        if (Test-Path $binary) {
            Write-Log "Antigravity IDE installed successfully at $binary"
        }
        else {
            Write-Log 'Antigravity install still running in the background; continuing without waiting.' -Level Warn
        }
    }
    catch {
        Write-Log "Antigravity install failed: $_" -Level Warn
    }
}

try {
    Write-Log 'setup-tools.ps1 starting...'
    $config = Get-Config
    
    $password = $env:RDP_PASS
    if (-not $password -and $config.anydesk.passwordEnv) {
        $password = [Environment]::GetEnvironmentVariable($config.anydesk.passwordEnv)
    }

    Install-Git -ToolConfig $config.tools.git
    Install-Node -ToolConfig $config.tools.node
    Install-WinFsp -ToolConfig $config.tools.winfsp
    Install-AnyDesk -ToolConfig $config.tools.anydesk -AnyConfig $config.anydesk -Password $password
    Install-NpmGlobal -PackageName $config.tools.claudeCode.npmPackage
    Install-NpmGlobal -PackageName $config.tools.openCode.npmPackage
    Install-Antigravity -ToolConfig $config.tools.antigravity

    Write-Log 'setup-tools.ps1 completed successfully.'
    # Explicitly reset and exit with 0 so GitHub Actions reports success
    # (the runner propagates $LASTEXITCODE when pwsh wraps the step).
    $LASTEXITCODE = 0
    exit 0
}
catch {
    Write-Log "setup-tools.ps1 fatal error: $_" -Level Error
    $LASTEXITCODE = 1
    exit 1
}
