$dexPath = "C:\Users\danie\OneDrive\Documenti\Antygravity\Akay\scratch\dex\classes3.dex"
$bytes = [System.IO.File]::ReadAllBytes($dexPath)

# Search all UTF-8/ASCII strings in the dex
# Dex strings start with length byte followed by null-terminated utf8
$strings = New-Object System.Collections.Generic.List[string]
$pos = 0
while ($pos -lt $bytes.Length - 10) {
    if ($bytes[$pos] -ge 32 -and $bytes[$pos] -le 126) {
        $start = $pos
        while ($pos -lt $bytes.Length -and $bytes[$pos] -ge 32 -and $bytes[$pos] -le 126) {
            $pos++
        }
        if ($pos - $start -ge 4) {
            $str = [System.Text.Encoding]::ASCII.GetString($bytes, $start, $pos - $start)
            $strings.Add($str)
        }
    } else {
        $pos++
    }
}

Write-Output "Total strings: $($strings.Count)"
$strings | Where-Object { $_ -match 'NativePlayer|nativePlayer|NativePlayback|Availability|availability' } | Select-Object -Unique | ForEach-Object {
    Write-Output "STR: $_"
}
