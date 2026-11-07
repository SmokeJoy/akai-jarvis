$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null
Start-Sleep -Milliseconds 300

Write-Output "=== CLEARING LOGCAT & STARTING MEDIASET INFINITY ==="
& $adb -s 192.168.1.8:5555 logcat -c
& $adb -s 192.168.1.8:5555 shell "am start -n it.mediaset.infinitytv/it.mediaset.mediasetplay.ctv.MainActivity"

Start-Sleep -Seconds 5

Write-Output "`n=== CHECKING TOP WINDOW ==="
& $adb -s 192.168.1.8:5555 shell "dumpsys window windows | grep -E 'mCurrentFocus|mFocusedApp'"

Write-Output "`n=== LOGCAT ERRORS & APP LOGS ==="
& $adb -s 192.168.1.8:5555 logcat -d -t 200 | Select-String -Pattern "it.mediaset|chromium|WebView|FATAL|AndroidRuntime|System.err|OMX" | Select-Object -First 40

Write-Output "`n=== SCREENSHOT ==="
& $adb -s 192.168.1.8:5555 shell "screencap -p /sdcard/screen_mediaset_test.png"
& $adb -s 192.168.1.8:5555 pull /sdcard/screen_mediaset_test.png "C:\Users\danie\.gemini\antigravity\brain\301a5daf-4835-45b9-b7d1-86d5907a0c37\screen_mediaset_test.png"
