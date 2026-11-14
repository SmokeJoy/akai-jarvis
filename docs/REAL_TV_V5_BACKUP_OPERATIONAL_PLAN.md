# AKAI JARVIS v5 — Piano Operativo di Backup Reale Verificato (TV AKAI `192.168.1.101`)

**Stato esecuzione:** **SOLO PIANO — NON ESEGUITO.**  
L'hardware freeze sulla TV fisica (`192.168.1.101`) resta attivo. Nessun comando ADB, `adb root`, `am force-stop`, backup reale, installazione o provisioning TLS verrà eseguito senza approvazione esplicita dell'utente.

---

## 1. Separazione Rigorosa delle Autorizzazioni

| Autorizzazione | Perimetro Operativo Esatto | Cosa Tocca sulla TV | Prerequisito di Avvio |
| :--- | :--- | :--- | :--- |
| **Autorizzazione (A)** *(Richiesta ora)* | **Solo Backup Reale JARVIS v5 + Prova Ripristinabilità Offline + Riavvio Immediato Servizio v5** | Breve arresto di `it.akai.customremote` (~10–15 s), elevazione temporanea `adb root` -> estrazione DB+WAL -> `adb unroot`, riavvio `RemoteServerService` v5. **Zero modifiche a APK o DB sulla TV.** | Approvazione esplicita dell'utente per **Fase (A)** |
| **Autorizzazione (B)** *(Successiva e separata)* | **Upgrade In-Place a JARVIS v6, Watchdog HTTPS `8443` (SAN `192.168.1.101`), Provisioning TLS ed Eventuale Rollback** | Sostituzione APK (`adb install -r -d`), generazione/validazione certificato TLS `AKAI Jarvis Local CA` per `192.168.1.101`, collaudo Safari iPhone a PC spento. | Completamento + verifica integrità offline del backup **Fase (A)** e **nuova autorizzazione esplicita** dell'utente per **Fase (B)** |

---

## 2. Target Fisico, Pacchetto Esatto e Invarianti Intoccabili

Valori rilevati durante l'audit read-only documentato sulla PR #1 (`#issuecomment-6878054878`):
- **Dispositivo target**: `AKAI AKTV5037N`, chassis/piattaforma `SmartTV (m7332)`
- **Build Fingerprint**: `MediaTek/m7332_eu/m7332_eu:9/PPR2.180905.006.A1/zhangsong11161808:userdebug/release-keys`
- **SELinux**: `Permissive`
- **Endpoint ADB**: `192.168.1.101:5555`
- **Pacchetto target (unico oggetto di backup)**: `it.akai.customremote`
  - **Versione attesa su TV**: `versionCode=1`, `versionName=1.0.0` (baseline v5 pre-HTTPS)
  - **UID Linux**: `u0_a51` (PID rilevato al preflight: `5611`)
  - **Directory dati SQLite**: `/data/data/it.akai.customremote/databases/` (`akai_memory.db` ~40.960 bytes, `akai_memory.db-wal` ~428.512 bytes, `akai_memory.db-shm` ~32.768 bytes al preflight)
- **Invarianti assolute (zero comandi eseguiti)**:
  - `it.akai.customhome.v8` (Home v8 vc11) e tasto **MENU** fisico: **INTOCCABILI**
  - `it.akai.customhome` (fallback Home v7): **INTOCCABILE**
  - Branch `main`: nessun merge

---

## 3. Prerequisiti Pre-Esecuzione (Controllo Fail-Closed)

Prima di avviare qualsiasi comando verso `192.168.1.101`:
1. **Connettività TV e ADB**:
   - `adb connect 192.168.1.101:5555` attivo e `adb -s 192.168.1.101:5555 shell id` -> `uid=2000(shell) gid=2000(shell)`.
   - `pm list packages it.akai.customremote` conferma presenza di `it.akai.customremote`; `pm list packages it.akai.customhome.v8` conferma integrità di Home v8 prima dell'inizio.
   - HTTP v5 attivo prima del fermo: `GET http://192.168.1.101:8088/api/status` risponde `200` con `uinput_ready: true`.
2. **Strumenti locali su PC sviluppatore** (verificati da [`05_safe_install_and_rollback.ps1`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/akai-remote-tests/05_safe_install_and_rollback.ps1)):
   - `adb.exe` (`Get-AdbExecutable`)
   - `tools\jdk-17\bin\java.exe` + `tools\android-sdk\build-tools\28.0.3\lib\apksigner.jar`
   - Interprete SQLite offline per checkpoint/integrità (`tools\nodejs\node.exe` con `node:sqlite`, oppure `python`/`python3` con `sqlite3`, oppure `sqlite3` CLI — se tutti assenti, `Verify-SQLiteIntegrityOffline` abortisce Fail-Closed)
3. **Cartella di sessione isolata**:
   - `.\backup_tv\backup_<yyyyMMdd_HHmmss>\` (nuova directory per sessione, nessuna sovrascrittura di backup precedenti).

---

## 4. Estrazione APK Precedente (v5) e Verifica Firma Digitale

1. Risoluzione percorso APK reale sulla TV:
   - `adb -s 192.168.1.101:5555 shell "pm path it.akai.customremote"`
2. Download read-only su PC:
   - `adb -s 192.168.1.101:5555 pull <percorso_apk_remoto> .\backup_tv\backup_<ts>\it.akai.customremote_backup.apk`
3. Verifica firma digitale tramite `Get-ApkCertificateFingerprint` (`apksigner verify --print-certs`):
   - Estrae il digest SHA-256 a 64 caratteri esadecimali del firmatario #1 dell'APK v5 estratto.
   - Confronto con l'impronta nota di `tools/debug.keystore` rilevata al preflight:
     `21c2c41dc4c34576cca14ad5404e87d1c5a07ace961c0fab96d128c2164a51ed`.
   - Salvataggio dello SHA-256 binario del file `it.akai.customremote_backup.apk` per tracciabilità rollback.

---

## 5. Quiescenza DB + WAL, Gestione `adb root`/`adb unroot`, Checkpoint Offline e Hash SHA-256

La procedura riutilizza i meccanismi Fail-Closed già testati (29/29) in [`05_safe_install_and_rollback.ps1`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/akai-remote-tests/05_safe_install_and_rollback.ps1):

### Passo 5.1 — Snapshot Logico Preventivo (Read-Only HTTP, pre-stop)
- `GET http://192.168.1.101:8088/api/ai/memory` -> salvato in `akai_memory_logical_backup.json` come copia logica aggiuntiva di sicurezza prima dell'arresto del processo (non sostituisce il backup binario SQLite).

### Passo 5.2 — Quiescenza Verificata del Writer (`Ensure-ApplicationQuiescence`)
- Esegue `adb -s 192.168.1.101:5555 shell "am force-stop it.akai.customremote"` (richiede `exit 0`).
- Attende 300 ms ed esegue il probe deterministico `Get-ApplicationProcessState`:
  `pids=$(pidof it.akai.customremote 2>/dev/null); code=$?; echo PIDOF_CHECK:pids=[$pids]:exit=[$code]`.
- Accetta **solo** `pidofExit == 1` con `pids == []` (zero processi attivi).
- Se risulta ancora attivo un PID residuo, tenta una sola volta `kill -9 <pids>`, ripete il probe dopo 300 ms e abortisce in **Fail-Closed** se un writer rimane in esecuzione (prevenzione assoluta di copie DB incoerenti).

### Passo 5.3 — Elevazione Controllata `adb root` -> Estrazione DB + WAL -> `adb unroot` (`Invoke-WithAdbElevation`)
1. Verifica contesto iniziale: `adb -s 192.168.1.101:5555 shell id`.
2. Poiché `it.akai.customremote` v5 non espone `run-as` (build release non debuggable) né `su`, entra il blocco controllato `Invoke-WithAdbElevation`:
   - Esegue `adb -s 192.168.1.101:5555 root`, attende 1000 ms, riconnette ADB e chiama `wait-for-device`.
   - Valida `adb -s 192.168.1.101:5555 shell id` con `Test-AdbRootIdOutput` (`^uid=0\(root\)(?:\s+gid=0\(root\))?`). Se l'elevazione non è confermata positivamente, solleva `[ELEVAZIONE ADB ROOT FALLITA]` e abortisce **senza eseguire estrazioni**.
3. Sotto `uid=0(root)` (solo lettura, zero scritture su `/data/data/it.akai.customremote`):
   - Estrae `/data/data/it.akai.customremote/databases/akai_memory.db` via `Receive-FileViaAdbExecOut` (`MinBytes = 512`) in `akai_memory.db`.
   - Esegue il probe tri-state `Probe-DeviceFileState -Channel "root"` su `/data/data/it.akai.customremote/databases/akai_memory.db-wal` (con guardia `exit 13` / `ACCESS_DENIED` se la directory non è leggibile).
   - Se il WAL risulta `EXISTS`, ne rende **obbligatoria** l'estrazione (`MinBytes = 32`) in `akai_memory.db-wal`; se manca o fallisce, abortisce in **Fail-Closed**.
4. **Rientro garantito nel blocco `finally`**:
   - Se l'elevazione è stata eseguita dalla procedura, chiama `adb -s 192.168.1.101:5555 unroot`, riconnette ADB, chiama `wait-for-device` e verifica `adb -s 192.168.1.101:5555 shell id` con `Test-AdbNonRootShellIdOutput` (`^uid=2000\(shell\)\s+gid=2000\(shell\)`).
   - Se `uid=2000(shell) gid=2000(shell)` non è confermato, solleva `[STATO ADBD UNKNOWN / RECUPERO MANUALE RICHIESTO]`.

### Passo 5.4 — Checkpoint Offline WAL e Integrità SQLite su PC (`Verify-SQLiteIntegrityOffline`)
Eseguito esclusivamente sui file estratti in locale sul PC (zero scritture su TV):
1. Esegue `PRAGMA wal_checkpoint(TRUNCATE);` verificando `busy == 0` per fondere integralmente i dati di `akai_memory.db-wal` (~428 KB al preflight) dentro `akai_memory.db`.
2. Esegue `PRAGMA integrity_check;` verificando esito esattamente pari a `ok`.
3. Verifica che il file locale `akai_memory.db-wal` post-checkpoint sia ridotto a `0` bytes (altrimenti errore Fail-Closed) e rimuove i residui locali `.db-wal` / `.db-shm` per lasciare un file singolo autonomo consolidato.
4. Calcola e registra l'**hash SHA-256** (64 hex) di `akai_memory.db` consolidato tramite `Get-Sha256Hex`.

---

## 6. Prova di Ripristinabilità Offline (100% su PC, Zero Scritture su TV)

Prima di considerare chiuso il backup **Fase (A)** e prima di chiedere in seguito l'Autorizzazione (B):
1. Creazione di una **copia di verifica offline** del file consolidato (`akai_memory_verify_copy.db`).
2. Verifica su `akai_memory_verify_copy.db` tramite SQLite locale:
   - Conferma presenza tabelle v5 attese e conteggio righe non vuoto / coerente con lo snapshot logico JSON (se acquisito).
   - Esecuzione simulata su copia temporanea locale dei test di compatibilità e rollback (`python akai-remote-tests/test_rollback_offline_simulation.py`) + verifica `apksigner verify --print-certs` su `it.akai.customremote_backup.apk`.
3. Conferma conservazione integrale nella cartella `.\backup_tv\backup_<ts>\` di:
   - `it.akai.customremote_backup.apk` + hash SHA-256 file + digest firma SHA-256
   - `akai_memory.db` consolidato + hash SHA-256
   - `akai_memory_logical_backup.json` (se server v5 raggiungibile pre-stop)

---

## 7. Riavvio Immediato Servizio v5, Durata Indisponibilità e Gestione Errori

> **Nota tecnica su `05_safe_install_and_rollback.ps1`**: il ramo `-Action backup` (righe 1384–1535) arresta `it.akai.customremote` per garantire la quiescenza del DB ma non include il riavvio finale del servizio. Di conseguenza, nella **Fase (A)**, subito dopo la verifica del ritorno di `adb` a `uid=2000(shell)`, la procedura operativa riavvierà esplicitamente il servizio v5 esistente senza installare alcun APK.

1. **Riavvio immediato JARVIS v5 post-backup**:
   - `adb -s 192.168.1.101:5555 shell "am startservice it.akai.customremote/.RemoteServerService"`
   - Verifica presenza processo (`pidof it.akai.customremote`) e verifica salute `GET http://192.168.1.101:8088/api/status` (`status == "ok"`, `uinput_ready == true`).

### Tabella Compatta degli Effetti Reali sulla TV durante Fase (A)

| Aspetto | Effetto Reale sulla TV `192.168.1.101` |
| :--- | :--- |
| **Comando arresto** | `am force-stop it.akai.customremote` arresta temporaneamente solo il processo JARVIS v5 (~10–15 secondi) per evitare corruzione WAL durante la copia del DB. |
| **Indisponibilità prevista** | Solo il vecchio server telecomando web v5 (`8088`) non risponde per **~10–15 secondi**; al termine viene riavviato subito (`am startservice it.akai.customremote/.RemoteServerService`). |
| **Impatto su visione TV / telecomando fisico / Home v8** | **Nessuno.** Canali DTV/HDMI, video, audio, telecomando IR fisico, Home v8 (`it.akai.customhome.v8`) e tasto MENU restano pienamente operativi senza riavvii né interruzioni UI. |
| **Scritture o modifiche su TV** | **Zero** modifiche a APK o DB v5 su TV. Elevazione `adb root` usata solo in lettura e revocata subito con `adb unroot` verificato a `uid=2000(shell)`. |
| **Comandi distruttivi** | **Nessuno** (`adb uninstall`, `pm clear`, wipe, flash, modifica partizioni categoricamente esclusi). |

### Comportamento in Caso di Errore (Fail-Closed & Ripristino Servizio)
- **Fallimento `am force-stop` / processo non quiescente**: abort immediato prima dell'estrazione; riavvio precauzionale di `RemoteServerService` v5 e verifica stato `8088`.
- **Fallimento `adb root` o verifica `uid=0(root)`**: blocco Fail-Closed (`[ELEVAZIONE ADB ROOT FALLITA]`), esecuzione blocco `finally` con verifica `adb unroot` (`uid=2000(shell)`), riavvio di `RemoteServerService` v5; nessuna installazione possibile.
- **Fallimento `adb unroot` (mancata conferma `uid=2000(shell)`)**: errore critico `[STATO ADBD UNKNOWN / RECUPERO MANUALE RICHIESTO]` con fermo immediato di qualunque operazione successiva e istruzione esplicita di recupero `adb -s 192.168.1.101:5555 unroot && adb -s 192.168.1.101:5555 shell id`.
- **Fallimento estrazione WAL o `PRAGMA wal_checkpoint(TRUNCATE)` / `PRAGMA integrity_check`**: backup marcato **NON VALIDO / BLOCCANTE** (Autorizzazione B resta vietata), riavvio di `RemoteServerService` v5, apertura report `[BLOCKER → CHATGPT]` su PR #1 prima di ritentare.
