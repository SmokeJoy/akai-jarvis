$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

$apk = "/data/app/it.rainet.androidtv-macUztuWjZ53LfbFmdXOwg==/base.apk"
Write-Output "=== CLASSES IN BASE.APK MATCHING NATIVEPLAYER ==="
& $adb -s 192.168.1.8:5555 shell "su 0 dexdump $apk | grep 'Class descriptor' | grep -i 'NativePlayer' | head -n 30"
