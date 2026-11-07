$jdk = (Resolve-Path "tools\jdk-17").Path
$env:JAVA_HOME = $jdk
$env:PATH = "$jdk\bin;$env:PATH"

& "tools\jadx\bin\jadx.bat" --version
