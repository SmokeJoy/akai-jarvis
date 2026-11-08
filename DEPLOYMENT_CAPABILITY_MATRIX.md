# AKAI JARVIS - Deployment & Rollback Capability Matrix

## 1. Obiettivo del Documento e Decisione Architetturale

Questo documento definisce in modo formale e verificabile la matrice delle capacità e dei vincoli architetturali dell'applicazione **AKAI Custom Remote** (`it.akai.customremote`), confrontando la **baseline legacy attualmente installata (v5)** con la **versione candidata (v6 / PR #1)**.

### Decisione Tecnica Formale: DECISIONE B (Gate di Privilegio Reale e Stop Conservativo)
A seguito dell'audit condotto nell'ottava revisione tecnica, viene formalizzata la seguente decisione architetturale:
- **Vincolo del Modello di Sicurezza AOSP**: Su un'applicazione Android compilata in profilo release (`android:debuggable="false"`, `android:allowBackup="false"`, `RemoteServerService` `android:exported="false"`), il sandbox di sistema isola rigorosamente i dati privati (`/data/data/it.akai.customremote/`). Un client ADB shell standard non privilegiato (UID `shell` 2000) **non ha alcuna facoltà di leggere o scrivere il database SQLite privato**, e il comando `run-as` è categoricamente rifiutato dal sistema operativo.
- **Decisione B**: Dichiarare che il rollback conservativo bit-for-bit del database SQLite sulla baseline APK v5 installata sulla TV **non è dimostrabile né eseguibile senza privilegi di root (`su`) sul dispositivo**.
- **Conseguenza Operativa (Pre-Flight Privilege Gate)**: La procedura `05_safe_install_and_rollback.ps1` implementa un controllo preventivo di accesso reale. Se il dispositivo non dispone di accesso privilegiato per estrarre uno snapshot integro verificato con `PRAGMA integrity_check`, **l'installazione si ARRESTA CATEGORICAMENTE (STOP)** prima di apportare qualsiasi modifica all'APK o al file system.

---

## 2. Analisi Comparativa delle Capacità Architetturali

| Componente / Caratteristica | Baseline Esistente Installata (v5 - commit `ea2f35e`) | Versione Candidata (v6 - branch `fix/pr01-...`) | Vincolo Architetturale e Impatto Operativo |
|---|---|---|---|
| **Package Name** | `it.akai.customremote` | `it.akai.customremote` | Identico. Gli aggiornamenti avvengono in-place preservando `/data/data/it.akai.customremote`. |
| **Target SDK / Min SDK** | Target SDK 28 (Android 9 Pie), Min SDK 21 | Target SDK 28 (Android 9 Pie), Min SDK 21 | Identico. Compatibilità runtime nativa con Android TV 9. |
| **`android:allowBackup`** | `false` | `false` | `adb backup` è **categoricamente disabilitato** a livello di sistema operativo Android. |
| **`android:debuggable`** | `false` (release build) | `false` (release build) | `run-as it.akai.customremote` è negato dal binario AOSP `run-as` in profili di release standard. |
| **Componenti Exported** | `MainActivity` (`exported=true`)<br>`PinActivity` (`exported=true`)<br>`AkaiAccessibilityService` (`exported=true`, bind permission)<br>`BootReceiver` (`exported=true`) | `MainActivity` (`exported=true`)<br>`PinActivity` (`exported=true`)<br>`AkaiAccessibilityService` (`exported=true`)<br>`BootReceiver` (`exported=true`) | Solo le Activity e i Receiver dichiarati esportati possono ricevere intent da UID shell non privilegiati. |
| **`RemoteServerService` Exported** | `android:exported="false"` | `android:exported="false"` | Il servizio demone NON è esportato. In Android standard, comandi `am startservice` da UID diversi o shell unprivileged sono limitati o respinti. |
| **Handler Intent `onStartCommand()`** | Esegue **unicamente** `ensureServerRunning()`. Ignora qualsiasi Action passata nell'Intent. | Supporta `ACTION_BACKUP_DB` e `ACTION_RESTORE_DB` invocando metodi interni con il proprio UID. | **DISCRIMINANTE FONDAMENTALE**: La baseline v5 **NON possiede** `ACTION_BACKUP_DB` né `ACTION_RESTORE_DB`. Inviare questi intent all'APK v5 prima dell'aggiornamento è un'operazione priva di effetto. |
| **Versione Schema SQLite** | `DB_VERSION = 5` | `DB_VERSION = 6` | Upgrade automatico gestito via `onUpgrade(5, 6)`. |
| **Override `onDowngrade()`** | **ASSENTE** (implementazione predefinita Android framework: lancia `SQLiteException`) | Implementato (`onDowngrade()` logga e preserva schema senza eccezioni distruttive). | **CRITICITÀ ROLLBACK**: Se l'APK v6 porta il DB a versione 6, l'APK v5 nativo reinstallato crasha immediatamente all'apertura del DB (`user_version = 6 > 5`) se il file non viene preventivamente ripristinato a versione 5. |
| **Snapshot Consistente SQLite** | Assente nel codice Java. | Implementato (`performConsistentSnapshot` con `PRAGMA wal_checkpoint(TRUNCATE)` verificato con codice `0` ed integrity check). | La creazione di snapshot interni consistenti è una capacità nativa di v6+. |
| **Ripristino Consistente SQLite** | Assente nel codice Java. | Implementato (`restoreConsistentSnapshot` con pulizia file `-wal`/`-shm` e `PRAGMA integrity_check`). | Il ripristino guidato dall'interno dell'app è una capacità nativa di v6+. |
| **Export Logico REST HTTP** | `GET /api/ai/memory` richiede **Bearer Token** (`SecurityManager.validateToken`). Restituisce solo `conversations`, `preferences`, `db_size_*` e `stats`. **NON contiene `procedures`**. | Presente con filtri Guest Mode e boundary sicuri (9/9 campi JSON). | **LIMITI DEL BACKUP LOGICO**: L'endpoint REST v5 richiede pairing autorizzato e NON esporta le procedure né la struttura del database. Non è un sostituto del backup binario SQLite. |

---

## 3. Analisi del Ciclo di Vita dei Dati e Pre-Flight Gate

```
+-----------------------------------------------------------------------------------+
|                           FASE 1: STATO BASELINE (v5)                             |
|                                                                                   |
|  - App: v5 (no intent backup, allowBackup=false, RemoteServerService unexported)  |
|  - DB: /data/data/it.akai.customremote/databases/akai_memory.db (user_version = 5)|
|  - Rete: Server HTTP porta 8088 attivo (GET /api/ai/memory richiede Bearer Token) |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|               FASE 2: PRE-FLIGHT PRIVILEGE GATE & BACKUP (FAIL-CLOSED)            |
|                                                                                   |
|  1. Verifica accesso privilegiato (su / UID reale):                              |
|     Se accesso non disponibile -> STOP CATEGORICO (Nessun deploy autorizzato).    |
|  2. Se accesso privilegiato disponibile:                                         |
|     Esecuzione snapshot binario databases/akai_memory.db                         |
|     Verifica offline PRAGMA integrity_check e SHA-256                             |
|  3. Se presente Bearer Token opzionale:                                           |
|     Cattura dump logico conversazioni/preferenze (backup accessorio)             |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                    FASE 3: UPGRADE IN-PLACE (adb install -r -d)                   |
|                                                                                   |
|  - Android preserva /data/data/it.akai.customremote intatto a livello OS          |
|  - App v6 si avvia -> onUpgrade(5, 6) porta DB a user_version = 6                 |
|  - Watchdog 30s verifica /api/status, /index.html e uinput_ready                  |
+-----------------------------------------------------------------------------------+
                     |                                         |
         (Watchdog OK: 100%)                       (Watchdog FALLITO)
                     v                                         v
+----------------------------------------+ +----------------------------------------+
|       FASE 4A: DEPLOYMENT CONCLUSO     | |      FASE 4B: ROLLBACK ATOMICO         |
|                                        | |                                        |
|  - Sistema operativo su v6             | |  1. adb install -r -d backup_v5.apk    |
|  - DB v6 consistente e funzionante     | |  2. Ripristino DB binario v5 originale |
|  - Nuove funzioni di backup/restore    | |  3. VERIFICA POST-ROLLBACK RIGOROSA:   |
|    native operative per il futuro      | |     - Rilettura databases/akai_memory  |
|                                        | |     - PRAGMA integrity_check offline   |
|                                        | |     - Parità hash SHA-256 obbligatoria |
|                                        | |     - Se fallisce: THROW FAIL-CLOSED   |
|                                        | |  4. Riavvio RemoteServerService        |
+----------------------------------------+ +----------------------------------------+
```

---

## 4. Requisiti di Sicurezza e Correzioni Applicate

1. **Riconoscimento dei Limiti di `GET /api/ai/memory` su Baseline v5**:
   L'endpoint v5 richiede Bearer token e restituisce esclusivamente la cronologia recente delle conversazioni e le preferenze utente; **non esporta le procedure né la struttura tabelle**. Non viene pertanto qualificato come backup completo, ma unicamente come snapshot logico ausiliario condizionato all'autenticazione.
2. **Post-Rollback Verification Fail-Closed Rigorosa**:
   In `05_safe_install_and_rollback.ps1`, la verifica dell'integrità del database ripristinato e la corrispondenza bit-for-bit dell'hash SHA-256 sono **obbligatorie e vincolanti**. Qualsiasi anomalia (file illeggibile da ADB, dimensione inferiore a 512 byte, integrity check fallito, mismatch SHA-256) scatena un'eccezione bloccante immediata (`throw`), impedendo categoricamente di dichiarare riuscito un rollback non verificato.
3. **Pre-Flight Privilege Gate**:
   Il tentativo di installazione abortisce categoricamente se il canale di estrazione del database binario non è dimostrato e verificato con successo prima di invocare `adb install`.
4. **Streaming Binario Nativo .NET**:
   Confermata l'eliminazione di `Get-Content -Encoding Byte` e delle redirezioni `>`, sostituite da `Send-FileViaAdbExecIn` e `Receive-FileViaAdbExecOut` basate su stream nativi .NET.

5. **Consistenza SQLite in Modalità WAL, Probing Attivo e Checkpoint Categorico (P0-1 & P0-2)**:
   Per eliminare ogni rischio di perdita silenziosa di dati o checkpoint incompleti:
   - **Quiescenza v5 Garantita**: L'applicazione viene forzatamente arrestata (`am force-stop`) prima della lettura del database su storage e il servizio demone non viene riavviato prima della copia, garantendo la quiescenza assoluta del writer durante tutta l'estrazione;
   - **Probing Attivo Stato WAL**: Lo stato del WAL su storage viene interrogato preventivamente con lo stesso canale autorizzato (`test -f databases/akai_memory.db-wal`). Se presente (`EXISTS`), l'estrazione del file WAL via `Receive-FileViaAdbExecOut` è categoricamente vincolante: qualsiasi fallimento solleva eccezione `FAIL-CLOSED` immediata. Se assente (`NOT_FOUND`), l'assenza controllabile viene esplicitamente registrata a log;
   - **Checkpoint Categorico TRUNCATE**: In `Verify-SQLiteIntegrityOffline`, l'invocazione di `PRAGMA wal_checkpoint(TRUNCATE)` verifica categoricamente la tupla risultante esigendo `busy === 0`. Qualsiasi eccezione o stato occupato (`busy > 0`) scatena un arresto bloccante immediato (`exit 3 -> throw FAIL-CLOSED`). Il superamento di `PRAGMA integrity_check` non può in alcun caso mascherare un checkpoint fallito o incompleto;
   - **Consolidamento Bit-for-Bit**: Post-checkpoint, la procedura verifica che il file WAL sia effettivamente troncato a 0 byte e rimuove i file ausiliari `-wal` e `-shm`, ottenendo un file `.db` autonomo, consistente e verificato al 100% prima del calcolo dell'hash SHA-256.
6. **Indivisibilità del Rollback e Prerequisiti Bloccanti (P0-2)**:
   Sia nel rollback automatico scatenato dal watchdog (30s) sia nel rollback manuale, è tassativamente vietato effettuare il downgrade dell'APK se il file di backup del database SQLite v5 non è presente, integro o leggibile:
   - Poiché la baseline v5 non possiede `onDowngrade()` e lancia eccezione irreversibile se avviata su schema v6, un downgrade del solo APK causerebbe il crash permanente del server;
   - La presenza del backup APK, del file `akai_memory.db` originale (>= 512 byte), dell'hash SHA-256 e dell'esito positivo di `Verify-SQLiteIntegrityOffline` è validata **prima di invocare `adb install`**;
   - In assenza di tali prerequisiti, la procedura solleva eccezione `FAIL-CLOSED` immediata con codice di uscita non-zero, senza eseguire alcuna reinstallazione né emettere falsi messaggi di ripristino riuscito (anche se `/api/status` dovesse rispondere positivamente).
7. **Risoluzione Rigorosa Identità Numerica Linux UID (P1 - Zero Fallback Arbitrari)**:
   In caso di ripristino via root (`su`), lo script risolve dinamicamente l'identità numerica dell'applicazione (`userId` o `appId`) interrogando `dumpsys package <PackageName>` o `stat -c "%u" /data/data/<PackageName>`. Se la risoluzione non restituisce un valore strettamente numerico verificato, la procedura **solleva immediatamente eccezione `FAIL-CLOSED`**. È categoricamente vietato applicare permessi con UID arbitrari o fittizi (es. `10000:10000`).
8. **Watchdog Post-Rollback Deterministic Exit (P1)**:
   I controlli di salute post-rollback eseguono un ciclo di verifica attivo: se l'endpoint `/api/status` non risponde con `status=ok`, la procedura dichiara esplicitamente lo stato `FAIL/UNKNOWN` e termina con eccezione bloccante ed exit code 1.
9. **Suite di Test Offline Rigorosa (19/19 PASS)**:
   La suite offline PowerShell `test_safe_install_mocked_adb.ps1` copre 19 scenari formali:
   - Test 1-6, 9, 12, 13, 14, 16, 17, 18, 19: Test negativi e fail-closed categorici (inclusi Test 13: estrazione WAL fallita se presente, Test 14: checkpoint WAL bloccato con lettore concorrente `busy=1`, Test 16: writer non quiescente con PID attivo, Test 17: residui WAL/SHM non rimossi su storage pre-restore, Test 18: errore di trasporto ADB / assenza stdout durante la verifica della quiescenza, e Test 19: probe WAL/SHM fallito su entrambi i canali `run-as` e `su` con blocco categorico senza streaming restore);
   - Test 7-8: Test affermativi end-to-end con mock ADB (ciclo completo upgrade e rollback con streaming e parità hash);
   - Test 10-11: Regressioni baseline v5 e consistenza transazionale WAL;
   - Test 15: Verifica isolata del percorso `sqlite3` CLI (4 condizioni: successo 0+ok, exit non-zero, corruzione, checkpoint busy).
10. **Correzione Predicato SQLite CLI e Verifica Isolata Backend CLI (P0 - Revisione 11)**:
    Corretto il typo invertito nella verifica con sqlite3 CLI (`$LASTEXITCODE -eq 0 -and $out.Trim() -eq "ok"`). Aggiunto Test 15 isolato con 4 condizioni formali che validano il comportamento corretto e fail-closed in isolamento.
11. **Prova Attiva di Quiescenza Writer e Rimozione Verificata File Orfani `-wal`/`-shm` (P1 - Revisione 11)**:
    - **Quiescenza Forzata e Verificata**: Implementato helper `Ensure-ApplicationQuiescence` (`am force-stop`, controllo attivo `pidof`, `kill -9` di recupero, e riverifica `pidof`). Se il processo writer continua a girare, l'estrazione viene categoricamente interrotta in `FAIL-CLOSED` per prevenire snapshot incoerenti (Test 16).
    - **Pulizia Verificata Residui WAL/SHM**: Implementato helper `Remove-OrphanedWalAndShmFiles` invocato prima del ripristino del DB in fase di rollback.
12. **Probing Attivo Tri-State dei File su Storage Device (P0 - Revisione 12)**:
    - **Eliminazione Radicale del Fail-Open**: Nei controlli di esistenza dei file remoti (`databases/akai_memory.db-wal` e `databases/akai_memory.db-shm`), l'assenza di output o il fallimento del trasporto non viene in nessun caso interpretato come `NOT_FOUND`.
    - **Helper Universale `Probe-DeviceFileState`**: Esegue comandi con marcatore esplicito (`FILE_PROBE_RESULT:EXISTS` o `FILE_PROBE_RESULT:NOT_FOUND`). Lo stato `NOT_FOUND` viene accettato **esclusivamente se il comando di probe restituisce exit code 0 e marcatore valido**.
    - **Gestione Multi-Canale con Fallback**: Tenta prioritariamente `run-as`; se fallisce (es. release non-debuggable), tenta il fallback via `su`. Se entrambi i canali falliscono o restituiscono output non valido/errore, solleva immediatamente eccezione bloccante `ERRORE FAIL-CLOSED`, arrestando categoricamente il rollback prima di qualunque tentativo di ripristino o streaming del database (validato al 100% dal Test 19).
13. **Verifica Quiescenza con Marcatore Shell Univoco per Errori ADB/Trasporto (P1 - Revisione 12)**:
    - **Helper `Get-ApplicationProcessState`**: Per evitare che errori di trasporto ADB o permessi negati vengano confusi con l'assenza di processi (poiché `pidof` esce con codice 1 quando nessun processo è attivo), il comando shell viene racchiuso in una sequenza con marcatore formattato: `pids=$(pidof $PackageName 2>/dev/null); code=$?; echo PIDOF_CHECK:pids=[$pids]:exit=[$code]`.
    - **Verifica Congiunta Exit Code ed Output**: Il comando `echo` garantisce exit code 0 dal lato shell in caso di funzionamento normale. Se ADB restituisce un codice diverso da 0 o se l'output stdout è vuoto o privo del marcatore formattato atteso, la procedura solleva immediatamente eccezione `ERRORE FAIL-CLOSED` prima di procedere all'estrazione del database (validato al 100% dal Test 18).
    - **Limiti Reali TV Fisica**: Si ribadisce formalmente che su dispositivo fisico AKAI Android TV non-debuggable (`android:debuggable="false"`), l'accesso ai file privati di `/data/data/it.akai.customremote/` per la baseline v5 richiede inderogabilmente privilegi di root (`su`). In assenza di tali privilegi verificati a runtime, la procedura scatta immediatamente nel pre-flight gate di sicurezza e rifiuta categoricamente l'installazione.
