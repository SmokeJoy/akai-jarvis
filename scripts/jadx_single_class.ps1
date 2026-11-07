$jdk = (Resolve-Path "tools\jdk-17").Path
$env:JAVA_HOME = $jdk
$env:PATH = "$jdk\bin;$env:PATH"

$apk = (Resolve-Path "scratch\raiplay_base.apk").Path
$out = "scratch\jadx_classes"

& "tools\jadx\bin\jadx.bat" --single-class "it.rai.raiplay.androidtv.WebMessageBridgeInstaller" -d $out $apk
