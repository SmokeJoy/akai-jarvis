$drives = @("C:\Program Files", "C:\Users\danie\AppData\Local", "C:\Users\danie\AppData\Roaming", "C:\ProgramData")
foreach ($d in $drives) {
    if (Test-Path $d) {
        $found = Get-ChildItem -Path $d -Filter "git.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
        if ($found) {
            Write-Host "Found in $d : $found"
        }
    }
}
