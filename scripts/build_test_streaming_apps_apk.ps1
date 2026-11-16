# ==============================================================================
# Compilazione Suite APK Distinti per Popolare Catalogo Emulatore Android TV
# Genera 8 pacchetti indipendenti conformi Leanback con Icone e Banner TV reali
# ==============================================================================

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

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

function Add-RoundedRectPath($gPath, [float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $d = $r * 2
    $gPath.AddArc($x, $y, $d, $d, 180, 90)
    $gPath.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $gPath.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $gPath.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $gPath.CloseFigure()
}

function Draw-BrandEmblem($g, [string]$kind, [float]$cx, [float]$cy, [float]$size, $accentColor) {
    $whiteBrush = [System.Drawing.Brushes]::White
    $whitePen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, [Math]::Max(3.0, $size * 0.085))
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $sf.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap

    if ($kind -eq "youtube") {
        $r = $size * 0.28
        $pts = @(
            (New-Object System.Drawing.PointF(($cx - $r * 0.65), ($cy - $r * 0.95))),
            (New-Object System.Drawing.PointF(($cx + $r * 1.05), $cy)),
            (New-Object System.Drawing.PointF(($cx - $r * 0.65), ($cy + $r * 0.95)))
        )
        $g.FillPolygon($whiteBrush, $pts)
    } elseif ($kind -eq "kodi") {
        $r = $size * 0.34
        $diamond = @(
            (New-Object System.Drawing.PointF($cx, ($cy - $r))),
            (New-Object System.Drawing.PointF(($cx + $r), $cy)),
            (New-Object System.Drawing.PointF($cx, ($cy + $r))),
            (New-Object System.Drawing.PointF(($cx - $r), $cy))
        )
        $g.DrawPolygon($whitePen, $diamond)
        $triR = $r * 0.42
        $tri = @(
            (New-Object System.Drawing.PointF(($cx - $triR * 0.55), ($cy - $triR * 0.8))),
            (New-Object System.Drawing.PointF(($cx + $triR * 0.85), $cy)),
            (New-Object System.Drawing.PointF(($cx - $triR * 0.55), ($cy + $triR * 0.8)))
        )
        $g.FillPolygon($whiteBrush, $tri)
    } elseif ($kind -eq "infinity") {
        $rx = $size * 0.16
        $ry = $size * 0.15
        $g.DrawEllipse($whitePen, ($cx - $rx * 1.9), ($cy - $ry), ($rx * 1.85), ($ry * 2))
        $g.DrawEllipse($whitePen, ($cx + $rx * 0.05), ($cy - $ry), ($rx * 1.85), ($ry * 2))
    } elseif ($kind -eq "vlc") {
        $h = $size * 0.34
        $wTop = $size * 0.10
        $wBot = $size * 0.28
        $cone = @(
            (New-Object System.Drawing.PointF(($cx - $wTop), ($cy - $h))),
            (New-Object System.Drawing.PointF(($cx + $wTop), ($cy - $h))),
            (New-Object System.Drawing.PointF(($cx + $wBot), ($cy + $h))),
            (New-Object System.Drawing.PointF(($cx - $wBot), ($cy + $h)))
        )
        $g.FillPolygon($whiteBrush, $cone)
        $stripeBrush = New-Object System.Drawing.SolidBrush($accentColor)
        $stripe = @(
            (New-Object System.Drawing.PointF(($cx - $size * 0.16), ($cy - $size * 0.08))),
            (New-Object System.Drawing.PointF(($cx + $size * 0.16), ($cy - $size * 0.08))),
            (New-Object System.Drawing.PointF(($cx + $size * 0.21), ($cy + $size * 0.10))),
            (New-Object System.Drawing.PointF(($cx - $size * 0.21), ($cy + $size * 0.10)))
        )
        $g.FillPolygon($stripeBrush, $stripe)
    } elseif ($kind -eq "raiplay") {
        $fSize = [Math]::Max(13, [int]($size * 0.30))
        $fnt = New-Object System.Drawing.Font("Segoe UI", $fSize, [System.Drawing.FontStyle]::Bold)
        $g.DrawString("Rai", $fnt, $whiteBrush, (New-Object System.Drawing.RectangleF(($cx - $size * 0.5), ($cy - $size * 0.5), $size, $size)), $sf)
    } elseif ($kind -eq "disney") {
        $fSize = [Math]::Max(14, [int]($size * 0.32))
        $fnt = New-Object System.Drawing.Font("Segoe UI", $fSize, [System.Drawing.FontStyle]::Bold)
        $g.DrawString("D+", $fnt, $whiteBrush, (New-Object System.Drawing.RectangleF(($cx - $size * 0.5), ($cy - $size * 0.5), $size, $size)), $sf)
    } elseif ($kind -eq "prime") {
        $fSize = [Math]::Max(15, [int]($size * 0.34))
        $fnt = New-Object System.Drawing.Font("Segoe UI", $fSize, [System.Drawing.FontStyle]::Bold)
        $g.DrawString("P", $fnt, $whiteBrush, (New-Object System.Drawing.RectangleF(($cx - $size * 0.5), ($cy - $size * 0.56), $size, ($size * 0.9))), $sf)
        $arcPen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, [Math]::Max(2.5, $size * 0.07))
        $g.DrawArc($arcPen, ($cx - $size * 0.26), ($cy + $size * 0.02), ($size * 0.52), ($size * 0.24), 15, 150)
    } else {
        $fSize = [Math]::Max(16, [int]($size * 0.38))
        $fnt = New-Object System.Drawing.Font("Segoe UI", $fSize, [System.Drawing.FontStyle]::Bold)
        $g.DrawString("N", $fnt, $whiteBrush, (New-Object System.Drawing.RectangleF(($cx - $size * 0.5), ($cy - $size * 0.5), $size, $size)), $sf)
    }
}

function New-BrandArtwork($appCfg, [string]$iconOutPath, [string]$bannerOutPath) {
    $c1 = [System.Drawing.ColorTranslator]::FromHtml($appCfg.C1)
    $c2 = [System.Drawing.ColorTranslator]::FromHtml($appCfg.C2)
    $accent = [System.Drawing.ColorTranslator]::FromHtml($appCfg.Accent)

    # 1. Banner Leanback TV (320 x 180 px)
    $bmpB = New-Object System.Drawing.Bitmap(320, 180)
    $gB = [System.Drawing.Graphics]::FromImage($bmpB)
    $gB.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $gB.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

    $rectB = New-Object System.Drawing.Rectangle(0, 0, 320, 180)
    $brushBg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rectB, $c1, $c2, 35.0)
    $gB.FillRectangle($brushBg, $rectB)

    $glowBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(45, $accent.R, $accent.G, $accent.B))
    $gB.FillEllipse($glowBrush, 180, -40, 200, 200)
    $gB.FillEllipse($glowBrush, -50, 90, 160, 160)

    # Rounded emblem box (left, 72x72)
    $badgePath = New-Object System.Drawing.Drawing2D.GraphicsPath
    Add-RoundedRectPath $badgePath 24 54 72 72 16
    $badgeBrush = New-Object System.Drawing.SolidBrush($accent)
    $gB.FillPath($badgeBrush, $badgePath)

    Draw-BrandEmblem $gB $appCfg.Kind 60 90 72 $accent

    # App Brand Title & Tagline (NoWrap, balanced width so nothing ever clips)
    $fontTitle = New-Object System.Drawing.Font("Segoe UI", 17.5, [System.Drawing.FontStyle]::Bold)
    $fontSub = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Regular)
    $sfLeft = New-Object System.Drawing.StringFormat
    $sfLeft.Alignment = [System.Drawing.StringAlignment]::Near
    $sfLeft.LineAlignment = [System.Drawing.StringAlignment]::Center
    $sfLeft.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap

    $whiteBrush = [System.Drawing.Brushes]::White
    $gB.DrawString($appCfg.ShortName, $fontTitle, $whiteBrush, (New-Object System.Drawing.RectangleF(110, 52, 198, 44)), $sfLeft)
    $subBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(205, 226, 232, 240))
    $gB.DrawString($appCfg.Tagline, $fontSub, $subBrush, (New-Object System.Drawing.RectangleF(112, 96, 196, 26)), $sfLeft)

    # Accent bottom ribbon
    $gB.FillRectangle($badgeBrush, 0, 173, 320, 7)

    $bmpB.Save($bannerOutPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $gB.Dispose()
    $bmpB.Dispose()

    # 2. App Icon (192 x 192 px)
    $bmpI = New-Object System.Drawing.Bitmap(192, 192)
    $gI = [System.Drawing.Graphics]::FromImage($bmpI)
    $gI.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $gI.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

    $rectI = New-Object System.Drawing.Rectangle(0, 0, 192, 192)
    $brushIcon = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rectI, $c1, $c2, 45.0)
    $gI.FillRectangle($brushIcon, $rectI)

    $badgeIconBrush = New-Object System.Drawing.SolidBrush($accent)
    $gI.FillEllipse($badgeIconBrush, 24, 24, 144, 144)
    Draw-BrandEmblem $gI $appCfg.Kind 96 96 144 $accent

    $bmpI.Save($iconOutPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $gI.Dispose()
    $bmpI.Dispose()
}

$appList = @(
    @{ Pkg = "test.tv.youtube"; Kind = "youtube"; Label = "YouTube TV"; ShortName = "YouTube"; Tagline = "Video & Live TV"; C1 = "#18181B"; C2 = "#311216"; Accent = "#FF0000" },
    @{ Pkg = "test.tv.netflix"; Kind = "netflix"; Label = "Netflix"; ShortName = "NETFLIX"; Tagline = "Film & Serie TV"; C1 = "#0A0406"; C2 = "#45060C"; Accent = "#E50914" },
    @{ Pkg = "test.tv.prime"; Kind = "prime"; Label = "Prime Video"; ShortName = "Prime Video"; Tagline = "Streaming Hub"; C1 = "#05192D"; C2 = "#0F4073"; Accent = "#00A8E1" },
    @{ Pkg = "test.tv.raiplay"; Kind = "raiplay"; Label = "RaiPlay"; ShortName = "RaiPlay"; Tagline = "Dirette & Replay"; C1 = "#00318C"; C2 = "#0066FF"; Accent = "#0284C7" },
    @{ Pkg = "test.tv.disney"; Kind = "disney"; Label = "Disney+"; ShortName = "Disney+"; Tagline = "Cinema & Family"; C1 = "#060D2A"; C2 = "#16357D"; Accent = "#38BDF8" },
    @{ Pkg = "test.tv.infinity"; Kind = "infinity"; Label = "Mediaset Infinity"; ShortName = "Infinity+"; Tagline = "Mediaset TV"; C1 = "#290852"; C2 = "#0E4D84"; Accent = "#A855F7" },
    @{ Pkg = "test.tv.vlc"; Kind = "vlc"; Label = "VLC Media Player"; ShortName = "VLC"; Tagline = "Media Player 4K"; C1 = "#1E1208"; C2 = "#4E2506"; Accent = "#FF7A00" },
    @{ Pkg = "test.tv.kodi"; Kind = "kodi"; Label = "Kodi Media Center"; ShortName = "KODI"; Tagline = "Home Theater"; C1 = "#07202E"; C2 = "#0E4E6E"; Accent = "#0EA5E9" }
)

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " COMPILAZIONE SUITE 8 APK STREAMING INDIPENDENTI CON BANNER/ICONE " -ForegroundColor Cyan
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
    $resValuesDir = Join-Path $tempDir "res\values"
    $resDrawableDir = Join-Path $tempDir "res\drawable-xhdpi"
    New-Item -ItemType Directory -Force -Path $genDir | Out-Null
    New-Item -ItemType Directory -Force -Path $classesDir | Out-Null
    New-Item -ItemType Directory -Force -Path $dexDir | Out-Null
    New-Item -ItemType Directory -Force -Path $resValuesDir | Out-Null
    New-Item -ItemType Directory -Force -Path $resDrawableDir | Out-Null

    $iconPng = Join-Path $resDrawableDir "app_icon.png"
    $bannerPng = Join-Path $resDrawableDir "app_banner.png"
    New-BrandArtwork $app $iconPng $bannerPng

    $manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="$pkg"
    android:versionCode="1"
    android:versionName="1.0">
    <uses-feature android:name="android.software.leanback" android:required="false" />
    <application android:label="$lbl" android:icon="@drawable/app_icon" android:banner="@drawable/app_banner">
        <activity android:name=".MainActivity" android:label="$lbl" android:icon="@drawable/app_icon" android:banner="@drawable/app_banner" android:exported="true">
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
    Write-Utf8NoBom (Join-Path $resValuesDir "strings.xml") $stringsXml

    $javaSrc = @"
package $pkg;
import android.app.Activity;
import android.os.Bundle;
import android.view.Gravity;
import android.widget.TextView;

public class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        TextView tv = new TextView(this);
        tv.setText("$lbl - Test App");
        tv.setTextSize(28f);
        tv.setGravity(Gravity.CENTER);
        tv.setBackgroundColor(0xFF0A0E17);
        tv.setTextColor(0xFFFFFFFF);
        setContentView(tv);
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

    # 5. Packaging classes.dex via jar.exe
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
    Write-Host "  [OK] $appName.apk generato con grafica vettoriale GDI+." -ForegroundColor Green

    Remove-Item $tempDir -Recurse -Force
}

Write-Host "`n=================================================================" -ForegroundColor Green
Write-Host " GENERATI CON SUCCESSO TUTTI GLI 8 APK NELLA CARTELLA: $outDir" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Green
