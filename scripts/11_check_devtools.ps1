$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Output "=== CHECKING UNIX DOMAIN SOCKETS FOR DEVTOOLS ==="
& $adb -s 192.168.1.8:5555 shell "su 0 grep -i 'devtools' /proc/net/unix"
