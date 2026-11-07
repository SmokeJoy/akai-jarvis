# ==============================================================================
# AKAI Custom TV - Script: Generazione Keystore TLS e Root CA per Smart TV e Client
# Genera certificato Server per 192.168.1.8 e Root CA per iPhone/Android
# ==============================================================================

$ErrorActionPreference = "Stop"

$workspace = "C:\Users\danie\OneDrive\Documenti\Antygravity\Akay"
$toolsDir = Join-Path $workspace "tools"
$keytool = Join-Path $toolsDir "jdk-17\bin\keytool.exe"

$caP12 = Join-Path $toolsDir "akai_ca.p12"
$caCrt = Join-Path $toolsDir "AkaiRootCA.crt"
$serverP12 = Join-Path $toolsDir "server_keystore.p12"
$serverCsr = Join-Path $toolsDir "server.csr"
$serverSignedCrt = Join-Path $toolsDir "server_signed.crt"
$pass = "akai1234"

Write-Host "=== GENERAZIONE CERTIFICATI TLS ATTENDIBILI PER AKAI CUSTOM REMOTE ===" -ForegroundColor Cyan

# Clean previous files
Remove-Item $caP12, $caCrt, $serverP12, $serverCsr, $serverSignedCrt -Force -ErrorAction SilentlyContinue

Write-Host "[1/6] Generazione Root CA privata locale..."
& $keytool "-J-Dkeystore.pkcs12.legacy" -genkeypair -alias akai_ca -keyalg RSA -keysize 2048 -validity 3650 -keystore $caP12 -storepass $pass -keypass $pass -dname "CN=AKAI Remote Root CA, O=AkaiCustom, C=IT" -ext "bc:c"

Write-Host "[2/6] Esportazione certificato pubblico Root CA (AkaiRootCA.crt)..."
& $keytool "-J-Dkeystore.pkcs12.legacy" -exportcert -alias akai_ca -keystore $caP12 -storepass $pass -file $caCrt -rfc

Write-Host "[3/6] Generazione coppia di chiavi per il server TV (192.168.1.8)..."
& $keytool "-J-Dkeystore.pkcs12.legacy" -genkeypair -alias akai_server -keyalg RSA -keysize 2048 -validity 1825 -keystore $serverP12 -storepass $pass -keypass $pass -dname "CN=192.168.1.8, O=AkaiCustom, C=IT" -ext "san=ip:192.168.1.8,dns:smarttv.local,dns:akai.local,dns:localhost,ip:127.0.0.1"

Write-Host "[4/6] Creazione Certificate Signing Request (CSR)..."
& $keytool "-J-Dkeystore.pkcs12.legacy" -certreq -alias akai_server -keystore $serverP12 -storepass $pass -file $serverCsr -ext "san=ip:192.168.1.8,dns:smarttv.local,dns:akai.local,dns:localhost,ip:127.0.0.1"

Write-Host "[5/6] Firma del certificato server con la Root CA locale..."
& $keytool "-J-Dkeystore.pkcs12.legacy" -gencert -alias akai_ca -keystore $caP12 -storepass $pass -infile $serverCsr -outfile $serverSignedCrt -validity 1825 -ext "san=ip:192.168.1.8,dns:smarttv.local,dns:akai.local,dns:localhost,ip:127.0.0.1"

Write-Host "[6/6] Importazione catena certificati nel server keystore..."
& $keytool "-J-Dkeystore.pkcs12.legacy" -importcert -noprompt -alias akai_ca -keystore $serverP12 -storepass $pass -file $caCrt
& $keytool "-J-Dkeystore.pkcs12.legacy" -importcert -noprompt -alias akai_server -keystore $serverP12 -storepass $pass -file $serverSignedCrt

# Copy to Android Assets
$assetsDir = Join-Path $workspace "akai-remote-tv\app\src\main\assets"
$wwwDir = Join-Path $assetsDir "www"
Copy-Item $serverP12 (Join-Path $assetsDir "server_keystore.p12") -Force
Copy-Item $caCrt (Join-Path $wwwDir "AkaiRootCA.crt") -Force
Copy-Item $caCrt (Join-Path $workspace "akai-remote-web\AkaiRootCA.crt") -Force

Write-Host "`nOperazione completata con successo!" -ForegroundColor Green
Write-Host "Keystore Server Android: $assetsDir\server_keystore.p12"
Write-Host "Certificato Root CA Client: $wwwDir\AkaiRootCA.crt"
