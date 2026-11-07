$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Host "=== 1. Kernel Cmdline & Panel Info ==="
& $adb -s 192.168.1.8:5555 shell "cat /proc/cmdline"
& $adb -s 192.168.1.8:5555 shell "getprop | grep -iE 'panel|display|mstar|mediatek|4k|uhd|resolution|vbyone|lvds'"

Write-Host "`n=== 2. DRM & Widevine Properties ==="
& $adb -s 192.168.1.8:5555 shell "getprop | grep -iE 'drm|widevine|crypto'"
& $adb -s 192.168.1.8:5555 shell "ls -la /vendor/lib/mediadrm /system/lib/mediadrm"

Write-Host "`n=== 3. Media Codecs XML ==="
& $adb -s 192.168.1.8:5555 pull /vendor/etc/media_codecs.xml scratch/vendor_media_codecs.xml
& $adb -s 192.168.1.8:5555 pull /system/etc/media_codecs.xml scratch/system_media_codecs.xml
& $adb -s 192.168.1.8:5555 pull /vendor/etc/media_codecs_performance.xml scratch/vendor_media_codecs_perf.xml 2>$null

Write-Host "`n=== 4. Play Protect / Fingerprint ==="
& $adb -s 192.168.1.8:5555 shell "getprop | grep -iE 'fingerprint|build.version|model|brand|manufacturer'"
