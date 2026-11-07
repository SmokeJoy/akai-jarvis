$dexPath = "C:\Users\danie\OneDrive\Documenti\Antygravity\Akay\scratch\dex\classes3.dex"
$bytes = [System.IO.File]::ReadAllBytes($dexPath)
$chars = [System.Text.Encoding]::ASCII.GetString($bytes)

# Find positions where NativePlayerAvailability or nativePlayerEnabled occurs
$regex = [regex]'NativePlayerAvailability|nativePlayerEnabled|installNativePlayerBridge'
$matches = $regex.Matches($chars)
foreach ($m in $matches) {
    $start = [Math]::Max(0, $m.Index - 200)
    $len = [Math]::Min($chars.Length - $start, 500)
    $snippet = $chars.Substring($start, $len)
    # clean printable strings
    $clean = ($snippet -split "[^a-zA-Z0-9_\.:\-\/ ]+" | Where-Object { $_.Length -ge 4 }) -join " "
    Write-Output "--- Snippet around $($m.Value) ---"
    Write-Output $clean
}
