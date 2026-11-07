$dexFiles = Get-ChildItem -Path "scratch/dex/*.dex"
foreach ($f in $dexFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $str = [System.Text.Encoding]::ASCII.GetString($bytes)
    if ($str.Contains("AndroidTvHost")) {
        Write-Output "Found AndroidTvHost in $($f.Name)"
        $idx = 0
        while (($idx = $str.IndexOf("AndroidTvHost", $idx)) -ge 0) {
            $start = [Math]::Max(0, $idx - 100)
            $len = [Math]::Min($str.Length - $start, 250)
            $snip = $str.Substring($start, $len)
            $clean = ($snip -split "[^a-zA-Z0-9_\.:\-\/$]+" | Where-Object { $_.Length -ge 3 }) -join " "
            Write-Output "  [$($f.Name) @ $idx]: $clean"
            $idx += 13
        }
    }
}
