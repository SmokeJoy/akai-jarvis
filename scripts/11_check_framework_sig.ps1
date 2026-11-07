$adb = (Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" | Select-Object -First 1 -ExpandProperty Path)
$target = "192.168.1.8:5555"
& $adb connect $target | Out-Null

Write-Output "=== SIGNATURE OF SYSTEM FRAMEWORK (android) ==="
& $adb -s $target shell "dumpsys package android | grep -A 5 'signatures:'"
