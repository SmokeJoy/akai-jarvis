$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null

Write-Output "=== FORWARDING DEVTOOLS PORT 9222 ==="
& $adb -s 192.168.1.8:5555 forward tcp:9222 localabstract:webview_devtools_remote_10881

Start-Sleep -Milliseconds 500

Write-Output "=== QUERYING CHROMIUM DEVTOOLS JSON LIST ==="
try {
    $res = Invoke-RestMethod -Uri "http://127.0.0.1:9222/json/list" -TimeoutSec 5
    $res | ForEach-Object {
        Write-Output "Title: $($_.title)"
        Write-Output "URL: $($_.url)"
        Write-Output "WebSocket: $($_.webSocketDebuggerUrl)"
        Write-Output "-------------------------"
    }
} catch {
    Write-Output "Error querying devtools: $_"
}
