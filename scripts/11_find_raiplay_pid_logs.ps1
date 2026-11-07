$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Output "=== 1. SEARCH FOR RAIPLAY PID (ps -A | grep rainet) ==="
& $adb -s 192.168.1.8:5555 shell "ps -A | grep rainet"

Write-Output "`n=== 2. DUMPING ALL LOGS FOR RAIPLAY PID ==="
& $adb -s 192.168.1.8:5555 logcat -d | Select-String -Pattern "10881" | Select-Object -First 30

Write-Output "`n=== 3. SEARCHING FOR 'Errore' or 'riproduzione' IN LOGCAT ==="
& $adb -s 192.168.1.8:5555 logcat -d | Select-String -Pattern "Errore|riproduzione|Toast|Notification" | Select-Object -Last 20
