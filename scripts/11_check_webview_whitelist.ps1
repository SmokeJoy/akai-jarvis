$adb = (Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" | Select-Object -First 1 -ExpandProperty Path)
$target = "192.168.1.8:5555"
& $adb connect $target | Out-Null

Write-Output "=== WEBVIEW PROVIDERS IN FRAMEWORK RES ==="
& $adb -s $target shell "grep -r -i 'webview' /system/etc/sysconfig/ 2>/dev/null"
& $adb -s $target shell "grep -r -i 'webview' /system/etc/permissions/ 2>/dev/null"
& $adb -s $target shell "dumpsys webviewupdate | grep -A 20 'WebView packages:'"
