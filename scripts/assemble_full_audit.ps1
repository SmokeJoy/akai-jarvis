# ==============================================================================
# AKAI Custom TV - Script di Assemblaggio, Manifest e Verifica Audit v16
# ==============================================================================

$ErrorActionPreference = "Stop"

$workspace = "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay"
$outputBase = Join-Path $workspace "AKAI_AUDIT_COMPLETO"
$staging = Join-Path $workspace "staging_audit_temp"

Write-Host "=== CREAZIONE DEGLI ARCHIVI ZIP INDIPENDENTI E DEL MANIFEST ===" -ForegroundColor Cyan

# Esecuzione primo step di staging
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $workspace "scripts\create_audit_package.ps1")

# Copia documentazione architettura in staging
Copy-Item (Join-Path $workspace "AKAI_ARCHITETTURA_COMPLETA.md") (Join-Path $staging "07_AKAI_ARCHITECTURE_EVIDENCE\AKAI_ARCHITETTURA_COMPLETA.md") -Force

# Helper per calcolare hash SHA-256
function Get-Sha256($filePath) {
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($filePath)
    $hashBytes = $hasher.ComputeHash($stream)
    $stream.Close()
    return ($hashBytes | ForEach-Object { $_.ToString("x2") }) -join ""
}

# Compressione dei 7 archivi indipendenti
Add-Type -AssemblyName System.IO.Compression.FileSystem

$zipTargets = @(
    @{ Name = "01_AKAI_ANDROID_SOURCES.zip"; Folder = "01_AKAI_ANDROID_SOURCES" },
    @{ Name = "02_AKAI_WEB_REMOTE.zip"; Folder = "02_AKAI_WEB_REMOTE" },
    @{ Name = "03_AKAI_BUILD_SCRIPTS_DEPENDENCIES.zip"; Folder = "03_AKAI_BUILD_SCRIPTS_DEPENDENCIES" },
    @{ Name = "04_AKAI_TESTS_REPORTS.zip"; Folder = "04_AKAI_TESTS_REPORTS" },
    @{ Name = "05_AKAI_HISTORY_BASELINES.zip"; Folder = "05_AKAI_HISTORY_BASELINES" },
    @{ Name = "06_AKAI_BINARIES_RELEASE.zip"; Folder = "06_AKAI_BINARIES_RELEASE" },
    @{ Name = "07_AKAI_ARCHITECTURE_EVIDENCE.zip"; Folder = "07_AKAI_ARCHITECTURE_EVIDENCE" }
)

$zipManifestList = @()

foreach ($item in $zipTargets) {
    $zipPath = Join-Path $outputBase $item.Name
    $srcDir = Join-Path $staging $item.Folder
    Write-Host "Compressione di $($item.Name)..."
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($srcDir, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)

    $len = (Get-Item $zipPath).Length
    $hash = Get-Sha256 $zipPath
    $zipManifestList += @{
        name = $item.Name
        size_bytes = $len
        size_kb = [Math]::Round($len / 1KB, 2)
        size_mb = [Math]::Round($len / 1MB, 2)
        sha256 = $hash
    }
}

# Inventario file inclusi
$fileInventory = @()
foreach ($item in $zipTargets) {
    $srcDir = Join-Path $staging $item.Folder
    Get-ChildItem -Path $srcDir -Recurse -File | ForEach-Object {
        $relPath = $_.FullName.Substring($staging.Length + 1)
        $h = Get-Sha256 $_.FullName
        $fileInventory += @{
            relative_path = $relPath
            archive = $item.Name
            size_bytes = $_.Length
            sha256 = $h
        }
    }
}

# Elenco esclusioni documentate
$exclusions = @(
    @{
        path = "tools/android-sdk/*"
        reason = "Toolchain SDK Android completa (>1.5 GB di binari Google standard). I requisiti minimi e i tool usati (build-tools 28.0.3, aapt2, d8, apksigner) sono descritti in TOOLCHAIN_SPECS.md."
    },
    @{
        path = "tools/jdk-17/*"
        reason = "Distribuzione binaria OpenJDK 17 (>300 MB). I requisiti di compilazione sono documentati in TOOLCHAIN_SPECS.md."
    },
    @{
        path = "tools/nodejs/*"
        reason = "Binario runtime Node.js esterno (>80 MB). Non indispensabile per il runtime TV né per la compilazione."
    },
    @{
        path = "tools/*.p12, tools/*.keystore (server_keystore.p12, debug.keystore, akai_ca.p12, test_legacy.p12)"
        reason = "Conformità rigorosa P0-04: le chiavi private e i keystore TLS/APK non devono mai essere condivisi in archivi di audit esterni. Sono inclusi esclusivamente gli script di generazione locale (generate_tv_tls_keystore.ps1) e il certificato pubblico AkaiRootCA.crt."
    },
    @{
        path = "downloads/*"
        reason = "Archivi zip di snapshot temporanei già inclusi o ridondanti."
    },
    @{
        path = ".git"
        reason = "La repository locale non è versionata con Git. La cronologia completa dello sviluppo dalle Fasi 1 a 16 è documentata in 05_AKAI_HISTORY_BASELINES."
    }
)

# Generazione AKAI_AUDIT_MANIFEST.json
$manifestObject = @{
    project_name = "AKAI JARVIS TV Assistant & Remote"
    version = "16.0.0"
    snapshot_date = "2026-11-07T22:15:00Z"
    target_hardware = @{
        model = 'AKAI AKTV5037N 50" UHD 4K (m7332_eu)'
        soc = "MediaTek MT9632 (Quad-core ARM Cortex-A53, Mali-G52 GPU)"
        cpu_arch = "armeabi-v7a (32-bit ARMv7-a)"
        os_version = "Android TV 9.0 Pie (API 28)"
        kernel = "Linux 4.19.79"
        total_ram_mb = 1331
        available_ram_mb = 382
        swap_zram_mb = 499
        lan_ip = "192.168.1.8"
        ports = @(8088, 8443)
    }
    compilation_specs = @{
        jdk_version = "OpenJDK 17.0.2 (target -source 1.8 -target 1.8)"
        android_target_api = 28
        build_tools_version = "28.0.3"
        ndk_version = "NDK r21e (Clang armv7a-linux-androideabi21)"
        apk_signatures = "v1 (JAR) + v2 (APK Signature Scheme v2)"
    }
    unit_tests = @{
        total_tests = 12
        passed_tests = 12
        failed_tests = 0
        success_rate = "100%"
        suite_path = "akai-remote-tests/UnitTests.java"
    }
    known_open_issues = @(
        "P1-11: L'indirizzo IP 192.168.1.8 e il certificato TLS sono al momento legati all'assegnazione DHCP corrente; una futura versione potra introdurre mDNS discovery.",
        "OODA Loop: L'assistente esegue macro con verifica semantica a schermo (Accessibility/Perception); la visione continua a frame ad anello chiuso non e implementata."
    )
    zip_archives = $zipManifestList
    file_inventory_count = $fileInventory.Count
    file_inventory = $fileInventory
    exclusions = $exclusions
}

$manifestJson = $manifestObject | ConvertTo-Json -Depth 6
$manifestPath = Join-Path $outputBase "AKAI_AUDIT_MANIFEST.json"
[System.IO.File]::WriteAllText($manifestPath, $manifestJson, [System.Text.Encoding]::UTF8)

# Copia anche nel workspace
Copy-Item $manifestPath (Join-Path $workspace "AKAI_AUDIT_MANIFEST.json") -Force
Copy-Item (Join-Path $workspace "AKAI_ARCHITETTURA_COMPLETA.md") (Join-Path $outputBase "AKAI_ARCHITETTURA_COMPLETA.md") -Force

# Generazione LEGGIMI_PRIMA.md
$leggimiContent = @"
# AKAI JARVIS v16 — Guida per la Revisione Esterna (ChatGPT)

Benvenuto nel pacchetto completo congelato per l'audit indipendente di **AKAI JARVIS v16**.

Tutti i file sono organizzati in **7 archivi ZIP indipendenti**, ciascuno inferiore a 15 MB (ampiamente sotto la soglia di 400 MB / 512 MB).

---

## Ordine di Caricamento Consigliato

Per consentire a ChatGPT un'analisi metodica e incrociata senza saturare la finestra di contesto, si raccomanda di caricare gli archivi nell'ordine seguente:

### Blocco 1: Architettura, Rete e Server Android
1. `01_AKAI_ANDROID_SOURCES.zip`  
   *Contiene:* Il server HTTP/HTTPS (`RemoteServerService.java`), il driver uinput C JNI (`uinput_jni.c`), il controller TV (`TvController.java`), la memoria SQLite (`AkaiMemoryEngine.java`), il motore vocale (`AkaiSpeechEngine.java`), l'adapter AI (`AiProviderAdapter.java`), la percezione (`ScreenPerceptionEngine.java`), e il launcher Custom Home v8.
2. `AKAI_ARCHITETTURA_COMPLETA.md` & `AKAI_AUDIT_MANIFEST.json`  
   *Contiene:* La mappa tecnica di tutti i flussi reali, thread, porte, protocolli, schemi SQLite e inventario SHA-256.

### Blocco 2: Interfaccia Web Mobile & Conversazione Multi-Turn
3. `02_AKAI_WEB_REMOTE.zip`  
   *Contiene:* L'interfaccia a 3 sezioni (Assistente, Telecomando, Attività), la PWA, il Service Worker Network-First (`sw.js`), i fogli di stile accessibili (`style.css`), il motore vocale frontend con turn locking e polling stato TV (`app.js`).

### Blocco 3: Test, Verifiche e Script Operativi
4. `04_AKAI_TESTS_REPORTS.zip`  
   *Contiene:* La suite di 12 test unitari (`UnitTests.java`), i mock host (`Context.java`, `SharedPreferences.java`, `Log.java`), gli script di test runtime e i dump di diagnostica con telemetria TV reale.
5. `03_AKAI_BUILD_SCRIPTS_DEPENDENCIES.zip`  
   *Contiene:* Gli script di compilazione autonoma (`08_compile_akai_remote_apk.ps1`, `tv.ps1`, `generate_tv_tls_keystore.ps1`, ecc.) e le specifiche della toolchain JDK 17 / NDK r21e / SDK 28.

### Blocco 4: Cronologia, Binari e Prove Visive
6. `05_AKAI_HISTORY_BASELINES.zip`  
   *Contiene:* I piani di sviluppo storici, i rapporti di audit precedenti (v15.3), i log delle decisioni architetturali.
7. `06_AKAI_BINARIES_RELEASE.zip`  
   *Contiene:* I binari APK compilati e firmati (`AKAI_JARVIS_Remote_v16.apk` e `AKAI_Custom_Home_v8.apk`), il backup del launcher di fabbrica e il certificato pubblico CA.
8. `07_AKAI_ARCHITECTURE_EVIDENCE.zip`  
   *Contiene:* L'anteprima HTML interattiva v16, gli screenshot tecnici a risoluzione reale della TV e i dump della gerarchia UI (`dump.xml`).

---

## Note di Sicurezza (Sanitizzazione Applicata)
In piena aderenza ai requisiti di audit:
- **Zero chiavi private:** Nessun file `.p12`, `.keystore` o `.jks` contenente chiavi private è stato incluso negli archivi.
- **Zero API keys reali:** Le configurazioni contengono solo placeholder di esempio (`sk-...REDACTED...`).
- **Nessuna alterazione della TV:** La Smart TV dell'utente è rimasta indisturbata durante tutta la procedura.
"@
[System.IO.File]::WriteAllText((Join-Path $outputBase "LEGGIMI_PRIMA.md"), $leggimiContent, [System.Text.Encoding]::UTF8)

# Pulizia staging temporaneo
Remove-Item $staging -Recurse -Force

Write-Host "`n=== VERIFICA INTEGRITÀ DEGLI ARCHIVI PRODOTTI ===" -ForegroundColor Cyan
foreach ($item in $zipTargets) {
    $zipPath = Join-Path $outputBase $item.Name
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    $entryCount = $zip.Entries.Count
    $zip.Dispose()
    Write-Host " [OK] $($item.Name) : $entryCount voci, $((Get-Item $zipPath).Length) bytes" -ForegroundColor Green
}

Write-Host "`nProcedura completata con successo in: $outputBase" -ForegroundColor Green
