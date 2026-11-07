$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Output "=== WM SIZE ==="
& $adb -s 192.168.1.8:5555 shell "wm size"

Write-Output "=== TESTING ENTER KEY & TAP ==="
# "CONTINUA SENZA ACCETTARE" is at approximately X: 520/1000 (middle-right of left column), Y: 467/1000
# On 1920x1080: X ~ 1000, Y ~ 470
# Let's try keyevent 66 (ENTER) first
& $adb -s 192.168.1.8:5555 shell "input keyevent 66"
Start-Sleep -Seconds 1
# And let's also try tapping "ACCETTA" (X ~ 300, Y ~ 915) or "CONTINUA SENZA ACCETTARE" (X ~ 1000, Y ~ 468)
& $adb -s 192.168.1.8:5555 shell "input tap 1000 468"
Start-Sleep -Seconds 2

Write-Output "=== CHECKING LOGCAT FOR CLICKS ==="
& $adb -s 192.168.1.8:5555 logcat -d -t 50 | Select-String -Pattern "chromium|Iubenda|mediaset"
