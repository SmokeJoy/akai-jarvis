# JARVIS v4 — Matrice di Collaudo Reale AKAI e Percorso Operativo Backup / OTA (`NEXT-8`)

**Stato documento:** guida operativa host+TV in preparazione al collaudo hardware; **nessuna** autorizzazione implicita ad installazioni OTA/ADB sulla TV.  
**Hardware target:** AKAI `AKTV5037N` (Android 9 / API 28, `armeabi-v7a`, stato base attuale preservato su **RC2 `versionCode 6`**, A2 Rescue `v7`, Home v8 intatta).  
**Principio vincolante:** nessuna nuova dipendenza o framework e nessun refactoring non indispensabile nella v4 Diagnostic.

---

## 1. Percorso operativo Backup, Recupero e Provisioning OTA (PC Owner offline)

Tutte le operazioni seguenti girano esclusivamente sul PC Windows privato dell'owner, fuori dal repository Git e senza eseguire scritture sulla TV finché l'owner non autorizza esplicitamente il collaudo:

1. **Inizializzazione Trust OTA (una tantum, chiavi fuori dal repo):**
   - **Staging isolato (collaudo v4):** `node scripts/18_prepare_ota_staging.mjs --mode init-staging-trust` (usa `JARVIS_OTA_STAGING_PASSPHRASE` e salva in trust locale privato `$LOCALAPPDATA/AkaiJarvisOtaStagingTrust`).
   - **Release finale (solo dopo `V4_COMPLETE_ACCEPTED`):** `node scripts/13_create_ota_release_trust.mjs` (usa `JARVIS_OTA_RELEASE_PASSPHRASE` e salva in `$LOCALAPPDATA/AkaiJarvisOtaReleaseTrust`).
2. **Backup reale sessione corrente (`RC2 v6`), esportazione e verifica offline non distruttiva:**
   - Raccogliere uno snapshot aggiornato dei dati reali del dispositivo corrente (`RC2 versionCode=6`: SQLite/WAL, keystore TLS, pairing).
   - Esportazione cifrata: `scripts/16_export_portable_recovery_bundle.ps1 -Action export -BackupSessionDir <dir-privata> -OutputBundlePath <bundle.akv.json>` (usa `JARVIS_RECOVERY_PASSPHRASE`).
   - Verifica ripristino offline (decifratura `PBKDF2` + `AES-256-CBC` + `HMAC`, controllo APK ZIP, SQLite `PRAGMA integrity_check`, PKCS#12/CA e XML): `scripts/16_export_portable_recovery_bundle.ps1 -Action verify-restore-offline -BundlePath <bundle.akv.json>`.
   - **Regola backup esterno vs locale:** quando il bundle cifrato è custodito su PC/supporto esterno anziché in `filesDir/ota-evidence/ota-backup.bundle` sulla TV, `OtaRecoveryEvidenceStore` richiede ugualmente la ricevuta crittografica `jarvis-ota-evidence-v2` firmata solo **dopo** esito `OFFLINE_RESTORE_VERIFIED` reale su PC e presenza di un APK A2 Rescue (`scripts/15_build_jarvis_a2_rescue.ps1`, non-debuggable, `versionCode > candidateVersionCode`) per ripristino in-place senza downgrade `-d` né disinstallazione. Se `ota-backup.bundle` è presente anche in locale nella directory privata della TV, `OtaRecoveryEvidenceStore` ne verifica inoltre byte-per-byte lo SHA-256 (`EVIDENCE_LOCAL_ARCHIVE_HASH_MISMATCH`).
3. **Compilazione APK candidato e APK A2 Rescue PRIMA del preflight (`scripts/12` e `scripts/15`):**
   - Compilare sul PC privato dell'owner (solo su HEAD con CI GitHub Actions `completed/success`) il pacchetto candidato v4 Diagnostic di staging, ad es. con `RC2 v6` già installata:
     - `scripts/12_build_jarvis_final_candidate.ps1 -BuildProfile Diagnostic -OtaStagingTest -VersionCode 8 ...` *(incorporando chiave pubblica + URL manifest HTTPS di staging)*.
     - In parallelo compilare il relativo APK di recupero in-place A2 Rescue: `scripts/15_build_jarvis_a2_rescue.ps1 -RescueVersionCode 9 -TargetToRecoverVersionCode 8 ...` *(non-debuggable; `jarvis-a2-rescue-v7-owner-signed.apk` copre l'attuale RC2 `v6`, non un futuro candidato `v8`)*.
   - **Release v5 (`-BuildProfile Release`):** compilare **solo dopo** `V4_COMPLETE_ACCEPTED` sulla matrice hardware, con `android:debuggable=false` e `VersionCode` strettamente superiore al massimo installato/preparato e nuovo Rescue `> v5`.
4. **Preflight readiness DOPO la compilazione dell'APK (`scripts/17`):**
   - Eseguire `scripts/17_check_ota_provisioning_readiness.ps1` **solo dopo** il punto 3 sull'APK e sul build manifest effettivamente compilati (mai prima della build; la sola modalità `-InventoryOnly` senza APK restituisce `OTA_TRUST_INVENTORY_INCOMPLETE` / `OTA_TRUST_INVENTORY_ONLY` con `otaReady=false`).
   - Verifica su Staging (`installed < candidate < recoveryRescue`) e su Release (`installed <= priorRescueFloor < candidate < postReleaseRescue`) tramite strumenti reali `apksigner` e `aapt` senza fidarsi di report mock.
5. **Firma del manifesto OTA e pubblicazione HTTPS durevole indipendente dal PC:**
   - Staging diagnostico: `node scripts/18_prepare_ota_staging.mjs --mode sign-staging ...`
   - Release finale *(solo dopo `V4_COMPLETE_ACCEPTED`)*: `node scripts/14_sign_ota_release_manifest.mjs ...`
   - Pubblicare manifest, firma e APK su un endpoint HTTPS pubblico/durevole raggiungibile dalla TV anche a **PC spento**.
6. **Emissione ricevuta (`scripts/19`) e procedura operativa di import sulla TV:**
   - Emissione offline: `node scripts/19_issue_ota_recovery_evidence.mjs --mode issue ...` *(verifica via `apksigner.jar` + `aapt` certificato originale `EXPECTED_CERT`, `package=it.akai.customremote`, `versionCode == recoveryRescueVersionCode`, SDK `21`/`28`, `armeabi-v7a`, `android:debuggable=false`, esegue `scripts/16 -Action verify-restore-offline` e lega gli SHA-256 reali su disco)*.
   - Riesame locale: `node scripts/19_issue_ota_recovery_evidence.mjs --mode verify-with-archive ...`
   - **Import operativo sulla TV (`ota-evidence/`):**
     - **Su v4 Diagnostic (`android:debuggable=true`):** l'owner autorizzato copia `ota-recovery-evidence.receipt` e `.receipt.sig` nella sandbox privata dell'app (`files/ota-evidence/`) tramite `adb shell run-as it.akai.customremote` prima dell'esecuzione `HW-06` a PC spento.
     - **Limite operativo noto per v5 Release (`android:debuggable=false`):** con `debuggable=false` `adb shell run-as` non è utilizzabile e in `OtaRecoveryEvidenceStore.importVerifiedReceipt(...)` esiste oggi solo il metodo helper offline senza ancora un chiamante UI/operativo esposto sull'app; questo gap va considerato prima di passare alla fase v5 se si vorranno emettere nuove ricevute in produzione dopo la chiusura del debug.

---

## 2. Consolidamento funzionalità v4 Diagnostic (nessuna nuova dipendenza)

| Funzionalità | Stato codice/CI host | Dipendenze aggiuntive | Nota operatività su AKAI |
|---|---|---|---|
| **Architettura DeepSeek / Kimi** | Implementata (CI PASS) | Nessuna | Richiede connettività e consenso esplicito per invio frame |
| **Navigazione autonoma + STOP + TIF/HDMI/DTV** | Implementata (CI PASS) | Nessuna | Richiede Accessibilità attiva e verifica visiva `STATE_VERIFIED` |
| **Memoria SQLite & Apprendimento** | Implementata (CI PASS) | Nessuna | Aggiorna procedure solo su esito verificato; quarantena fail |
| **Telecomando Web HTTPS** | Implementata (CI PASS) | Nessuna | Operativo a PC spento su LAN dopo pairing + Root CA |
| **OTA HTTPS + `jarvis-ota-evidence-v2`** | PASS host / `NON_AUTHORITATIVE` | Nessuna | Consenso owner separato da evidenza + check reale Rescue APK |
| **Backup & Rescue A2 (`scripts/15`/`16`/`19`)** | Implementata + check APK cert/versionCode | Nessuna | Richiede prima esecuzione fisica su archivi reali dell'owner |

---

## 3. Matrice di collaudo reale su Smart TV AKAI (`NOT_RUN`)

Ogni prova va registrata con timestamp, scenario, logcat/dumpsys sanitizzati ed esito numerico ripetibile (`PASS` / `FAIL` / `BLOCKED`):

| ID | Area di collaudo | Procedura minima su AKAI TV (sola lettura/uso consentito) | Criterio oggettivo di PASS | Stato |
|---|---|---|---|---|
| **HW-01** | **Accessibilità & Stato TV** | Verificare servizio Accessibilità attivo; aprire canali DTV e ingressi HDMI via Home v8 / TV Input Framework | Accessibilità rilevata attiva; nessuna falsa conferma senza osservazione reale (`STATE_VERIFIED`) | `NOT_RUN` |
| **HW-02** | **Navigazione autonoma & STOP** | Avviare ricerca/apertura contenuto multipasso fra app installate; premere `STOP` durante il loop | Recupero singolo passo funzionante; interruzione immediata allo `STOP` senza azioni residue | `NOT_RUN` |
| **HW-03** | **Memoria & Apprendimento** | Ripetere una procedura riuscita e indurre un percorso errato/cambiato UI | Procedura salvata in SQLite solo dopo successo verificato; percorso fallito messo in quarantena | `NOT_RUN` |
| **HW-04** | **DeepSeek / Kimi** | Eseguire richiesta vocale/testuale con fallback visivo previo consenso MediaProjection e consenso cloud separato | Modelli ammessi rispettati; rifiuto pulito se consenso negato | `NOT_RUN` |
| **HW-05** | **Telecomando Web HTTPS (PC spento)** | Aprire UI Web da telefono/browser in LAN con PC spento; testare tasti, stato, volume | Connessione HTTPS valida con pairing/CA preservati; controllo reattivo | `NOT_RUN` |
| **HW-06** | **OTA PC spento + Backup/Rescue** | Importare ricevuta `jarvis-ota-evidence-v2` firmata da `scripts/19` in `ota-evidence/`; verificare menu OTA su staging firmato e conferma fisica owner; verificare ripristino A2 Rescue | Blocco fail-closed se ricevuta mancante/alterata; aggiornamento staging confermabile su TV; recupero A2 Rescue senza uninstall né `-d` | `NOT_RUN` |
| **HW-07** | **Prestazioni RAM** | Eseguire `scripts/05_monitor_performance.ps1 -DeviceId <TV_LAN_IP>:5555 -SessionType utilizzo` e `dumpsys meminfo it.akai.customremote` prima, durante e dopo il collaudo | `MemAvailable` e `TOTAL PSS` stabili senza leak crescenti su sessioni ripetute né OOM killer | `NOT_RUN` |
| **HW-08** | **Prestazioni CPU, Idle & Invarianti** | Eseguire `scripts/05_monitor_performance.ps1 -DeviceId <TV_LAN_IP>:5555 -SessionType riposo` (baseline + post-riavvio) | CPU delta idle contenuta; zero ANR/crash; tuner DTV, HDMI, LTvLauncher e telecomando originale intatti | `NOT_RUN` |

---

## 4. Blocchi realmente impeditivi per il collaudo (lista chiusa)

Al netto delle verifiche host/CI già verdi, restano **esclusivamente** questi quattro blocchi concreti prima di passare da `V4_INCOMPLETE` a `V4_COMPLETE_ACCEPTED`:

1. **Autorizzazione esplicita dell'owner per la sessione TV:** consenso puntuale per compilare/installare sulla AKAI (oggi lasciata intatta su RC2 `versionCode 6`).
2. **Abilitazione fisica Accessibilità sulla AKAI:** attivazione manuale dell'Accessibility Service di JARVIS dalle Impostazioni Android della TV.
3. **Materiali reali firmati offline dall'owner (non simulabili in CI):** keystore originale, trust OTA staging/release (`scripts/18` / `scripts/13`), endpoint HTTPS PC-off, bundle cifrato aggiornato a `RC2 v6` e verificato (`scripts/16`), nuova coppia APK v4 Diagnostic `v8` + Rescue `v9` firmata dall'owner (`scripts/12` / `scripts/15`) e ricevuta `jarvis-ota-evidence-v2` (`scripts/19`).
4. **Esecuzione della matrice fisica `HW-01..HW-08` sulla Smart TV:** raccolta di misure numeriche reali RAM/CPU (`scripts/05`), comportamento app/DRM/DeepSeek/Kimi, Telecomando Web a PC spento e test OTA staging + recupero.

---

## 5. Inventario locale in sola lettura, materiali mancanti e sequenza owner-led (`24/11/2026`)

Ricognizione in sola lettura eseguita sull'host Windows privato dell'owner (nessun segreto esposto, nessuna modifica a TV/chiavi; **`V4_INCOMPLETE` · `TV_NOT_RUN` · `NO-GO` installazione**):

### 5.1 Artefatti già presenti e verificati sull'host
- **Toolchain completa disponibile (`PASS`):** `JDK 17`, `Android SDK API 28`, `Build Tools 28.0.3` (`aapt`, `aapt2`, `apksigner.jar`, `d8.jar`, `zipalign`), `NDK 21.4.7075529` (`armv7a-linux-androideabi21-clang`), `Node.js v22.23.4`, `ADB`.
- **APK A2 Rescue esistente (`$LOCALAPPDATA/AkaiJarvisBuilds/A2-RESCUE-v7-20261122-020820-466/.../jarvis-a2-rescue-v7-owner-signed.apk`, `206.241 B`, `2026-11-22`):**
  - Verificato in sola lettura tramite `proveActualRescueApk` (`apksigner.jar` + `aapt` reali): `verified=true`, `packageName=it.akai.customremote`, `versionCode=7`, `versionName=1.2.0-a2-rescue-v7`, `originalSignerSha256=21c2c41dc4c34576cca14ad5404e87d1c5a07ace961c0fab96d128c2164a51ed`, `debuggable=false`, SDK `21`/`28`, `armeabi-v7a`.
  - *Nota versioni:* recupera l'attuale `RC2 v6` sulla TV, ma **non** basterà per recuperare un nuovo candidato Diagnostic `v8` (servirà `v9`).
- **APK Diagnostic precedente (`$LOCALAPPDATA/AkaiJarvisBuilds/FINAL-v6-20261122-020804-644/.../jarvis-v4-ota-stage-v6-owner-signed-diagnostic.apk`, `259.489 B`, `2026-11-22`):** corrisponde a **RC2 `versionCode 6`** già presente sulla TV (OTA `otaProvisioned` vuoto, `gitHead` non valorizzato nel manifest locale).
- **Vault backup locale (`$LOCALAPPDATA/AkaiTvSecureVault/it.akai.customremote`):** contiene snapshot cifrati locali del `2026-11-22` (più recente completo di TLS+pairing `backup_20261122_111520` oltre a sessioni pairing successive), ma **0** archivi portatili `*.akv.json` già esportati/verificati con `scripts/16` (`PORTABLE_AKV_BUNDLES=0`).

### 5.2 Materiali e prerequisiti ancora mancanti (solo owner-led)
1. **Keystore di firma Android originale + passphrase private** (`JARVIS_SIGNING_STOREPASS`, `JARVIS_SIGNING_KEYPASS` oggi non impostate in ambiente).
2. **Trust OTA e chiavi offline** (`$LOCALAPPDATA/AkaiJarvisOtaStagingTrust` e `$LOCALAPPDATA/AkaiJarvisOtaReleaseTrust` assenti): `scripts/17_check_ota_provisioning_readiness.ps1 -InventoryOnly` restituisce `OTA_TRUST_INVENTORY_INCOMPLETE` (`MISSING_OTA_TRUST_PUBLIC_KEY`, `MISSING_OTA_MANIFEST_URL`); assenti anche `JARVIS_OTA_STAGING_PASSPHRASE` e `JARVIS_OTA_RELEASE_PASSPHRASE`.
3. **Endpoint HTTPS durevole PC-off** configurato per servire manifest e APK di staging (e successivamente release).
4. **Backup aggiornato dell'attuale `RC2 v6` (SQLite/WAL + TLS + pairing)** esportato in bundle portatile cifrato e verificato con `scripts/16 -Action verify-restore-offline` (`JARVIS_RECOVERY_PASSPHRASE` oggi assente).
5. **Nuova coppia di APK compilata da HEAD verificato CI e firmata con certificato originale:** candidato v4 Diagnostic (es. `v8`) + nuovo Rescue A2 in-place (es. `v9`; e per eventuale OTA staging `v8 -> v9`, relativo Rescue `v10`).
6. **Chiamante UI/operativo per `OtaRecoveryEvidenceStore.importVerifiedReceipt(...)` prima di v5:** oggi `run-as` copre l'import durante il collaudo su v4 Diagnostic `debuggable=true` (`HW-06`), mentre su v5 Release `debuggable=false` servirà esporre un percorso UI/operativo autenticato di import ricevuta se si vorranno importare nuove ricevute post-release.
7. **Sessione fisica autorizzata sulla TV:** riattivazione Accessibilità sulla AKAI ed esecuzione completa `HW-01..HW-08`.
