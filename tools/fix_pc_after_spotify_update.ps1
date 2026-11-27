# Восстанавливает AntiCensor на ПК после автообновления Spotify.
# Spotify при каждом апдейте подменяет xpui.spa, из-за чего Spicetify-патч
# становится несовместимым и расширение «пропадает» из клиента.
#
# Запуск (PowerShell, Spotify должен быть ЗАКРЫТ):
#   powershell -ExecutionPolicy Bypass -File tools\fix_pc_after_spotify_update.ps1
param(
    [string]$Spicetify = "$env:LOCALAPPDATA\spicetify\spicetify.exe",
    [string]$RepoExt = (Join-Path $PSScriptRoot "..\spicetify\AntiCensor.js")
)

$ErrorActionPreference = "Stop"
$extDir = Join-Path $env:APPDATA "spicetify\Extensions"

if (-not (Test-Path $Spicetify)) { throw "spicetify.exe not found: $Spicetify" }
if (-not (Test-Path $RepoExt))   { throw "extension not found: $RepoExt" }

if (Get-Process Spotify -ErrorAction SilentlyContinue) {
    throw "Закрой Spotify и запусти скрипт снова (патчинг требует закрытого клиента)."
}

New-Item -ItemType Directory -Force -Path $extDir | Out-Null
Copy-Item $RepoExt (Join-Path $extDir "AntiCensor.js") -Force
Write-Host "extension installed: $(Join-Path $extDir 'AntiCensor.js')"

Write-Host "updating spicetify CLI..."
& $Spicetify update 2>&1 | Select-Object -Last 3

Write-Host "applying patches..."
$apply = & $Spicetify apply 2>&1
$apply | Select-Object -Last 6
if ($LASTEXITCODE -ne 0) {
    Write-Host "apply failed (обычно из-за несовпадения бэкапа после обновления Spotify)."
    Write-Host "Пробую 'backup apply'..."
    & $Spicetify backup apply 2>&1 | Select-Object -Last 8
}

$injected = Join-Path $env:APPDATA "Spotify\Apps\xpui\extensions\AntiCensor.js"
if (Test-Path $injected) {
    $len = (Get-Item $injected).Length
    Write-Host "OK: injected extension present ($len bytes)"
} else {
    Write-Warning "extension not found in Spotify Apps after apply — проверь вывод выше"
}
