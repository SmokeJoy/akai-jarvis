$url = "https://github.com/skylot/jadx/releases/download/v1.5.6/jadx-1.5.6.zip"
$zipPath = "tools\jadx-1.5.6.zip"
$destDir = "tools\jadx"

if (-not (Test-Path "$destDir\bin\jadx.bat")) {
    Write-Host "Downloading JADX 1.5.6 from GitHub..." -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
    Write-Host "Extracting JADX to $destDir..." -ForegroundColor Cyan
    Expand-Archive -Path $zipPath -DestinationPath $destDir -Force
    Remove-Item $zipPath -Force
    Write-Host "JADX extracted successfully!" -ForegroundColor Green
} else {
    Write-Host "JADX already installed in $destDir" -ForegroundColor Green
}
