#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$Desktop = [Environment]::GetFolderPath('Desktop')
$OutFile = Join-Path $Desktop 'pcloud-config.txt'
$ToolDir = Join-Path $env:USERPROFILE 'pcloud-rclone'
$ConfigFile = Join-Path $ToolDir 'rclone.conf'

function Write-Log {
    param([string]$Message)
    Write-Host "[pcloud-setup] $Message"
}

New-Item -ItemType Directory -Path $ToolDir -Force | Out-Null

# --- 1. Ensure portable rclone ---
$rcloneExe = Join-Path $ToolDir 'rclone.exe'
if (-not (Test-Path $rcloneExe)) {
    Write-Log 'Downloading portable rclone...'
    try {
        $ver = (Invoke-WebRequest 'https://downloads.rclone.org/version.txt' -UseBasicParsing -TimeoutSec 30).Content
        if ($ver -match 'rclone\s+(v[\d.]+)') { $ver = $Matches[1] }
        else { $ver = $ver.Trim() }
    }
    catch {
        $ver = 'v1.68.2'
    }
    $url = "https://downloads.rclone.org/$ver/rclone-$ver-windows-amd64.zip"
    $zip = Join-Path $env:TEMP 'pcloud-rclone.zip'
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 180
    Expand-Archive -Path $zip -DestinationPath $env:TEMP -Force
    $dir = Get-ChildItem $env:TEMP -Directory -Filter "rclone-$ver-windows-amd64" | Select-Object -First 1
    if (-not $dir) {
        throw 'Could not locate extracted rclone folder.'
    }
    Copy-Item (Join-Path $dir.FullName 'rclone.exe') $rcloneExe -Force
    Write-Log "rclone $ver ready at $rcloneExe"
}
else {
    Write-Log 'rclone already present.'
}

# --- Make the script re-runnable ---
& $rcloneExe config delete pcloud --config $ConfigFile 2>$null | Out-Null

# --- 2. Authenticate to pCloud (opens browser) ---
Write-Log 'Starting pCloud authentication...'
Write-Log 'Your browser will open. Log in to pCloud and click Allow/Authorize.'
Write-Host ''
# Auto-answer the "use web browser?" prompt with y if rclone asks
'y' | & $rcloneExe config create pcloud pcloud --config $ConfigFile
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n[ERROR] pCloud authentication failed. Please run this script again." -ForegroundColor Red
    exit 1
}

# --- 3. Copy config to Desktop ---
if (-not (Test-Path $ConfigFile)) {
    throw "Config file was not created: $ConfigFile"
}
Copy-Item $ConfigFile $OutFile -Force
Write-Host ''
Write-Host '======================================================'
Write-Host '  DONE! pCloud is configured.'
Write-Host "  Config file saved on your Desktop:"
Write-Host "  $OutFile"
Write-Host ''
Write-Host '  Send this file back to me and I will add it as'
Write-Host '  the PCLOUD_CONFIG secret. Then persistent backup'
Write-Host '  will work automatically in the workflow.'
Write-Host '======================================================'
