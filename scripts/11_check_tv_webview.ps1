$adb = (Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" | Select-Object -First 1 -ExpandProperty Path)
$target = "192.168.1.8:5555"

Write-Output "=== CONNECTING TO TV ==="
& $adb connect $target

Write-Output "`n=== WEBVIEW PROVIDER INFO ==="
& $adb -s $target shell dumpsys webviewupdate

Write-Output "`n=== INSTALLED WEBVIEW PACKAGES ==="
& $adb -s $target shell "pm list packages -f | grep -i webview"
& $adb -s $target shell "pm list packages -f | grep -i chrome"

Write-Output "`n=== PLAY SERVICES & STORE VERSION ==="
& $adb -s $target shell "dumpsys package com.google.android.gms | grep -E 'versionName|versionCode' | head -n 4"
& $adb -s $target shell "dumpsys package com.android.vending | grep -E 'versionName|versionCode' | head -n 4"
