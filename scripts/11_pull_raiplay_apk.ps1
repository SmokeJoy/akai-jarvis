$adb = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools\adb.exe"
& $adb connect 192.168.1.8:5555 | Out-Null
$targetDir = "C:\Users\danie\OneDrive\Documenti\Antygravity\Akay\scratch"
if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir | Out-Null }

$localApk = Join-Path $targetDir "raiplay_base.apk"
Write-Output "Pulling base.apk to $localApk..."
& $adb -s 192.168.1.8:5555 pull /data/app/it.rainet.androidtv-macUztuWjZ53LfbFmdXOwg==/base.apk $localApk
