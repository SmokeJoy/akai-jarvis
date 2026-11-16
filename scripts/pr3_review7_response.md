### Riscontro Tecnico alla Settima Revisione su PR #3 (AKAI Custom Home v8 Leanback)

**Commit di riferimento:** `ff1c42a` su branch `feature/launcher-ui-v8-leanback`  
**GitHub Actions CI Status:**
- Push Run `#42477667563`: **SUCCESS** (113 test Java, 7 test isolamento ADB fail-closed in `pwsh`, build AAPT2/D8, strict Android 9 API 28)
- Pull Request Run `#42477672131`: **SUCCESS** (113 test Java, 7 test isolamento ADB, build e verifica firma)
- **113/113 Test Unitari Java PASS (100%)**
- **7/7 Test Unitari Isolamento ADB PASS in CI (100%)**
- **Hardware Freeze TV:** Rigorosamente attivo e inviolato (zero comandi, zero socket, zero ping verso `192.168.1.8`)

---

### 1. Risoluzione P1 — Suite di Isolamento ADB Integrata Direttamente in CI (7/7 PASS)

In risposta ai rilievi puntuali sulla robustezza dei test mock di isolamento:
1. **Normalizzazione e Delimitatori Deterministici:**
   - In `scripts/11_test_emulator_smoke_script_isolation.ps1`, tutti i separatori di mock sono definiti esplicitamente tramite backtick-t (`` `t ``) e newlines (`` `n ``).
   - In `scripts/10_android_tv_emulator_smoke_test.ps1`, la funzione `Get-ValidatedEmulatorSerial` normalizza sia tab reali (ASCII 9), sia sequenze letterali `\t`, dividendo i campi con `-split "\s+"` e validando rigorosamente lo stato del dispositivo.
   - I percorsi sono stati resi cross-platform e dinamici (`$PSScriptRoot` / `$MyInvocation.MyCommand.Path`).
2. **Ampliamento Scenari di Sicurezza (7 Scenari):**
   - **Scenario 1 (Solo TV fisica `192.168.1.8:5555`):** `SICUREZZA P0 VIOLATA` (Fail-Closed)
   - **Scenario 2 (TV fisica + Emulatore contemporanei):** `SICUREZZA P0 VIOLATA` (Fail-Closed)
   - **Scenario 3 (Nessun dispositivo connesso):** `SICUREZZA P0 FAIL-CLOSED`
   - **Scenario 4 (Multipli emulatori collegati):** `SICUREZZA P0 FAIL-CLOSED` (Ambiguità rifiutata)
   - **Scenario 5 (Singolo emulatore valido con tab):** Individuato e convalidato `emulator-5554`
   - **Scenario 6 (Dispositivo hardware USB estraneo `0123456789ABCDEF`):** `SICUREZZA P0 VIOLATA`
   - **Scenario 7 (Emulatore in stato offline/unauthorized):** `SICUREZZA P0 FAIL-CLOSED`
3. **Esecuzione Automatica Ufficiale in GitHub Actions CI:**
   - La suite è stata inserita direttamente nel workflow `.github/workflows/ci-launcher.yml` come step 5 (`shell: pwsh`).
   - **Estratto Log Ufficiale GitHub Actions (Run `#42477667563`):**
   ```text
   === Running ADB Fail-Closed Isolation Safety Tests (P0 Suite) ===
   TEST ISOLAMENTO DETERMINISTICO ADB FAIL-CLOSED (P0 SAFETY SUITE)
     [PASS] Scenario 1 (Solo TV fisica): Bloccato fail-closed con eccezione P0 attesa
     [PASS] Scenario 2 (TV + Emulatore): Bloccato fail-closed con eccezione P0 attesa
     [PASS] Scenario 3 (Nessun device): Bloccato fail-closed con eccezione P0 attesa
     [PASS] Scenario 4 (Multipli emulatori): Bloccato per ambiguità target
     [PASS] Scenario 5 (Singolo emulatore valido con tab): Individuato correttamente 'emulator-5554'
     [PASS] Scenario 6 (Dispositivo USB estraneo): Bloccato con eccezione P0 attesa
     [PASS] Scenario 7 (Emulatore offline): Bloccato fail-closed per target non operativo
   RISULTATO SUITE ISOLAMENTO ADB: 7 / 7 SUPERATI
   ADB Fail-Closed Isolation Safety Suite passed 100% in CI.
   ```

---

### 2. Risoluzione P1 — Distinzione Livelli di Verifica UI e App di Test

Condivido pienamente la distinzione metodologica:
1. **Asserzioni Automatiche di Stato:**
   - Lo script 10 convalida a livello programmatico: exit code del comando di installazione (`Success`), matching dell'impronta OS (SDK 28 su `ro.build.version.sdk`), focus esclusivo in primo piano accertato via `dumpsys window windows | Select-String "mCurrentFocus"` (`it.akai.customhome.MainActivity`).
2. **Audit Visivo e Semantico:**
   - La verifica del rendering grafico (anello di focus dorato `#FFB300`, scala 1.08x, contrasto testi WCAG AAA, apertura dialoghi di aggiunta ai preferiti e tema) non è affidata a semplici `Test-Path`, ma all'ispezione visiva delle 7 schermate reali a 1080p allegate in `docs/screenshots/emulator/`.
3. **Distinzione Stub vs App Reali:**
   - Le app streaming impiegate nel collaudo AVD (`TestStreamingApps.apk`) sono **stub di test locali** che implementano i Leanback intent filter (`com.google.android.youtube.tv`, `com.netflix.ninja`, `it.rainet.raiplay`, `com.amazon.amazonvideo.livingroom`, `com.disney.disneyplus`, `org.videolan.vlc`, `org.xbmc.kodi`). Consentono di convalidare l'ergonomia delle 4 righe e lo scorrimento orizzontale in sandbox senza profilazione o account utente.

---

### 3. Risoluzione P1 — Analisi Offline di Release, Package e Piano di Rollback

Per fugare qualsiasi ambiguità tra i package e garantire la reversibilità totale:
1. **Mappatura dei Package:**
   - `it.akai.customhome` (PR #3): Nuovo launcher Leanback v8 (`versionCode 8`). **Non è ancora presente sulla TV fisica.**
   - `it.akai.customremote` (PR #1): Servizio JARVIS daemon (`versionCode 16`). Rimane su PR separata e indipendente.
   - `cn.cultraview.launcher.technical.open`: Launcher di fabbrica OEM preinstallato nella ROM di sistema (`/system/app/TvLauncher_Cetus_1_A/TvLauncher_Cetus_1_A.apk`, `versionCode 1006900`).
2. **Paracadute di Fallback Hardware e Rollback Safe:**
   - La partizione `/system` della TV è in sola lettura: il launcher OEM di fabbrica `cn.cultraview.launcher.technical.open` non può essere rimosso.
   - In caso di installazione futura del launcher v8 e successivo rollback, è sufficiente un `adb uninstall it.akai.customhome` per ripristinare istantaneamente il launcher di fabbrica OEM come Home predefinita.
3. **Firma Digitale di Release:**
   - Gli artefatti compilati in CI sono rigorosamente denominati `akai-custom-home-v8-ci-test-nondistributable.apk` e firmati con chiave effimera usa-e-getta.
   - Prima di qualsiasi futuro piano di deploy su hardware reale (subordinato ad approvazione esplicita dell'utente), verrà generato e conservato un keystore persistente dedicato con impronta SHA-256 certificata.

---

### 4. Stato PR e Hardware Freeze

- **PR #3:** Pronta e validata in CI con suite Java (113/113) e suite isolamento ADB (7/7).
- **PR #1:** Mantenuta isolata sul proprio branch, nessun merge effettuato.
- **Hardware TV (`192.168.1.8`):** Freeze totale attivo al 100%.
