foreach ($dex in Get-ChildItem "C:\Users\danie\OneDrive\Documenti\Antygravity\Akay\scratch\dex" -Filter "*.dex") {
    $bytes = [System.IO.File]::ReadAllBytes($dex.FullName)
    $chars = [System.Text.Encoding]::ASCII.GetString($bytes)
    if ($chars.Contains("MainActivity")) {
        Write-Output "Found MainActivity in $($dex.Name)"
        $idx = $chars.IndexOf("MainActivity")
        while ($idx -ge 0) {
            $snippet = $chars.Substring([Math]::Max(0, $idx - 50), [Math]::Min(200, $chars.Length - $idx))
            $clean = ($snippet -split "[^a-zA-Z0-9_\.:\-\/$]+" | Where-Object { $_.Length -ge 3 }) -join " "
            Write-Output "  -> $clean"
            $idx = $chars.IndexOf("MainActivity", $idx + 50)
            if ($idx -gt 0 -and $idx -lt 1000) { break }
        }
    }
}
