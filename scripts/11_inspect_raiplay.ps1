$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Output "=== RAIPLAY PACKAGE INFO ==="
& $adb -s 192.168.1.8:5555 shell "dumpsys package it.rainet.androidtv | grep -E 'versionName|versionCode|minSdk|targetSdk'"
