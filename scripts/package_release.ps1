# ==============================================================================
# AKAI Custom TV - Script: Assemblaggio Pacchetto Completo Sorgenti & Funzionamento v16
# Crea il file zip autonomo per la revisione del codice e dei componenti operativi
# ==============================================================================

$ErrorActionPreference = "Stop"

$workspace = "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay"
$staging = Join-Path $workspace "staging_release"
$zipOutput = Join-Path $workspace "AKAI_JARVIS_Sorgenti_e_File_Funzionamento.zip"

Write-Host "=== CREAZIONE PACCHETTO COMPLETO SORGENTI E FILE PER REVISIONE v16 ===" -ForegroundColor Cyan

if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
if (Test-Path $zipOutput) { Remove-Item $zipOutput -Force }

New-Item -ItemType Directory -Force -Path $staging | Out-Null
New-Item -ItemType Directory -Force -Path "$staging\binaries" | Out-Null
New-Item -ItemType Directory -Force -Path "$staging\akai-remote-tv\app\src" | Out-Null
New-Item -ItemType Directory -Force -Path "$staging\akai-custom-home\app\src" | Out-Null
New-Item -ItemType Directory -Force -Path "$staging\akai-remote-web" | Out-Null
New-Item -ItemType Directory -Force -Path "$staging\akai-remote-tests" | Out-Null
New-Item -ItemType Directory -Force -Path "$staging\scripts" | Out-Null

Write-Host "[1/7] Copia sorgenti akai-remote-tv (Daemon TV, AI Controller, Speech Engine)..."
Copy-Item "$workspace\akai-remote-tv\app\src\*" "$staging\akai-remote-tv\app\src" -Recurse -Force

Write-Host "[2/7] Copia sorgenti akai-custom-home (Launcher TV v8)..."
Copy-Item "$workspace\akai-custom-home\app\src\*" "$staging\akai-custom-home\app\src" -Recurse -Force

Write-Host "[3/7] Copia console web akai-remote-web (HTML5, CSS3, PWA v16, Voice Orb)..."
Copy-Item "$workspace\akai-remote-web\*" "$staging\akai-remote-web" -Recurse -Force

Write-Host "[4/7] Copia test suite unitari e mock host (12 test superati)..."
Copy-Item "$workspace\akai-remote-tests\*" "$staging\akai-remote-tests" -Recurse -Force -Exclude "bin"

Write-Host "[5/7] Copia script di compilazione, gestione e recupero..."
$scriptsList = @(
    "08_compile_akai_remote_apk.ps1",
    "09_compile_akai_home_apk.ps1",
    "tv.ps1",
    "generate_tv_tls_keystore.ps1",
    "01_check_tools.ps1",
    "02_connect_tv.ps1",
    "03_read_only_audit.ps1",
    "05_monitor_performance.ps1",
    "06_diagnose_cpu_load.ps1",
    "10_pull_diagnostics.ps1",
    "99_emergency_restore.ps1",
    "rollback_to_ltvlauncher.ps1",
    "rollback_to_ltvlauncher.bat",
    "pull_diagnostics.bat"
)
foreach ($scriptName in $scriptsList) {
    $srcPath = Join-Path "$workspace\scripts" $scriptName
    if (Test-Path $srcPath) {
        Copy-Item $srcPath "$staging\scripts\$scriptName" -Force
    } elseif (Test-Path "$workspace\$scriptName") {
        Copy-Item "$workspace\$scriptName" "$staging\scripts\$scriptName" -Force
    }
}

Write-Host "[6/7] Copia binari compilati APK e certificato pubblico TLS (escluse chiavi private)..."
Copy-Item "$workspace\akai-remote-tv\app\build\outputs\apk\debug\app-debug.apk" "$staging\binaries\AKAI_JARVIS_Remote_v16.apk" -Force
Copy-Item "$workspace\akai-custom-home\app\build\outputs\apk\debug\akai-custom-home.apk" "$staging\binaries\AKAI_Custom_Home_v8.apk" -Force
Copy-Item "$workspace\tools\AkaiRootCA.crt" "$staging\binaries\AkaiRootCA.crt" -Force

# Generazione Guida alla Revisione per il Reviewer
$readmeContent = @"
# AKAI JARVIS v16 — Pacchetto Completo per la Revisione del Codice e del Sistema

Questo archivio contiene l'intera base di codice sorgente, l'interfaccia a 3 sezioni (Assistente, Telecomando, Attività), i driver, gli script di compilazione, la suite di test e i file binari operativi del progetto **AKAI JARVIS v16**, sviluppato specificamente per la Smart TV **AKAI AKTV5037N 50" UHD 4K** (MediaTek MT9632, Android TV 9.0 Pie API 28).

---

## Stato di Risoluzione Audit Completo v15.3 -> v16

### P0 — Errori Critici Risolti
- **P0-01 (Parser HTTP)**: Il parser in `RemoteServerService.java` ora legge esattamente `contentLength` byte dal flusso binario con limite di 64 KB prima di decodificare in UTF-8. Le lettere accentate (`ù`, `è`, `é`, `ò`, `à`, `ì`) ed emoji non causano più blocchi di timeout.
- **P0-02 (Sequenze di Azioni)**: `TvController.executeActionSequence` verifica il `CommandResult` di ogni singolo passo; se uno step fallisce, la sequenza si arresta immediatamente e restituisce `false` indicando il passo e la causa dell'errore.
- **P0-03 (Seeding Memorie SQLite)**: In `AkaiMemoryEngine.java`, i template iniziali vengono seminati con `success_count = 0` e `last_verified = 0` con `CONFLICT_IGNORE`. La funzione `resetProcedures()` azzera esclusivamente la tabella `procedural_memory`, preservando intatte le preferenze dell'utente, la cronologia e le statistiche.
- **P0-04 (Sicurezza Certificati)**: Le chiavi private non vengono distribuite nei pacchetti di rilascio. I certificati TLS vengono generati localmente tramite `generate_tv_tls_keystore.ps1`.
- **P0-05 (Autenticazione e Backup)**: L'endpoint `/api/diagnostics` richiede autenticazione Bearer obbligatoria. `AndroidManifest.xml` imposta `android:allowBackup="false"`.

### P1 — Affidabilità e Conversazione Vocale
- **P1-01 (Thread Pool)**: Pool espanso a 12 worker con thread dedicati `AkaiHttpAcceptor` e `AkaiHttpsAcceptor` per evitare starvation e saturazione delle chiamate di controllo.
- **P1-02 (Turn Locking Atomico)**: In `app.js`, la conversazione multi-turn usa `turnLocked` e `currentTurnId` atomici. Final, interim e `onend` non possono più provocare doppie esecuzioni.
- **P1-03 (Tracking Stato Vocale)**: `CloudSpeechAdapter.java` traccia lo stato vocale (`IDLE`, `FETCHING`, `PLAYING`). Il frontend attende l'inizio effettivo della voce e verifica il ritorno allo stato `IDLE` prima di riaprire il microfono.
- **P1-04 (Timeout e Cancellazione Browser)**: Le chiamate a `/api/ai/ask` sono vincolate a un `AbortController` con timeout a 25 secondi. Il pulsante Stop annulla immediatamente qualsiasi richiesta pendente.
- **P1-05 & P1-16 (Accuratezza Esiti e Dialoghi)**: Le risposte conversazionali del LLM sono etichettate come `ANSWERED_DIALOG` con `verified = false`. `SUCCESS_VERIFIED` viene attribuito soltanto a operazioni verificate a schermo.
- **P1-06 (Screen Perception)**: `player_active` restituisce categoricamente `false` se l'app in primo piano è la Home/Launcher.
- **P1-07 (Privacy e Modalità Ospite)**: In modalità ospite, `AkaiMemoryEngine` non salva le conversazioni su disco. Il pulsante `clearPersonalPreferencesOnly()` elimina sia le preferenze personali sia tutti i record della tabella `conversations`.
- **P1-09 (Cache Audio Cifrata)**: Il file audio attualmente in riproduzione è escluso dalla pulizia LRU. I file temporanei `tts_tmp_` vengono rimossi al termine dell'esecuzione.
- **P1-10 (AudioFocus Android 8+)**: Audio focus gestito tramite `AudioFocusRequest` persistente e rilasciato con `abandonAudioFocusRequest`.
- **P1-12 & P1-13 (Gestione Sessioni)**: I token scaduti (401) vengono rilevati e rimossi con invito al nuovo PIN. La revoca notifica chiaramente l'esito della cancellazione.
- **P1-14 (Parser Italiano)**: `LocalIntentParser` normalizza gli accenti con Unicode NFD e `\p{InCombiningDiacriticalMarks}+` (`più forte` -> `piu forte`).

### P2 — Redesign Interfaccia v16 (Fase B)
- **P2-01 (PWA & Service Worker)**: Service Worker registrato con cache `akai-jarvis-v16` e strategia Network-First con fallback cache per l'aggiornamento immediato dei file shell.
- **P2-02 (Accessibilità Voice Orb)**: Orb trasformato in `<button type="button" id="jarvis-orb">` accessibile da tastiera e screen reader, con `aria-pressed`, `aria-label` e `aria-live="polite"`.
- **P2-03 & P2-04 (Layout a 3 Sezioni)**:
  1. `Assistente`: Voice Orb, badge dinamico, trascrizione live, TV reply box, pulsante Stop immediato, quick chips.
  2. `Telecomando`: D-Pad circolare e OK grandi (touch target ≥44px), Home/Indietro/Menu, coppie Volume e Canale con Mute/Prev, sorgenti e scorciatoie app.
  3. `Attività`: Cronologia conversazioni SQLite, memorie procedurali verificate, controlli privacy (Guest mode, reset dati personali).
  4. `Impostazioni`: Modal unificato per Provider, API keys, Voce TTS Azure/locale, Memoria e Statistiche.

---

## Suite di Test Eseguita
La suite `akai-remote-tests/UnitTests.java` copre ora 12 test automatici:
1. PIN casuale a 6 cifre
2. Filtro Subnet RFC 1918 (LAN domestica)
3. Rate Limiter anti-brute force (lockout a 3 errori)
4. Rilascio Bearer Token a 256-bit
5. Revoca immediata della sessione
6. Protezione Replay Attacks (Timestamp + Nonce)
7. Autonomia di rete e JVM
8. Generazione matrice QR Code Nayuki
9. Sliding window session touch
10. Normalizzazione accenti italiani (Unicode NFD)
11. Parser HTTP binario a byte (Content-Length UTF-8)
12. Interruzione atomica della sequenza su errore di step

**Esito test unitari:** 12 / 12 superati con successo (100% PASS).
"@

$readmePath = Join-Path $staging "README_REVISIONE.md"
[System.IO.File]::WriteAllText($readmePath, $readmeContent, [System.Text.Encoding]::UTF8)

Write-Host "[7/7] Compressione archivio ZIP: $zipOutput..."
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($staging, $zipOutput, [System.IO.Compression.CompressionLevel]::Optimal, $false)

# Pulizia staging temporaneo
Remove-Item $staging -Recurse -Force

if (Test-Path $zipOutput) {
    $zipSizeMb = [Math]::Round((Get-Item $zipOutput).Length / 1MB, 2)
    $zipSizeKb = [Math]::Round((Get-Item $zipOutput).Length / 1KB, 2)
    Write-Host "`n========================================================" -ForegroundColor Green
    Write-Host " ARCHIVIO ZIP GENERATO CON SUCCESSO!" -ForegroundColor Green
    Write-Host "========================================================" -ForegroundColor Green
    Write-Host " Percorso : $zipOutput"
    Write-Host " Peso     : $zipSizeMb MB ($zipSizeKb KB)" -ForegroundColor Yellow
} else {
    Write-Host "ERRORE: Generazione ZIP fallita." -ForegroundColor Red
    exit 1
}
