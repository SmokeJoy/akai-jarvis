$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Output "=== DISASSEMBLING NativePlayerAvailability ==="
& $adb -s 192.168.1.8:5555 shell "dexdump -d /data/local/tmp/classes3.dex | grep -A 80 'Class descriptor.*NativePlayerAvailability;' | head -n 80"

Write-Output "`n=== DISASSEMBLING MainActivity.installNativePlayerBridge ==="
& $adb -s 192.168.1.8:5555 shell "dexdump -d /data/local/tmp/classes3.dex | grep -A 80 'name.*installNativePlayerBridge' | head -n 80"
