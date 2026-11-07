# scripts/01_check_tools.ps1
# Verifica la disponibilità di ADB e strumenti essenziali

$ErrorActionPreference = "Continue"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " AKAI Custom TV - Verifica Strumenti Locali" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# 1. Verifica ADB nel PATH o nelle cartelle locali
$adbPath = $null
$localPlatformTools = Join-Path $PSScriptRoot "..\tools\platform-tools\adb.exe"

if (Get-Command adb -ErrorAction SilentlyContinue) {
    $adbPath = (Get-Command adb).Source
    Write-Host "[OK] ADB trovato nel sistema: $adbPath" -ForegroundColor Green
} elseif (Test-Path $localPlatformTools) {
    $adbPath = (Resolve-Path $localPlatformTools).Path
    Write-Host "[OK] ADB trovato nella cartella locale: $adbPath" -ForegroundColor Green
} else {
    Write-Host "[ATTENZIONE] 'adb' non e' presente nel PATH di sistema ne' nella cartella tools." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Per installare platform-tools (ADB) ufficiali di Google in locale:" -ForegroundColor Yellow
    Write-Host "1. Scarica lo zip ufficiale da:"
    Write-Host "   https://dl.google.com/android/repository/platform-tools-latest-windows.zip" -ForegroundColor White
    Write-Host "2. Estrai la cartella 'platform-tools' all'interno di:"
    Write-Host "   $((Resolve-Path (Join-Path $PSScriptRoot '..')).Path)\tools\platform-tools" -ForegroundColor White
    Write-Host ""
    Write-Host "Oppure (se disponi di winget nel terminale):"
    Write-Host "   winget install Google.PlatformTools" -ForegroundColor White
}

# 2. Mostra versione ADB se presente
if ($adbPath) {
    & $adbPath version
}

Write-Host "==========================================" -ForegroundColor Cyan
