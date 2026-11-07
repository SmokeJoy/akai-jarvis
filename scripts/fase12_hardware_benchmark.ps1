$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

$out = @{}

Write-Host "--- 1. Display & Resolution ---"
$out["wm_size"] = (& $adb -s 192.168.1.8:5555 shell "wm size").Trim()
$out["wm_density"] = (& $adb -s 192.168.1.8:5555 shell "wm density").Trim()
$out["dumpsys_display"] = (& $adb -s 192.168.1.8:5555 shell "dumpsys display | grep -E 'DisplayDeviceInfo|mDefaultDisplay|mDisplayModes|supportedModes|colorMode|hdrCapabilities|state=ON'")
$out["framebuffer"] = (& $adb -s 192.168.1.8:5555 shell "cat /sys/class/graphics/fb0/virtual_size /sys/class/graphics/fb0/modes 2>/dev/null")

Write-Host "--- 2. SurfaceFlinger & HWC ---"
$out["surfaceflinger"] = (& $adb -s 192.168.1.8:5555 shell "dumpsys SurfaceFlinger | grep -E 'Display|Refresh-Rate|type=Display|mode:|activeConfig|hwcomposer'")

Write-Host "--- 3. MediaTek Hardware Codecs ---"
$out["media_codecs"] = (& $adb -s 192.168.1.8:5555 shell "cat /vendor/etc/media_codecs.xml /system/etc/media_codecs.xml 2>/dev/null | grep -E '<MediaCodec name=\"OMX.MTK|<Type name=\"video'")

Write-Host "--- 4. DRM & Widevine ---"
$out["drm_dumpsys"] = (& $adb -s 192.168.1.8:5555 shell "dumpsys media.drm 2>/dev/null || dumpsys drm.drm_server 2>/dev/null")

Write-Host "--- 5. CPU, Frequencies & Thermals ---"
$out["cpu_info"] = (& $adb -s 192.168.1.8:5555 shell "cat /proc/cpuinfo | grep -E 'Hardware|Processor|model name|Features|BogoMIPS'")
$out["cpu_cur_freq"] = (& $adb -s 192.168.1.8:5555 shell "cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null")
$out["cpu_available_freq"] = (& $adb -s 192.168.1.8:5555 shell "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies 2>/dev/null")
$out["cpu_governor"] = (& $adb -s 192.168.1.8:5555 shell "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null")
$out["thermals"] = (& $adb -s 192.168.1.8:5555 shell "for z in /sys/class/thermal/thermal_zone*; do echo -n `cat `$z/type 2>/dev/null`: ; cat `$z/temp 2>/dev/null; done")

Write-Host "--- 6. RAM, ZRAM & Swap ---"
$out["meminfo"] = (& $adb -s 192.168.1.8:5555 shell "cat /proc/meminfo | grep -E 'MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|Zram'")
$out["zram"] = (& $adb -s 192.168.1.8:5555 shell "cat /proc/swaps; cat /sys/block/zram0/disksize 2>/dev/null; cat /sys/block/zram0/mm_stat 2>/dev/null")

Write-Host "--- 7. Storage I/O ---"
$out["df"] = (& $adb -s 192.168.1.8:5555 shell "df -h /data /system /vendor")

Write-Host "--- 8. Wi-Fi & Network ---"
$out["wifi"] = (& $adb -s 192.168.1.8:5555 shell "dumpsys wifi | grep -E 'mWifiInfo|curState=Completed|Link speed|RSSI|SSID|Frequency'")

$jsonStr = $out | ConvertTo-Json -Depth 5
$jsonStr | Out-File -FilePath "scratch/fase12_hardware_baseline.json" -Encoding utf8
Write-Host "Baseline saved to scratch/fase12_hardware_baseline.json."
