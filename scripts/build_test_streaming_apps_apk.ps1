# ==============================================================================
# Compilazione Stub App di Test per Popolare Catalogo Emulatore Android TV
# Pacchetto di test locale: test.tv.streaming (YouTube, Netflix, Prime, RaiPlay, VLC, Kodi, Disney+)
# ==============================================================================

$ErrorActionPreference = "Stop"

$workspace = "C:\Users\danie\OneDrive\Documenti\Antygravity\Akay"
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

$srcDir = Join-Path $toolsDir "test-apps\src"
$buildDir = Join-Path $toolsDir "test-apps\build"

if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $buildDir "gen") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $buildDir "classes") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $buildDir "dex") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $srcDir "res\values") | Out-Null

function Write-Utf8NoBom($path, $text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# 1. Manifest con 6 Activity Leanback Launcher
$manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="test.tv.streaming"
    android:versionCode="1"
    android:versionName="1.0">
    <uses-feature android:name="android.software.leanback" android:required="false" />
    <application android:label="Streaming Apps Suite" android:icon="@android:drawable/sym_def_app_icon">
        <activity android:name=".YouTubeActivity" android:label="YouTube" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LEANBACK_LAUNCHER" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
        <activity android:name=".NetflixActivity" android:label="Netflix" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LEANBACK_LAUNCHER" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
        <activity android:name=".PrimeVideoActivity" android:label="Prime Video" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LEANBACK_LAUNCHER" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
        <activity android:name=".RaiPlayActivity" android:label="RaiPlay" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LEANBACK_LAUNCHER" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
        <activity android:name=".DisneyActivity" android:label="Disney+" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LEANBACK_LAUNCHER" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
        <activity android:name=".VlcActivity" android:label="VLC Media Player" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LEANBACK_LAUNCHER" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
        <activity android:name=".KodiActivity" android:label="Kodi Media Center" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LEANBACK_LAUNCHER" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
"@
Write-Utf8NoBom (Join-Path $srcDir "AndroidManifest.xml") $manifest

# Strings
$stringsXml = @"
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">Streaming Suite</string>
</resources>
"@
Write-Utf8NoBom (Join-Path $srcDir "res\values\strings.xml") $stringsXml

# Java Classes
Write-Utf8NoBom (Join-Path $srcDir "YouTubeActivity.java") "package test.tv.streaming; import android.app.Activity; public class YouTubeActivity extends Activity {}"
Write-Utf8NoBom (Join-Path $srcDir "NetflixActivity.java") "package test.tv.streaming; import android.app.Activity; public class NetflixActivity extends Activity {}"
Write-Utf8NoBom (Join-Path $srcDir "PrimeVideoActivity.java") "package test.tv.streaming; import android.app.Activity; public class PrimeVideoActivity extends Activity {}"
Write-Utf8NoBom (Join-Path $srcDir "RaiPlayActivity.java") "package test.tv.streaming; import android.app.Activity; public class RaiPlayActivity extends Activity {}"
Write-Utf8NoBom (Join-Path $srcDir "DisneyActivity.java") "package test.tv.streaming; import android.app.Activity; public class DisneyActivity extends Activity {}"
Write-Utf8NoBom (Join-Path $srcDir "VlcActivity.java") "package test.tv.streaming; import android.app.Activity; public class VlcActivity extends Activity {}"
Write-Utf8NoBom (Join-Path $srcDir "KodiActivity.java") "package test.tv.streaming; import android.app.Activity; public class KodiActivity extends Activity {}"

# 1. AAPT2 compile
& $aapt2 compile --dir (Join-Path $srcDir "res") -o (Join-Path $buildDir "compiled.zip")

# 2. AAPT2 link
& $aapt2 link -I $platformJar `
  --manifest (Join-Path $srcDir "AndroidManifest.xml") `
  -o (Join-Path $buildDir "base.apk") `
  --java (Join-Path $buildDir "gen") `
  (Join-Path $buildDir "compiled.zip") `
  --auto-add-overlay `
  --min-sdk-version 21 --target-sdk-version 28

# 3. Javac
$javaFiles = Get-ChildItem (Join-Path $srcDir "*.java"), (Join-Path $buildDir "gen\*.java") -Recurse | Select-Object -ExpandProperty FullName
& $javac -encoding UTF-8 -source 1.8 -target 1.8 -bootclasspath $platformJar -cp $platformJar -d (Join-Path $buildDir "classes") $javaFiles

# 4. D8
$classFiles = Get-ChildItem (Join-Path $buildDir "classes") -Filter "*.class" -Recurse | Select-Object -ExpandProperty FullName
& $java -cp $d8Jar com.android.tools.r8.D8 --min-api 21 --lib $platformJar --output (Join-Path $buildDir "dex") $classFiles

# 5. Zip classes.dex into base.apk
$oldPwd = Get-Location
Set-Location (Join-Path $buildDir "dex")
& "$jdkDir\bin\jar.exe" -uf (Join-Path $buildDir "base.apk") "classes.dex"
Set-Location $oldPwd

# 6. ZipAlign
$alignedApk = Join-Path $buildDir "aligned.apk"
& $zipalign -f -v 4 (Join-Path $buildDir "base.apk") $alignedApk | Out-Null

# 7. Sign
$outApk = Join-Path $toolsDir "test-apps\TestStreamingApps.apk"
$debugKeystore = Join-Path $toolsDir "debug.keystore"
& $java -jar $apksignerJar sign --ks $debugKeystore --ks-pass pass:android --ks-key-alias androiddebugkey --out $outApk $alignedApk

Write-Host "TestStreamingApps.apk compilato con successo: $outApk" -ForegroundColor Green
