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
    Write-Host "apply failed: Spotify build and Spicetify backup build differ."
    Write-Host "This happens after a Spotify auto-update. Clean reset (Spotify closed):"
    Write-Host "  1) rename %APPDATA%\Spotify\Apps\xpui              -> xpui.old"
    Write-Host "  2) rename %APPDATA%\spicetify\Backup               -> Backup.old"
    Write-Host "  3) start Spotify once (it restores its own assets), close it"
    Write-Host "  4) run this script again"
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
