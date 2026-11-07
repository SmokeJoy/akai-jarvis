$url = "https://raiplay-android-tv.it.uptodown.com/android/versions"
$html = (Invoke-WebRequest -Uri $url -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -UseBasicParsing).Content
[System.IO.File]::WriteAllText("scratch\uptodown_versions.html", $html)
Write-Host "Length:" $html.Length
$matches = [regex]::Matches($html, '4\.2\.11|4\.[0-9]+')
Write-Host "Found version matches:" $matches.Count
foreach ($m in ($matches | Select-Object -First 10)) {
    Write-Host $m.Value
}
