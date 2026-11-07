$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null
& $adb -s 192.168.1.8:5555 forward tcp:9222 localabstract:webview_devtools_remote_10881
Start-Sleep -Milliseconds 400

$list = Invoke-RestMethod -Uri "http://127.0.0.1:9222/json/list" -TimeoutSec 5
$wsUrl = $list[0].webSocketDebuggerUrl
Write-Output "Target Title: $($list[0].title)"
Write-Output "WS URL: $wsUrl"

Add-Type -AssemblyName System.Net.Http
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$cts = New-Object System.Threading.CancellationTokenSource(5000)

$connectTask = $ws.ConnectAsync([System.Uri]$wsUrl, $cts.Token)
$connectTask.Wait()
Write-Output "Connected! State: $($ws.State)"

function Send-Cdp($command, $params=@{}) {
    $id = [System.Environment]::TickCount
    $req = @{ id = $id; method = $command; params = $params } | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($req)
    $segment = New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)
    $sendTask = $ws.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None)
    $sendTask.Wait()
    
    $buffer = New-Object byte[] 65536
    $recvSegment = New-Object System.ArraySegment[byte] -ArgumentList @(,$buffer)
    $recvTask = $ws.ReceiveAsync($recvSegment, [System.Threading.CancellationToken]::None)
    $recvTask.Wait()
    $jsonStr = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $recvTask.Result.Count)
    return $jsonStr | ConvertFrom-Json
}

# 1. User Agent
$r1 = Send-Cdp "Runtime.evaluate" @{ expression = "navigator.userAgent" }
Write-Output "User-Agent: $($r1.result.result.value)"

# 2. Check for video element in DOM
$r2 = Send-Cdp "Runtime.evaluate" @{ expression = "document.querySelector('video') ? { src: document.querySelector('video').src, currentSrc: document.querySelector('video').currentSrc, error: document.querySelector('video').error ? document.querySelector('video').error.message : null, readyState: document.querySelector('video').readyState } : 'No video tag'" ; returnByValue = $true }
Write-Output "Video Tag: $($r2.result.result.value | ConvertTo-Json -Compress)"

# 3. Check for any global player or error object
$r3 = Send-Cdp "Runtime.evaluate" @{ expression = "Object.keys(window).filter(k => k.match(/player|rai|video|app|shaka/i))" ; returnByValue = $true }
Write-Output "Window keys matching player/rai: $($r3.result.result.value -join ', ')"

$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "Done", [System.Threading.CancellationToken]::None).Wait()
