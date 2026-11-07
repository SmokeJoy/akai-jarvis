$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555
Start-Sleep -Milliseconds 500

Write-Output "=== DRM PROCESSES ==="
& $adb -s 192.168.1.8:5555 shell "ps -A | grep -i drm"

Write-Output "`n=== DRM LIBRARIES ==="
& $adb -s 192.168.1.8:5555 shell "ls -la /vendor/lib/mediadrm/ /system/lib/mediadrm/ 2>/dev/null"

Write-Output "`n=== TEE AND OPTEE STATUS ==="
& $adb -s 192.168.1.8:5555 shell "ls -la /dev/tee* /dev/teepriv* 2>/dev/null"
& $adb -s 192.168.1.8:5555 shell "dmesg | grep -i -E 'tee|optee|drm|widevine' | head -n 30"

Write-Output "`n=== DUMPSYS DRM.DRMMANAGER ==="
& $adb -s 192.168.1.8:5555 shell "dumpsys drm.drmManager"


