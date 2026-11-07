$jdk = "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay\tools\jdk-17\bin"
$keytool = "$jdk\keytool.exe"

$v5 = "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay\scratch\raiplay_base.apk"
$v4 = "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay\scratch\raiplay_4.2.11.apk"

Write-Host "=== HASH SHA-256 ==="
Write-Host "RaiPlay 5.0.1 (Base TV):" (Get-FileHash $v5 -Algorithm SHA256).Hash
Write-Host "RaiPlay 4.2.11:" (Get-FileHash $v4 -Algorithm SHA256).Hash

Write-Host "`n=== SIGNATURE CERTIFICATE v5.0.1 ==="
& $keytool -printcert -jarfile $v5

Write-Host "`n=== SIGNATURE CERTIFICATE v4.2.11 ==="
& $keytool -printcert -jarfile $v4
