. "$PSScriptRoot\set_env.ps1"

Write-Host "=== TESTING JADX-MCP ===" -ForegroundColor Cyan
try {
    & "$PSScriptRoot\..\tools\mcp\node_modules\.bin\jadx-mcp.cmd" --help
} catch {
    Write-Host "jadx-mcp error: $_" -ForegroundColor Red
}

Write-Host "`n=== TESTING REA ===" -ForegroundColor Cyan
try {
    & "$PSScriptRoot\..\tools\mcp\node_modules\.bin\rea.cmd" --version
} catch {
    Write-Host "rea error: $_" -ForegroundColor Red
}
