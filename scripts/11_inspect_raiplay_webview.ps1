$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Output "=== APP_WEBVIEW FILES ==="
& $adb -s 192.168.1.8:5555 shell "su 0 ls -la /data/data/it.rainet.androidtv/app_webview/"

Write-Output "`n=== RECENT NETWORK CONNECTIONS BY RAIPLAY ==="
& $adb -s 192.168.1.8:5555 shell "su 0 netstat -tunp | grep 10881"

Write-Output "`n=== LOGCAT CHROMIUM WEBVIEW (LAST 200 LINES) ==="
& $adb -s 192.168.1.8:5555 shell "logcat -d -s chromium:* cr_MediaCodecBridge:* chromium-net:*"
