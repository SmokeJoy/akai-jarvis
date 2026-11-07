$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null
& $adb -s 192.168.1.8:5555 forward tcp:9222 localabstract:webview_devtools_remote_10881
Start-Sleep -Milliseconds 400

$list = Invoke-RestMethod -Uri "http://127.0.0.1:9222/json/list" -TimeoutSec 5
$wsUrl = $list[0].webSocketDebuggerUrl

Add-Type -AssemblyName System.Net.Http
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$cts = New-Object System.Threading.CancellationTokenSource(5000)
$ws.ConnectAsync([System.Uri]$wsUrl, $cts.Token).Wait()

function Send-Cdp($command, $params=@{}) {
    $id = [System.Environment]::TickCount
    $req = @{ id = $id; method = $command; params = $params } | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($req)
    $segment = New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)
    $ws.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait()
    
    $buffer = New-Object byte[] 65536
    $recvSegment = New-Object System.ArraySegment[byte] -ArgumentList @(,$buffer)
    $recvTask = $ws.ReceiveAsync($recvSegment, [System.Threading.CancellationToken]::None)
    $recvTask.Wait()
    $jsonStr = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $recvTask.Result.Count)
    return $jsonStr | ConvertFrom-Json
}

# 1. Install Hook on NotificationManager.ShowMessage and window.onerror
$hookScript = @"
window._capturedErrors = [];
if (window.NotificationManager && window.NotificationManager.ShowMessage) {
    window._origShowMessage = window.NotificationManager.ShowMessage;
    window.NotificationManager.ShowMessage = function(msg, duration) {
        window._capturedErrors.push({
            type: 'ShowMessage',
            msg: msg,
            stack: new Error().stack
        });
        return window._origShowMessage.apply(this, arguments);
    };
}
window.addEventListener('error', function(e) {
    window._capturedErrors.push({
        type: 'window.onerror',
        msg: e.message,
        filename: e.filename,
        lineno: e.lineno,
        colno: e.colno,
        stack: e.error ? e.error.stack : null
    });
});
window.addEventListener('unhandledrejection', function(e) {
    window._capturedErrors.push({
        type: 'unhandledrejection',
        reason: e.reason ? (e.reason.message || e.reason.toString()) : null,
        stack: e.reason ? e.reason.stack : null
    });
});
'hook_installed'
"@

$rHook = Send-Cdp "Runtime.evaluate" @{ expression = $hookScript ; returnByValue = $true }
Write-Output "Hook installed: $($rHook.result.result.value)"

# 2. Trigger playback click: on hero "RIPRODUCI"
# First let's press BACK to return to Home if on Dirette, or navigate to RIPRODUCI
Write-Output "Triggering click on RIPRODUCI..."
& $adb -s 192.168.1.8:5555 shell "input keyevent 4"
Start-Sleep -Seconds 1
& $adb -s 192.168.1.8:5555 shell "input keyevent 21"
Start-Sleep -Milliseconds 400
& $adb -s 192.168.1.8:5555 shell "input keyevent 19"
Start-Sleep -Milliseconds 400
& $adb -s 192.168.1.8:5555 shell "input keyevent 23"
Start-Sleep -Seconds 2
# Now on Home, click RIPRODUCI
& $adb -s 192.168.1.8:5555 shell "input keyevent 23"
Start-Sleep -Seconds 3

# 3. Retrieve captured errors!
$rErrors = Send-Cdp "Runtime.evaluate" @{ expression = "window._capturedErrors" ; returnByValue = $true }
Write-Output "Captured errors:"
Write-Output ($rErrors.result.result.value | ConvertTo-Json -Depth 5)
