$dexPath = "C:\Users\danie\OneDrive\Documenti\Antygravity\Akay\scratch\dex\classes3.dex"
$bytes = [System.IO.File]::ReadAllBytes($dexPath)
$chars = [System.Text.Encoding]::ASCII.GetString($bytes)

$idx = $chars.IndexOf("displayBelowUhd:")
$start = [Math]::Max(0, $idx - 1000)
$len = 2000
$snippet = $chars.Substring($start, $len)
$clean = ($snippet -split "[^a-zA-Z0-9_\.:\-\/$]+" | Where-Object { $_.Length -ge 3 }) -join "`n"
Write-Output $clean
