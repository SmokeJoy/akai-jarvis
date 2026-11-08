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
