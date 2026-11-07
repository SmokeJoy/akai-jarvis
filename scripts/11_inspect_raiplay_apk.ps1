$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

$apkPath = "/data/app/it.rainet.androidtv-macUztuWjZ53LfbFmdXOwg==/base.apk"
Write-Output "Pulling base.apk header or checking strings..."
& $adb -s 192.168.1.8:5555 shell "su 0 unzip -p $apkPath classes.dex | strings | grep -E 'nativePlayer|nativeHttp|androidTvCapabilities' | head -n 30"
