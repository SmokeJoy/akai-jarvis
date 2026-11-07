$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Host "1. Clearing logcat..."
& $adb -s 192.168.1.8:5555 logcat -c

Write-Host "2. Launching Disney+ (com.bamtechmedia.dominguez.main.MainActivity)..."
$startRes = & $adb -s 192.168.1.8:5555 shell "am start -n com.disney.disneyplus/com.bamtechmedia.dominguez.main.MainActivity"
Write-Host "Start output: $startRes"

Write-Host "3. Waiting 8 seconds for Disney+ startup..."
Start-Sleep -Seconds 8

Write-Host "4. Capturing top activity and window focus..."
$focus = & $adb -s 192.168.1.8:5555 shell "dumpsys window windows | grep -E 'mCurrentFocus|mFocusedApp'"
Write-Host "Focus: $focus"

Write-Host "5. Capturing screenshot..."
& $adb -s 192.168.1.8:5555 shell screencap -p /sdcard/screen_disney_start.png
& $adb -s 192.168.1.8:5555 pull /sdcard/screen_disney_start.png scratch/screen_disney_start.png
Copy-Item scratch/screen_disney_start.png "C:\Users\danie\.gemini\antigravity\brain\301a5daf-4835-45b9-b7d1-86d5907a0c37\screen_disney_start.png" -Force

Write-Host "6. Checking meminfo for com.disney.disneyplus..."
$mem = & $adb -s 192.168.1.8:5555 shell "dumpsys meminfo com.disney.disneyplus | grep -E 'TOTAL PSS:|Native Heap|Dalvik Heap'"
Write-Host "Meminfo: $mem"

Write-Host "7. Dumping initial logcat for Disney+..."
& $adb -s 192.168.1.8:5555 shell "logcat -d | grep -iE 'disney|bamtech|chromium|fatal|crash' | tail -n 50"
