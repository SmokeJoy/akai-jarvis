$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Output "=== PRESSING DPAD_CENTER ON SELECTED TILE ==="
& $adb -s 192.168.1.8:5555 shell "input keyevent 23"

Start-Sleep -Seconds 4

Write-Output "=== CAPTURING SCREENSHOT AFTER CLICK ==="
& $adb -s 192.168.1.8:5555 shell "screencap -p /sdcard/screen_mediaset_play.png"
& $adb -s 192.168.1.8:5555 pull /sdcard/screen_mediaset_play.png "C:\Users\danie\.gemini\antigravity\brain\301a5daf-4835-45b9-b7d1-86d5907a0c37\screen_mediaset_play.png"

Write-Output "`n=== LOGCAT VIDEO PLAYBACK / MEDIACODEC ==="
& $adb -s 192.168.1.8:5555 logcat -d -t 150 | Select-String -Pattern "OMX|MediaCodec|mediadrm|widevine|chromium|player|exoplayer" | Select-Object -First 30
