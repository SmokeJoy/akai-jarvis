$url = "https://nodejs.org/dist/latest-v22.x/node-v22.23.4-win-x64.zip"
$zipPath = "tools\node-v22.23.4-win-x64.zip"
$targetDir = "tools\nodejs"

if (-not (Test-Path "$targetDir\node.exe")) {
    Write-Host "Downloading Node.js 22.23.4 portable zip..." -ForegroundColor Cyan
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
    Write-Host "Extracting to tools\..." -ForegroundColor Cyan
    Expand-Archive -Path $zipPath -DestinationPath "tools" -Force
    Remove-Item $zipPath -Force
    if (Test-Path "tools\node-v22.23.4-win-x64") {
        if (Test-Path $targetDir) { Remove-Item $targetDir -Recurse -Force }
        Rename-Item -Path "tools\node-v22.23.4-win-x64" -NewName "nodejs"
    }
    Write-Host "Node.js 22 portable installed in $targetDir!" -ForegroundColor Green
} else {
    Write-Host "Node.js already present in $targetDir" -ForegroundColor Green
}

& "$targetDir\node.exe" -v
& "$targetDir\npm.cmd" -v
