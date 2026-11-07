$adb = (Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" | Select-Object -First 1 -ExpandProperty Path)
$target = "192.168.1.8:5555"

& $adb connect $target | Out-Null
& $adb -s $target shell "dexdump -d /data/local/tmp/classes3.dex | grep -A 80 'name.*: .install.' | head -n 80"
