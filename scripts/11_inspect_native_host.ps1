$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null
& $adb -s 192.168.1.8:5555 forward tcp:9222 localabstract:webview_devtools_remote_10881

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

# 1. NativeHostBridge source code
$r1 = Send-Cdp "Runtime.evaluate" @{ expression = "NativeHostBridge.getCapabilities.toString()" ; returnByValue = $true }
Write-Output "=== NativeHostBridge.getCapabilities code ==="
Write-Output $r1.result.result.value

# 2. What is window.__androidTvCapabilities ?
$r2 = Send-Cdp "Runtime.evaluate" @{ expression = "window.__androidTvCapabilities ? JSON.stringify(window.__androidTvCapabilities) : 'no __androidTvCapabilities'" ; returnByValue = $true }
Write-Output "`n=== window.__androidTvCapabilities ==="
Write-Output $r2.result.result.value

# 3. What injected Java interface exists?
$r3 = Send-Cdp "Runtime.evaluate" @{ expression = "Object.keys(window).filter(k => typeof window[k] === 'object' && window[k] !== null && window[k].constructor && window[k].constructor.name === 'Object')" ; returnByValue = $true }
Write-Output "`n=== Candidate JavascriptInterface objects ==="
Write-Output ($r3.result.result.value -join ', ')
