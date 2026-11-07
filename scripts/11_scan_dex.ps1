Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead("C:\Users\danie\OneDrive\Documenti\Antygravity\Akay\scratch\raiplay_base.apk")

$dexFiles = $zip.Entries | Where-Object { $_.Name -like "classes*.dex" }
Write-Output "Found DEX entries: $($dexFiles.Count)"

$extractDir = "C:\Users\danie\OneDrive\Documenti\Antygravity\Akay\scratch\dex"
if (-not (Test-Path $extractDir)) { New-Item -ItemType Directory -Path $extractDir | Out-Null }

foreach ($entry in $dexFiles) {
    $outPath = Join-Path $extractDir $entry.Name
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $outPath, $true)
    Write-Output "Extracted: $($entry.Name) ($($entry.Length) bytes)"
}
$zip.Dispose()

# Now search strings in the DEX files
foreach ($dex in Get-ChildItem $extractDir -Filter "*.dex") {
    Write-Output "=== Scanning $($dex.Name) ==="
    $bytes = [System.IO.File]::ReadAllBytes($dex.FullName)
    # Simple ASCII string extraction
    $chars = [System.Text.Encoding]::ASCII.GetString($bytes)
    $matches = [regex]::Matches($chars, '[a-zA-Z0-9_\.]{4,60}')
    $matches | ForEach-Object { $_.Value } | Where-Object { $_ -match 'nativePlayer|nativeHttp|isNativePlayer|getCapabilities' } | Select-Object -Unique | ForEach-Object {
        Write-Output "Match: $_"
    }
}
