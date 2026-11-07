$adb = (Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" | Select-Object -First 1 -ExpandProperty Path)
$target = "192.168.1.8:5555"
& $adb connect $target | Out-Null

$cmd = @'
dexdump -d /data/local/tmp/classes3.dex | grep -B 10 -A 10 'nativePlayerTransportAvailable'
'@

& $adb -s $target shell $cmd
