$dir = "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay\AKAI_AUDIT_COMPLETO"
$files = Get-ChildItem $dir

$results = foreach ($f in $files) {
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($f.FullName)
    $hash = ($hasher.ComputeHash($stream) | ForEach-Object { $_.ToString("x2") }) -join ""
    $stream.Close()
    [PSCustomObject]@{
        Name = $f.Name
        Size_KB = [Math]::Round($f.Length / 1KB, 2)
        SHA256 = $hash
    }
}

$results | Format-Table -AutoSize
