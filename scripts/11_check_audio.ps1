$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Output "=== AUDIO FLINGER ACTIVE TRACKS ==="
& $adb -s 192.168.1.8:5555 shell "dumpsys media.audio_flinger | grep -A 10 'Active tracks'"

Write-Output "`n=== MEMORY USAGE DURING FULL PLAYBACK ==="
& $adb -s 192.168.1.8:5555 shell "dumpsys meminfo it.mediaset.infinitytv | grep -E 'TOTAL|Native|Dalvik'"
