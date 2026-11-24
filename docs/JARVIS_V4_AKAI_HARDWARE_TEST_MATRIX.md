# JARVIS v4 — Matrice di Collaudo Reale AKAI e Percorso Operativo Backup / OTA (`NEXT-8`)

**Stato documento:** guida operativa host+TV in preparazione al collaudo hardware; **nessuna** autorizzazione implicita ad installazioni OTA/ADB sulla TV.  
**Hardware target:** AKAI `AKTV5037N` (Android 9 / API 28, `armeabi-v7a`, stato base attuale preservato su **RC2 `versionCode 6`**, A2 Rescue `v7`, Home v8 intatta).  
**Principio vincolante:** nessuna nuova dipendenza o framework e nessun refactoring non indispensabile nella v4 Diagnostic.

---

## 1. Percorso operativo Backup, Recupero e Provisioning OTA (PC Owner offline)

Tutte le operazioni seguenti girano esclusivamente sul PC Windows privato dell'owner, fuori dal repository Git e senza eseguire scritture sulla TV finché l'owner non autorizza esplicitamente il collaudo:

1. **Inizializzazione Trust OTA (una tantum, chiavi fuori dal repo):**
   - **Staging isolato (collaudo v4):** `node scripts/18_prepare_ota_staging.mjs --mode init-staging-trust` (usa `JARVIS_OTA_STAGING_PASSPHRASE` e salva in trust locale privato separato).
   - **Release finale (solo dopo `V4_COMPLETE_ACCEPTED`):** `node scripts/13_create_ota_release_trust.mjs` (usa `JARVIS_OTA_RELEASE_PASSPHRASE`).
2. **Esportazione e verifica offline non distruttiva del backup cifrato:**
   - Esportazione: `scripts/16_export_portable_recovery_bundle.ps1 -Action export -BackupSessionDir <dir-privata> -OutputBundlePath <bundle.akv.json>`.
   - Verifica ripristino offline (decifratura `PBKDF2` + `AES-256-CBC` + `HMAC`, controllo APK ZIP, SQLite `PRAGMA integrity_check`, PKCS#12/CA e XML): `scripts/16_export_portable_recovery_bundle.ps1 -Action verify-restore-offline -BundlePath <bundle.akv.json>`.
   - **Regola backup esterno vs locale:** quando il bundle cifrato è custodito su PC/supporto esterno anziché in `filesDir/ota-evidence/ota-backup.bundle` sulla TV, `OtaRecoveryEvidenceStore` richiede ugualmente la ricevuta crittografica `jarvis-ota-evidence-v2` firmata solo **dopo** esito `OFFLINE_RESTORE_VERIFIED` reale su PC e presenza di un APK A2 Rescue (`scripts/15_build_jarvis_a2_rescue.ps1`, non-debuggable, `versionCode > candidateVersionCode`) per ripristino in-place senza downgrade `-d` né disinstallazione. Se `ota-backup.bundle` è presente anche in locale nella directory privata della TV, `OtaRecoveryEvidenceStore` ne verifica inoltre byte-per-byte lo SHA-256 (`EVIDENCE_LOCAL_ARCHIVE_HASH_MISMATCH`).
3. **Emissione e verifica archivio + certificato/versione Rescue APK (`scripts/19`):**
   - Emissione offline ricevuta `jarvis-ota-evidence-v2`: `node scripts/19_issue_ota_recovery_evidence.mjs --mode issue ...`
     - Verifica automaticamente via `apksigner.jar` e `aapt` (`proveActualRescueApk`): firma **v2** con certificato originale `EXPECTED_CERT`, singolo firmatario, `package=it.akai.customremote`, `versionCode == recoveryRescueVersionCode`, SDK `21`/`28`, ABI `armeabi-v7a`, `android:debuggable=false` (`0x0`).
     - Esegue `scripts/16 -Action verify-restore-offline` e lega i digest SHA-256 reali su disco di backup e APK Rescue nella ricevuta firmata.
   - Riesame locale della ricevuta emessa: `node scripts/19_issue_ota_recovery_evidence.mjs --mode verify-with-archive ...`
4. **Preflight readiness e coerenza versioni (`scripts/17`):**
   - `scripts/17_check_ota_provisioning_readiness.ps1` verifica su Staging (`installed < candidate < recoveryRescue`) e su Release (`installed <= priorRescueFloor < candidate < postReleaseRescue`) l'APK compilato, i metadati manifest e la chiave pubblica senza fidarsi di report mock.
5. **Compilazione e preparazione canale OTA (senza toccare la TV):**
   - Build diagnostico / staging (`scripts/12_build_jarvis_final_candidate.ps1 -BuildProfile Diagnostic -OtaStagingTest ...`) -> manifesto staging (`scripts/18_prepare_ota_staging.mjs --mode sign-staging ...`).
   - Build v5 finale *solo dopo accettazione completa della v4* (`scripts/12` profilo `Release`, `android:debuggable=false`, `scripts/14_sign_ota_release_manifest.mjs`).

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
3. **Materiali reali firmati offline dall'owner (non simulabili in CI):** keystore originale, trust OTA staging/release (`scripts/18` / `scripts/13`), bundle cifrato verificato (`scripts/16`), APK Rescue firmato verificato con certificato originale (`scripts/15`) e ricevuta `jarvis-ota-evidence-v2` (`scripts/19`).
4. **Esecuzione della matrice fisica `HW-01..HW-08` sulla Smart TV:** raccolta di misure numeriche reali RAM/CPU (`scripts/05`), comportamento app/DRM/DeepSeek/Kimi, Telecomando Web a PC spento e test OTA staging + recupero.
