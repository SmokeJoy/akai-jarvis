# AKAI JARVIS v5 — Piano Operativo di Backup Reale Verificato (TV AKAI `192.168.1.101`)

**Stato esecuzione:** **SOLO PIANO — NON ESEGUITO.**  
L'hardware freeze sulla TV fisica (`192.168.1.101`) resta attivo. Nessun comando ADB, `adb root`, `am force-stop`, backup reale, installazione o provisioning TLS verrà eseguito senza approvazione esplicita dell'utente.

---

## 1. Separazione Rigorosa delle Autorizzazioni

| Autorizzazione | Perimetro Operativo Esatto | Cosa Tocca sulla TV | Prerequisito di Avvio |
| :--- | :--- | :--- | :--- |
| **Autorizzazione (A)** *(Richiesta ora)* | **Solo Backup Reale JARVIS v5 + Prova Ripristinabilità Offline + Ripristino Verificato Servizio v5 (`try/finally`)** | **Zero scritture persistenti su APK o DB sulla TV**, ma **modifiche temporanee allo stato runtime**: `am force-stop` arresta temporaneamente `it.akai.customremote` (**stima nominale ~10–15 s**, timeout massimo cumulativo stimato **~35–45 s**), elevazione temporanea controllata `adb root` (riavvio temporaneo `adbd`) -> estrazione sola lettura DB+WAL -> `adb unroot` verificato (`uid=2000`), ripristino automatico `finally` di v5 compatibile Android 9 con verifica `/api/status`. In caso di disconnessione ADB: stato dichiarato `UNKNOWN` e procedura manuale esplicita. | Approvazione esplicita dell'utente per **Fase (A)** |
| **Autorizzazione (B)** *(Successiva e separata)* | **Upgrade In-Place a JARVIS v6, Watchdog HTTPS `8443` (SAN `192.168.1.101`), Provisioning TLS ed Eventuale Rollback** | Verifica `applicationId`, `versionCode >= installedVersionCode` e firma SHA-256 -> `adb install -r` (**senza `-d`**, downgrade vietato salvo piano separato / `-Action rollback`), generazione/validazione certificato TLS `AKAI Jarvis Local CA` per `192.168.1.101`, collaudo Safari iPhone a PC spento. | Completamento + verifica integrità offline del backup **Fase (A)** e **nuova autorizzazione esplicita** dell'utente per **Fase (B)** |

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
- Prima di invocare `am force-stop`, registra `$wasRunning = $preStopState.IsRunning` tramite `Get-ApplicationProcessState`.
- All'interno di un blocco `try { ... } finally { ... }`, esegue `adb -s 192.168.1.101:5555 shell "am force-stop it.akai.customremote"` (richiede `exit 0`).
- Attende 300 ms ed esegue il probe deterministico `Get-ApplicationProcessState`:
  `pids=$(pidof it.akai.customremote 2>/dev/null); code=$?; echo PIDOF_CHECK:pids=[$pids]:exit=[$code]`.
- Accetta **solo** `pidofExit == 1` con `pids == []` (zero processi attivi).
- **Nessun `kill -9` implicito nella Fase A**: se dopo `am force-stop` risulta ancora attivo un PID residuo, `Ensure-ApplicationQuiescence` abortisce immediatamente in **Fail-Closed** prima di qualsiasi lettura DB, e il blocco `finally` invoca `Restore-TargetApplicationService` per garantire il ripristino del servizio v5.

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

## 7. Recovery Atomico `try/finally` del Servizio v5, Durata Stimata & Gate Fase (B)

> **Wrapper eseguibile in `-Action backup`**: `05_safe_install_and_rollback.ps1` registra `$wasRunning` prima di `am force-stop` ed esegue l'intera quiescenza/estrazione/checkpoint all'interno di un blocco `try { ... } finally { ... }`. In ogni percorso (successo o eccezione su copia DB/WAL, checksum o ADB), se `$wasRunning -and $stopIssued`, il `finally` invoca `Restore-TargetApplicationService`.

1. **Riavvio v5 compatibile Android 9 (`targetSdkVersion=28`, `.RemoteServerService` non esportato vs `.MainActivity` esportata)**:
   - Se `$UnrootVerified` è falso (`STATO ADBD UNKNOWN`), la funzione **non** dichiara mai ripristinato il servizio e segnala `[STATO SERVIZIO V5 UNKNOWN / RECUPERO MANUALE RICHIESTO]`.
   - Verifica connettività ADB (`echo ADB_ALIVE`). Se ADB è irraggiungibile: stato **`UNKNOWN`** e stampa procedura manuale esplicita.
   - Tenta nell'ordine: (1) `am startservice -n it.akai.customremote/.RemoteServerService`, (2) `cmd activity start-service it.akai.customremote/.RemoteServerService`, (3) fallback Activity esportata `am start -n it.akai.customremote/.MainActivity`.
   - Verifica sia il processo attivo (`Get-ApplicationProcessState` -> PID non vuoto) sia la salute applicativa (`GET /api/status` con `status == "ok"` e `uinput_ready == true`, fino a 3 tentativi).

### Tabella Compatta degli Effetti Reali e Tempi Stimati durante Fase (A)

| Aspetto | Effetto Reale sulla TV `192.168.1.101` |
| :--- | :--- |
| **Comando arresto** | `am force-stop it.akai.customremote` arresta temporaneamente solo il processo JARVIS v5 per evitare corruzione WAL; `adb root`/`adb unroot` riavvia temporaneamente il daemon `adbd`. |
| **Stima indisponibilità nominale e timeout massimi** | **Stima nominale: ~10–15 secondi** per il solo server web v5 (`8088`). In caso di errori/retry (`adb root` + `unroot` + `exec-out` + 3 tentativi health check), i **timeout massimi cumulativi stimati arrivano a ~35–45 secondi** (o interruzione più lunga se ADB cade e richiede recupero manuale). |
| **Impatto previsto su TV / telecomando fisico / Home v8** | Atteso trascurabile sulla visione video (canali DTV/HDMI, IR fisico, `it.akai.customhome.v8` e tasto MENU restano intatti e non toccati da alcun comando). |
| **Scritture su disco / modificabilità** | **Zero scritture persistenti su APK o DB v5 della TV**, pur includendo **modifiche temporanee allo stato runtime** (`force-stop`, `adb root`/`unroot`, ripristino servizio). |
| **Comandi distruttivi** | **Nessuno** (`adb uninstall`, `pm clear`, wipe, flash, `kill -9` implicito e `-d` su installazione categoricamente esclusi). |

### Comportamento in Caso di Errore & Gate per Successiva Fase (B)
- **Fallimento `am force-stop` / PID residuo**: abort immediato in `Ensure-ApplicationQuiescence` **senza `kill -9`**, blocco `finally` invoca comunque `Restore-TargetApplicationService` su v5 e verifica processo + `/api/status`.
- **Fallimento `adb root` o `adb unroot` (`uid!=2000`)**: se `adb unroot` fallisce o ADB diventa irraggiungibile dopo `force-stop`, emissione di **`[STATO SERVIZIO V5 UNKNOWN / RECUPERO MANUALE RICHIESTO]`** con comandi manuali `adb -s 192.168.1.101:5555 unroot && adb -s 192.168.1.101:5555 shell id && adb -s 192.168.1.101:5555 shell am start -n it.akai.customremote/.MainActivity`.
- **Gate obbligatorio per Fase (B) (`-Action install`)**: prima dell'installazione, `Test-PackageUpgradeGate` verifica `applicationId == it.akai.customremote`, `versionCode >= installedVersionCode` e firma SHA-256; `adb install -r` **non include più `-d`** (riservato esclusivamente a `-Action rollback` esplicito). Clean-start (`-GreenfieldStart`) resta ammesso solo con pacchetto assente e consenso specifico.
