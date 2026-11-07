$bytes = [System.IO.File]::ReadAllBytes("scratch/dex/classes3.dex")
$str = [System.Text.Encoding]::ASCII.GetString($bytes)

$matches = [regex]::Matches($str, "Lit/rai/raiplay/androidtv/nativeplayer/[a-zA-Z0-9_\$]+")
$unique = $matches | ForEach-Object { $_.Value } | Sort-Object -Unique
$unique
