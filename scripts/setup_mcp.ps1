$dest = "tools\mcp"
if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest | Out-Null }

$base = (Resolve-Path "$PSScriptRoot\..").Path
$env:PATH = "$base\tools\nodejs;$env:PATH"

Set-Location $dest
if (-not (Test-Path "package.json")) {
    & "$base\tools\nodejs\npm.cmd" init -y | Out-Null
}

Write-Host "Installing rea-agents and jadx-mcp in tools\mcp..." -ForegroundColor Cyan
& "$base\tools\nodejs\npm.cmd" install --save rea-agents jadx-mcp
Write-Host "Installation completed!" -ForegroundColor Green
