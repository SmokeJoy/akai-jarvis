$dexPath = "C:\Users\danie\OneDrive\Documenti\Antygravity\Akay\scratch\dex\classes3.dex"
$bytes = [System.IO.File]::ReadAllBytes($dexPath)
$chars = [System.Text.Encoding]::ASCII.GetString($bytes)

$idx = $chars.IndexOf("PlaybackCapabilitiesStore")
while ($idx -ge 0) {
    $start = [Math]::Max(0, $idx - 300)
    $len = [Math]::Min($chars.Length - $start, 600)
    $snippet = $chars.Substring($start, $len)
    $clean = ($snippet -split "[^a-zA-Z0-9_\.:\-\/$]+" | Where-Object { $_.Length -ge 3 }) -join " "
    Write-Output "=== At $idx ==="
    Write-Output $clean
    $idx = $chars.IndexOf("PlaybackCapabilitiesStore", $idx + 1)
}
