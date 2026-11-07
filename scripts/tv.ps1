$adbPath = (Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_*\platform-tools\adb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Path)
if (-not $adbPath) {
    throw "ADB binary not found in WinGet platform-tools"
}

$target = "192.168.1.8:5555"

function Invoke-TvAdb {
    param([string[]]$AdbArgs)
    & $adbPath -s $target @AdbArgs
}

# Ensure connected
$devices = & $adbPath devices
if ($devices -notmatch [regex]::Escape($target)) {
    Write-Host "Connecting to $target..." -ForegroundColor Cyan
    & $adbPath connect $target
}

if ($args.Count -gt 0) {
    & $adbPath -s $target @args
} else {
    & $adbPath devices -l
}
