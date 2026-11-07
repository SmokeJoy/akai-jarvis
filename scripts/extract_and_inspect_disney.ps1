$aapt = "tools\android-sdk\build-tools\28.0.3\aapt.exe"
$keytool = "tools\jdk-17\bin\keytool.exe"

$src = Get-ChildItem "scratch\disney_download" -Filter "*.apkm" | Select-Object -First 1
Write-Host "Source bundle: $($src.FullName) ($($src.Length) bytes)"

$destDir = "scratch\disney_splits"
if (Test-Path $destDir) { Remove-Item $destDir -Recurse -Force }
New-Item -ItemType Directory -Path $destDir | Out-Null

Write-Host "Extracting bundle..."
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($src.FullName, (Resolve-Path $destDir).Path)

Write-Host "Extracted files:"
$files = Get-ChildItem $destDir
foreach ($f in $files) {
    Write-Host " - $($f.Name) ($($f.Length) bytes)"
}

Write-Host "`n=== BADGING BASE.APK ==="
& $aapt dump badging "$destDir\base.apk" | Select-String -Pattern "package:|sdkName|targetSdk|minSdk|uses-feature|launchable-activity|leanback"

Write-Host "`n=== SIGNATURE CHECK ==="
& $keytool -printcert -jarfile "$destDir\base.apk"
