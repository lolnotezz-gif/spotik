# Recovers AntiCensor on PC after a Spotify auto-update.
# Spotify replaces xpui.spa on every update, which makes the old Spicetify patch
# incompatible and the extension "disappears" from the client.
#
# Run (Spotify must be CLOSED):
#   powershell -ExecutionPolicy Bypass -File "C:\Users\a\.gemini\antigravity\scratch\AntiCensor-iOS\tools\fix_pc_after_spotify_update.ps1"
param(
    [string]$Spicetify = "$env:LOCALAPPDATA\spicetify\spicetify.exe",
    [string]$RepoExt = (Join-Path $PSScriptRoot "..\spicetify\AntiCensor.js")
)

$ErrorActionPreference = "Stop"

# Spicetify must NOT run elevated: files become admin-owned and Spotify (normal user)
# shows a black/blank window afterwards.
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ""
    Write-Host "ERROR: this script must NOT run as administrator." -ForegroundColor Red
    Write-Host "Spicetify with admin rights breaks Spotify (black window)."
    Write-Host ""
    Write-Host "Open a NORMAL PowerShell: press Win+R, type 'powershell', Enter, then run:"
    Write-Host '  powershell -ExecutionPolicy Bypass -File "C:\Users\a\.gemini\antigravity\scratch\AntiCensor-iOS\tools\fix_pc_after_spotify_update.ps1"'
    Write-Host ""
    exit 2
}

if (-not (Test-Path $Spicetify)) { throw "spicetify.exe not found: $Spicetify" }
if (-not (Test-Path $RepoExt))   { throw "extension not found: $RepoExt" }

if (Get-Process Spotify -ErrorAction SilentlyContinue) {
    throw "Spotify is running. Close it and run the script again."
}

$extDir = Join-Path $env:APPDATA "spicetify\Extensions"
New-Item -ItemType Directory -Force -Path $extDir | Out-Null
Copy-Item $RepoExt (Join-Path $extDir "AntiCensor.js") -Force
Write-Host ("extension installed: " + (Join-Path $extDir "AntiCensor.js"))

Write-Host "updating spicetify CLI..."
& $Spicetify update *>&1 | Select-Object -Last 3

Write-Host "applying patches..."
$apply = & $Spicetify apply *>&1
$apply | Select-Object -Last 6
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "apply refused: Spotify was auto-updated after Spicetify made its backup,"
    Write-Host "so the stored backup version no longer matches the installed client."
    Write-Host ""
    Write-Host "If the AntiCensor button is missing (or the window is blank), the clean fix is:"
    Write-Host "  1) reinstall Spotify from https://www.spotify.com/download/windows/ (data is kept)"
    Write-Host "  2) run: spicetify backup apply      (normal, NOT elevated PowerShell)"
    Write-Host "  3) run this script again to copy the latest extension"
    Write-Host ""
    Write-Host "If the extension is already patched (see check below), just start Spotify."
}

$injected = Join-Path $env:APPDATA "Spotify\Apps\xpui\extensions\AntiCensor.js"
if (Test-Path $injected) {
    $len = (Get-Item $injected).Length
    Write-Host ("OK: injected extension present (" + $len + " bytes)")
} else {
    Write-Warning "extension not found in Spotify Apps after apply - check the output above"
}
