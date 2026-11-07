$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Host "1. Clearing logcat..."
& $adb -s 192.168.1.8:5555 logcat -c

Write-Host "2. Pressing ENTER (DPAD_CENTER) on RIPRODUCI..."
& $adb -s 192.168.1.8:5555 shell input keyevent 23

Write-Host "3. Waiting 6 seconds for player initialization and stream buffering..."
Start-Sleep -Seconds 6

Write-Host "4. Capturing window focus..."
$focus = & $adb -s 192.168.1.8:5555 shell "dumpsys window windows | grep -E 'mCurrentFocus|mFocusedApp'"
Write-Host "Focus: $focus"

Write-Host "5. Capturing screenshot..."
& $adb -s 192.168.1.8:5555 shell screencap -p /sdcard/screen_raiplay4_player.png
& $adb -s 192.168.1.8:5555 pull /sdcard/screen_raiplay4_player.png scratch/screen_raiplay4_player.png
Copy-Item scratch/screen_raiplay4_player.png "C:\Users\danie\.gemini\antigravity\brain\301a5daf-4835-45b9-b7d1-86d5907a0c37\screen_raiplay4_player.png"

Write-Host "6. Checking MediaCodec and ExoPlayer logs..."
$logs = & $adb -s 192.168.1.8:5555 shell "logcat -d | grep -iE 'ExoPlayer|MediaCodec|OMX|video/avc|it.rainet|PlayerActivity'"
$logs | Out-File -FilePath scratch/raiplay4_playback_analysis.log -Encoding utf8
Write-Host "Relevant log sample:"
$logs | Select-Object -Last 30
