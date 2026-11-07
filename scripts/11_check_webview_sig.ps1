$adb = (Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" | Select-Object -First 1 -ExpandProperty Path)
$target = "192.168.1.8:5555"
& $adb connect $target | Out-Null

Write-Output "=== SIGNATURE OF /system/app/webview/webview.apk ==="
& $adb -s $target shell "dumpsys package com.android.webview | grep -A 10 'signatures:'"
