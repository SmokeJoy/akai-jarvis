$bytes = [System.IO.File]::ReadAllBytes("scratch/dex/classes3.dex")
$str = [System.Text.Encoding]::ASCII.GetString($bytes)

$idx = 0
while (($idx = $str.IndexOf("PlaybackCapabilitiesStore", $idx)) -ge 0) {
    $start = [Math]::Max(0, $idx - 150)
    $len = [Math]::Min($str.Length - $start, 400)
    $snip = $str.Substring($start, $len)
    $clean = ($snip -split "[^a-zA-Z0-9_\.:\-\/$]+" | Where-Object { $_.Length -ge 3 }) -join " "
    Write-Output "=== PlaybackCapabilitiesStore @ $idx ==="
    Write-Output $clean
    $idx += 25
}
