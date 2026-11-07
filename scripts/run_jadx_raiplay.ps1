$jdk = (Resolve-Path "tools\jdk-17").Path
$env:JAVA_HOME = $jdk
$env:PATH = "$jdk\bin;$env:PATH"

$apk = (Resolve-Path "scratch\raiplay_base.apk").Path
$out = "scratch\jadx_out"

Write-Host "Running JADX on $apk targeting it.rai.raiplay.androidtv..." -ForegroundColor Cyan
& "tools\jadx\bin\jadx.bat" -d $out -f --include-pkg "it.rai.raiplay.androidtv" $apk
Write-Host "JADX decompilation complete!" -ForegroundColor Green
