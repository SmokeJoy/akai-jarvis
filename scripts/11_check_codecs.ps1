$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555
Start-Sleep -Milliseconds 500

Write-Output "=== 1. DUMPSYS MEDIA.DRM ==="
& $adb -s 192.168.1.8:5555 shell dumpsys media.drm

Write-Output "`n=== 2. MEDIA_CODECS.XML (DECODERS) ==="
& $adb -s 192.168.1.8:5555 shell "grep -E '<MediaCodec name=' /vendor/etc/media_codecs.xml"

Write-Output "`n=== 3. MEDIA_EXTRACTOR & PLAYBACK CODECS ==="
& $adb -s 192.168.1.8:5555 shell dumpsys media.player

Write-Output "`n=== 4. HBBTV REFERENCES IN TVCENTER ==="
& $adb -s 192.168.1.8:5555 shell "grep -rn 'hbbtv' /system/framework/ /vendor/framework/ 2>/dev/null"
