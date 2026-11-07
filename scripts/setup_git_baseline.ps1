$git = "C:\Users\danie\AppData\Local\Microsoft\WinGet\Packages\Git.MinGit_Microsoft.Winget.Source_8wekyb3d8bbwe\cmd\git.exe"
$gh = "C:\Program Files\GitHub CLI\gh.exe"

Set-Location "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay"

Write-Host "=== INIZIALIZZAZIONE REPOSITORY GIT LOCALE ===" -ForegroundColor Cyan
& $git init -b main

Write-Host "`n=== AGGIUNTA DEI FILE SANITIZZATI ALL'INDICE GIT ===" -ForegroundColor Cyan
& $git add .

Write-Host "`n=== VERIFICA SEGRETI E STATO FILE STAGED ===" -ForegroundColor Cyan
$stagedFiles = & $git diff --cached --name-only
Write-Host "Numero di file staged:" $stagedFiles.Count

$forbidden = $stagedFiles | Where-Object { $_ -match '\.(p12|jks|keystore|apk|log|zip)$' }
if ($forbidden) {
    Write-Host "ERRORE: Rilevati file sensibili o binari tra i file staged:" -ForegroundColor Red
    $forbidden | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    exit 1
} else {
    Write-Host "Verifica superata: nessun keystore, chiave privata o APK presente nell'indice Git." -ForegroundColor Green
}

Write-Host "`n=== COMMIT BASELINE INIZIALE ===" -ForegroundColor Cyan
& $git commit -m "feat(baseline): AKAI JARVIS v16 codebase baseline freeze"

Write-Host "`nCommit SHA:"
& $git rev-parse HEAD
