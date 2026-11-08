# ==============================================================================
# Compilazione Suite APK Distinti per Popolare Catalogo Emulatore Android TV
# Genera 8 pacchetti indipendenti conformi Leanback per collaudo reale righe
# ==============================================================================

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = $PSScriptRoot }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$workspace = (Resolve-Path (Join-Path $scriptDir "..")).Path

$toolsDir = Join-Path $workspace "tools"
$sdkDir = Join-Path $toolsDir "android-sdk"
$buildToolsDir = Join-Path $sdkDir "build-tools\28.0.3"
$platformJar = Join-Path $sdkDir "platforms\android-28\android.jar"

$aapt2 = Join-Path $buildToolsDir "aapt2.exe"
$d8Jar = Join-Path $buildToolsDir "lib\d8.jar"
$apksignerJar = Join-Path $buildToolsDir "lib\apksigner.jar"
$zipalign = Join-Path $buildToolsDir "zipalign.exe"
$jdkDir = Join-Path $toolsDir "jdk-17"
$javac = Join-Path $jdkDir "bin\javac.exe"
$java = Join-Path $jdkDir "bin\java.exe"

$appsDir = Join-Path $toolsDir "test-apps"
$outDir = Join-Path $appsDir "output"
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

function Write-Utf8NoBom($path, $text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

$appList = @(
    @{ Pkg = "test.tv.youtube"; Label = "YouTube TV" },
    @{ Pkg = "test.tv.netflix"; Label = "Netflix" },
    @{ Pkg = "test.tv.prime"; Label = "Prime Video" },
    @{ Pkg = "test.tv.raiplay"; Label = "RaiPlay" },
    @{ Pkg = "test.tv.disney"; Label = "Disney+" },
    @{ Pkg = "test.tv.infinity"; Label = "Mediaset Infinity" },
    @{ Pkg = "test.tv.vlc"; Label = "VLC Media Player" },
    @{ Pkg = "test.tv.kodi"; Label = "Kodi Media Center" }
)

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " COMPILAZIONE SUITE 8 APK STREAMING INDIPENDENTI PER EMULATORE   " -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

foreach ($app in $appList) {
    $pkg = $app.Pkg
    $lbl = $app.Label
    $appName = ($pkg -split "\.")[-1]
    Write-Host "Compilazione pacchetto: $pkg ($lbl)..." -ForegroundColor Yellow

    $tempDir = Join-Path $appsDir "temp_$appName"
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
    $genDir = Join-Path $tempDir "gen"
    $classesDir = Join-Path $tempDir "classes"
    $dexDir = Join-Path $tempDir "dex"
    $resDir = Join-Path $tempDir "res\values"
    New-Item -ItemType Directory -Force -Path $genDir | Out-Null
    New-Item -ItemType Directory -Force -Path $classesDir | Out-Null
    New-Item -ItemType Directory -Force -Path $dexDir | Out-Null
    New-Item -ItemType Directory -Force -Path $resDir | Out-Null

    $manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="$pkg"
    android:versionCode="1"
    android:versionName="1.0">
    <uses-feature android:name="android.software.leanback" android:required="false" />
    <application android:label="$lbl" android:icon="@android:drawable/sym_def_app_icon">
        <activity android:name=".MainActivity" android:label="$lbl" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LEANBACK_LAUNCHER" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
"@
    Write-Utf8NoBom (Join-Path $tempDir "AndroidManifest.xml") $manifest

    $stringsXml = @"
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">$lbl</string>
</resources>
"@
    Write-Utf8NoBom (Join-Path $resDir "strings.xml") $stringsXml

    $javaSrc = @"
package $pkg;
import android.app.Activity;
import android.os.Bundle;

public class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
    }
}
"@
    $pkgPath = Join-Path $tempDir ("src\" + $pkg.Replace(".", "\"))
    New-Item -ItemType Directory -Force -Path $pkgPath | Out-Null
    Write-Utf8NoBom (Join-Path $pkgPath "MainActivity.java") $javaSrc

    # 1. AAPT2 compile
    & $aapt2 compile --dir (Join-Path $tempDir "res") -o (Join-Path $tempDir "compiled_res.zip") | Out-Null

    # 2. AAPT2 link
    & $aapt2 link -I $platformJar `
        --manifest (Join-Path $tempDir "AndroidManifest.xml") `
        -o (Join-Path $tempDir "base.apk") `
        --java $genDir `
        (Join-Path $tempDir "compiled_res.zip") `
        --auto-add-overlay `
        --min-sdk-version 21 `
        --target-sdk-version 28 | Out-Null

    # 3. Javac
    $sources = @(
        (Join-Path $pkgPath "MainActivity.java"),
        (Get-ChildItem -Path $genDir -Filter "*.java" -Recurse | Select-Object -ExpandProperty FullName)
    )
    & $javac -encoding UTF-8 -source 1.8 -target 1.8 -bootclasspath $platformJar -cp $platformJar -d $classesDir $sources

    # 4. D8
    $classFiles = Get-ChildItem -Path $classesDir -Filter "*.class" -Recurse | Select-Object -ExpandProperty FullName
    & $java -jar $d8Jar --min-api 21 --lib $platformJar --output $dexDir $classFiles

    # 5. Inserimento Dalvik Executable (classes.dex) nel package ZIP tramite jar.exe
    & (Join-Path $jdkDir "bin\jar.exe") -uf (Join-Path $tempDir "base.apk") -C $dexDir classes.dex

    # 6. Zipalign
    $alignedApk = Join-Path $tempDir "aligned.apk"
    & $zipalign -f -v 4 (Join-Path $tempDir "base.apk") $alignedApk | Out-Null

    # 7. Firma
    $keystore = Join-Path $toolsDir "debug.keystore"
    if (-not (Test-Path $keystore)) {
        & (Join-Path $jdkDir "bin\keytool.exe") -genkey -v -keystore $keystore -alias androiddebugkey -storepass android -keypass android -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Android Debug,O=Android,C=US"
    }

    $finalApk = Join-Path $outDir "$appName.apk"
    & $java -jar $apksignerJar sign --ks $keystore --ks-pass pass:android --key-pass pass:android --out $finalApk $alignedApk
    Write-Host "  [OK] $appName.apk generato con successo." -ForegroundColor Green

    Remove-Item $tempDir -Recurse -Force
}

Write-Host "`n=================================================================" -ForegroundColor Green
Write-Host " GENERATI CON SUCCESSO TUTTI GLI 8 APK NELLA CARTELLA: $outDir" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Green
