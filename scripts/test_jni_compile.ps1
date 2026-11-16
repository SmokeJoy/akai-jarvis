$ErrorActionPreference = "Stop"

$workspace = (Get-Item $PSScriptRoot).Parent.FullName
$clang = Join-Path $workspace "tools\android-sdk\ndk\21.4.7075529\toolchains\llvm\prebuilt\windows-x86_64\bin\armv7a-linux-androideabi21-clang.cmd"
$jniSrc = Join-Path $workspace "akai-remote-tv\app\src\main\jni\uinput_jni.c"
$testDir = Join-Path $workspace "akai-remote-tv\app\build"
$testSo = Join-Path $testDir "test_libakai_uinput.so"

New-Item -ItemType Directory -Force -Path $testDir | Out-Null
if (Test-Path $testSo) { Remove-Item $testSo -Force }

Write-Host "Compilazione JNI uinput_jni.c con NDK Clang ARMv7..."
& cmd.exe /c "`"$clang`" -shared -fPIC -O2 -llog `"$jniSrc`" -o `"$testSo`""

if (Test-Path $testSo) {
    $len = (Get-Item $testSo).Length
    Write-Host "JNI ARMv7 nativo compilato con SUCCESSO! Dimensione: $len bytes" -ForegroundColor Green
    Remove-Item $testSo -Force
} else {
    Write-Host "ERRORE compilazione JNI nativo!" -ForegroundColor Red
    exit 1
}
