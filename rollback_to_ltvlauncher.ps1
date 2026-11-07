# Script di Rollback Immediato a LTvLauncher
$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
if (-not (Test-Path $adb)) {
    $adb = "adb"
}

Write-Host "Connessione alla TV AKAI (192.168.1.8:5555)..." -ForegroundColor Cyan
& $adb connect 192.168.1.8:5555
Start-Sleep -Milliseconds 500

Write-Host "Ripristino di LTvLauncher come Home predefinita..." -ForegroundColor Yellow
& $adb -s 192.168.1.8:5555 shell "cmd package set-home-activity com.leanbitlab.ltvL/.MainActivity"

Write-Host "Apertura immediata di LTvLauncher..." -ForegroundColor Green
& $adb -s 192.168.1.8:5555 shell "am start -n com.leanbitlab.ltvL/.MainActivity"

Write-Host "Verifica stato:" -ForegroundColor Cyan
& $adb -s 192.168.1.8:5555 shell "cmd package resolve-activity --brief -c android.intent.category.HOME -a android.intent.action.MAIN"
Write-Host "Rollback completato con successo!" -ForegroundColor Green
