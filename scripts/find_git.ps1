$searchLocations = @(
    "C:\Program Files\Git\cmd\git.exe",
    "C:\Program Files\Git\bin\git.exe",
    "C:\Program Files (x86)\Git\cmd\git.exe",
    "C:\Users\danie\AppData\Local\Programs\Git\cmd\git.exe",
    "C:\Users\danie\AppData\Local\Programs\Git\bin\git.exe",
    "C:\Users\danie\scoop\shims\git.exe",
    "C:\Program Files\GitHub CLI\gh.exe",
    "C:\Users\danie\AppData\Local\Programs\GitHub CLI\gh.exe",
    "C:\Users\danie\scoop\shims\gh.exe"
)

foreach ($loc in $searchLocations) {
    if (Test-Path $loc) {
        Write-Host "FOUND: $loc"
    }
}

# Also search Registry or Environment Path
Write-Host "PATH env:"
$env:PATH -split ';' | Where-Object { $_ -match 'git|github' } | ForEach-Object { Write-Host "In PATH: $_" }
