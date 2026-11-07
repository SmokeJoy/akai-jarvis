$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

& $adb -s 192.168.1.8:5555 shell "screencap -p /sdcard/screen_raiplay_now.png"
& $adb -s 192.168.1.8:5555 pull /sdcard/screen_raiplay_now.png "C:\Users\danie\.gemini\antigravity\brain\301a5daf-4835-45b9-b7d1-86d5907a0c37\screen_raiplay_now.png"

Write-Output "=== TOP WINDOW ==="
& $adb -s 192.168.1.8:5555 shell "dumpsys window windows | grep -E 'mCurrentFocus|mFocusedApp'"

Write-Output "=== LOGCAT RAIPLAY ==="
& $adb -s 192.168.1.8:5555 logcat -d -t 150 | Select-String -Pattern "it.rainet|chromium|WebView|ExoPlayer|MediaCodec|DRM" | Select-Object -Last 30
