$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null
Start-Sleep -Milliseconds 300

Write-Output "=== 1. WIDEVINE E DRM PROPS ==="
& $adb -s 192.168.1.8:5555 shell "getprop | grep -i drm"
& $adb -s 192.168.1.8:5555 shell "getprop | grep -i crypto"
& $adb -s 192.168.1.8:5555 shell "ls -la /vendor/tvcertificate/"

Write-Output "`n=== 2. HBBTV E DTV PACKAGES ==="
& $adb -s 192.168.1.8:5555 shell "pm list packages | grep -E 'hbbtv|dtv|tv|mediatek'"
& $adb -s 192.168.1.8:5555 shell "find /system /vendor -name '*hbbtv*' 2>/dev/null"

Write-Output "`n=== 3. MEDIA CODECS XML FILES ==="
& $adb -s 192.168.1.8:5555 shell "ls -la /vendor/etc/*codec* /system/etc/*codec* 2>/dev/null"

Write-Output "`n=== 4. WEBVIEW STATE ==="
& $adb -s 192.168.1.8:5555 shell "pm list packages -f | grep webview"
& $adb -s 192.168.1.8:5555 shell "dumpsys webviewupdate"
