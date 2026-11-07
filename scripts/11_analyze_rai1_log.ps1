$f = Get-Item "C:\Users\danie\.gemini\antigravity\brain\301a5daf-4835-45b9-b7d1-86d5907a0c37\rai1_live_raw.log"
Write-Output "File size: $($f.Length)"
if ($f.Length -gt 0) {
    Get-Content $f.FullName | Select-String -Pattern "10881|it\.rainet|chromium|WebView|Media|Audio|Video|HTTP|SSL|TLS|DRM" | Select-Object -First 30
}
