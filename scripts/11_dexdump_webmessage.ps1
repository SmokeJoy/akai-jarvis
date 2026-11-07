$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Output "=== DISASSEMBLING WebMessageBridgeInstaller ==="
& $adb -s 192.168.1.8:5555 shell "dexdump -d /data/local/tmp/classes3.dex | grep -A 60 'Class descriptor.*WebMessageBridgeInstaller;' | head -n 60"
