$adb = (Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" | Select-Object -First 1 -ExpandProperty Path)
$target = "192.168.1.8:5555"
& $adb connect $target | Out-Null

$cmd = @'
dexdump -d /data/local/tmp/classes3.dex | grep -B 5 -A 5 'NativePlayerAvailability'
'@

& $adb -s $target shell $cmd
