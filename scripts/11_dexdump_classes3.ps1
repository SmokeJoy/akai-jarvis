$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Output "Pushing classes3.dex to /data/local/tmp/..."
& $adb -s 192.168.1.8:5555 push "C:\Users\danie\OneDrive\Documenti\Antygravity\Akay\scratch\dex\classes3.dex" /data/local/tmp/classes3.dex

Write-Output "Dumping classes from classes3.dex..."
& $adb -s 192.168.1.8:5555 shell "dexdump /data/local/tmp/classes3.dex | grep 'Class descriptor' | grep -i 'NativePlayer' | head -n 30"
