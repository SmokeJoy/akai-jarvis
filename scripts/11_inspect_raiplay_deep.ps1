$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Output "=== TV_CONFIG_CACHE.XML (KEYS) ==="
& $adb -s 192.168.1.8:5555 shell "su 0 cat /data/data/it.rainet.androidtv/shared_prefs/tv_config_cache.xml | grep -E '<string|<boolean|<int' | head -n 30"
