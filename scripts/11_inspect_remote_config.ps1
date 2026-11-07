$xml = [xml](Get-Content "C:\Users\danie\OneDrive\Documenti\Antygravity\Akay\scratch\tv_config_cache.xml" -ErrorAction SilentlyContinue)
if (-not $xml) {
    # Pull fresh from TV
    $adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
    & $adb connect 192.168.1.8:5555 | Out-Null
    $content = & $adb -s 192.168.1.8:5555 shell "su 0 cat /data/data/it.rainet.androidtv/shared_prefs/tv_config_cache.xml"
    $content | Set-Content "C:\Users\danie\OneDrive\Documenti\Antygravity\Akay\scratch\tv_config_cache.xml"
    $xml = [xml]$content
}

# The json is inside a string tag with name starting with config:
$jsonNode = $xml.map.string | Where-Object { $_.name -like "*config*" }
$json = $jsonNode.InnerText | ConvertFrom-Json

Write-Output "Top-level keys in remote config:"
$json.PSObject.Properties | ForEach-Object { Write-Output "  $($_.Name)" }

Write-Output "`nKeys containing player, native or android:"
$json.PSObject.Properties | Where-Object { $_.Name -match 'player|native|android|video|device|model|media' } | ForEach-Object {
    Write-Output "[$($_.Name)]:"
    Write-Output ($_.Value | ConvertTo-Json -Depth 3)
}
