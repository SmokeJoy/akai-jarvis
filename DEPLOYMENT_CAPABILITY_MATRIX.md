# AKAI JARVIS - Deployment & Rollback Capability Matrix

## 1. Obiettivo del Documento
Questo documento definisce in modo formale e verificabile la matrice delle capacità e dei vincoli architetturali dell'applicazione **AKAI Custom Remote** (`it.akai.customremote`), confrontando la **baseline legacy attualmente installata (v5)** con la **versione candidata (v6 / PR #1)**.

L'obiettivo è chiarire cosa l'APK legacy è in grado di eseguire, cosa NON può eseguire, e quale strategia operativa garantisce la conservazione dei dati e la recuperabilità del dispositivo televisivo senza fare affidamento su scorciatoie non dimostrate o privilegi inesistenti.

---

## 2. Analisi Comparativa delle Capacità Architetturali

| Componente / Caratteristica | Baseline Esistente Installata (v5 - commit `ea2f35e`) | Versione Candidata (v6 - branch `fix/pr01-...`) | Vincolo Architetturale e Impatto Operativo |
|---|---|---|---|
| **Package Name** | `it.akai.customremote` | `it.akai.customremote` | Identico. Gli aggiornamenti avvengono in-place preservando `/data/data/it.akai.customremote`. |
| **Target SDK / Min SDK** | Target SDK 28 (Android 9 Pie), Min SDK 21 | Target SDK 28 (Android 9 Pie), Min SDK 21 | Identico. Compatibilità runtime nativa con Android TV 9. |
| **`android:allowBackup`** | `false` | `false` | `adb backup` è **categoricamente disabilitato** a livello di sistema operativo Android. |
| **`android:debuggable`** | Non dichiarato (default: `false` per release) | Non dichiarato (default: `false` per release) | `run-as it.akai.customremote` è negato dal binario AOSP `run-as` in profili di release standard. |
| **Componenti Exported** | `MainActivity` (`exported=true`)<br>`PinActivity` (`exported=true`)<br>`AkaiAccessibilityService` (`exported=true`, bind permission)<br>`BootReceiver` (`exported=true`) | `MainActivity` (`exported=true`)<br>`PinActivity` (`exported=true`)<br>`AkaiAccessibilityService` (`exported=true`)<br>`BootReceiver` (`exported=true`) | Solo le Activity e i Receiver dichiarati esportati possono ricevere intent da UID shell non privilegiati. |
| **`RemoteServerService` Exported** | `android:exported="false"` | `android:exported="false"` | Il servizio demone NON è esportato. In Android standard, comandi `am startservice` da UID diversi o shell unprivileged sono limitati o respinti. |
| **Handler Intent `onStartCommand()`** | Esegue **unicamente** `ensureServerRunning()`. Ignora qualsiasi Action passata nell'Intent. | Supporta `ACTION_BACKUP_DB` e `ACTION_RESTORE_DB` invocando metodi interni con il proprio UID. | **DISCRIMINANTE FONDAMENTALE**: La baseline v5 **NON possiede** `ACTION_BACKUP_DB` né `ACTION_RESTORE_DB`. Inviare questi intent all'APK v5 prima dell'aggiornamento è un'operazione priva di effetto. |
| **Versione Schema SQLite** | `DB_VERSION = 5` | `DB_VERSION = 6` | Upgrade automatico gestito via `onUpgrade(5, 6)`. |
| **Override `onDowngrade()`** | **ASSENTE** (implementazione predefinita Android framework: lancia `SQLiteException`) | Implementato (`onDowngrade()` logga e preserva schema senza eccezioni distruttive). | **CRITICITÀ ROLLBACK**: Se l'APK v6 porta il DB a versione 6, l'APK v5 nativo reinstallato crasha immediatamente all'apertura del DB (`user_version = 6 > 5`). |
| **Snapshot Consistente SQLite** | Assente nel codice Java. | Implementato (`performConsistentSnapshot` con `PRAGMA wal_checkpoint(TRUNCATE)` verificato con codice `0` ed integrity check). | La creazione di snapshot interni consistenti è una capacità nativa di v6+. |
| **Ripristino Consistente SQLite** | Assente nel codice Java. | Implementato (`restoreConsistentSnapshot` con pulizia file `-wal`/`-shm` e `PRAGMA integrity_check`). | Il ripristino guidato dall'interno dell'app è una capacità nativa di v6+. |
| **Export Logico REST HTTP** | Presente: `GET /api/ai/memory` restituisce JSON autenticato con procedure, preferenze, statistiche e cronologia conversazioni. | Presente e arricchito con filtri Guest Mode e boundary sicuri (9/9 campi JSON). | **CANALE DI RECUPERO BASELINE**: L'unico canale applicativo ufficiale offerto dalla baseline v5 per estrarre i dati prima dell'aggiornamento è l'API REST autenticata su porta 8088. |

---

## 3. Analisi del Ciclo di Vita dei Dati in Caso di Aggiornamento e Rollback

```
+-----------------------------------------------------------------------------------+
|                           FASE 1: STATO BASELINE (v5)                             |
|                                                                                   |
|  - App: v5 (no intent backup, allowBackup=false, RemoteServerService unexported)  |
|  - DB: /data/data/it.akai.customremote/databases/akai_memory.db (user_version = 5)|
|  - Rete: Server HTTP porta 8088 attivo (disponibile GET /api/ai/memory)          |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                        FASE 2: STRATEGIA PRE-UPGRADE                              |
|                                                                                   |
|  1. Se HTTP attivo: Backup logico REST (GET /api/ai/memory -> memory_backup.json)|
|  2. Se accesso shell adb diretto/privilegiato disponibile:                       |
|     Snapshot binario akai_memory.db -> sessione backup offline                   |
|  3. Se nessun canale di backup è utilizzabile:                                    |
|     BLOCCO FAIL-CLOSED IMMEDIATO (Nessuna installazione autorizzata)             |
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
|  - DB v6 consistente e funzionante     | |  2. Gestione DB per APK v5:            |
|  - Nuove funzioni di backup/restore    | |     a) Se presente snapshot v5:         |
|    native operative per il futuro      | |        ripristino file binario v5      |
|                                        | |     b) Se presente solo backup logico: |
|                                        | |        pulizia DB v6 e re-seed v5      |
|                                        | |  3. Watchdog post-rollback operativo   |
+----------------------------------------+ +----------------------------------------+
```

---

## 4. Requisiti di Sicurezza e Correzioni Applicate

1. **Riconoscimento del Vincolo Baseline v5**:
   Lo script `05_safe_install_and_rollback.ps1` NON assume che l'APK attualmente installato possieda `ACTION_BACKUP_DB`. Prima dell'installazione, tenta il recupero logico REST autenticato da `/api/ai/memory` oltre al dump binario se consentito dai permessi del device. Se nessun backup integro è ottenibile, l'installazione viene interrotta categoricamente (**Fail-Closed**).
2. **Rigorosità del Checkpoint WAL in `AkaiMemoryEngine`**:
   Il metodo `performConsistentSnapshot()` verifica esplicitamente che il valore restituito da `PRAGMA wal_checkpoint(TRUNCATE)` sia `0` (busy=0). Se il checkpoint restituisce `busy` o fallisce, o se la copia non supera l'integrity check, l'operazione restituisce `false` (Fail-Closed).
3. **Compatibilità Multipiattaforma PowerShell 7 (`pwsh`)**:
   Eliminato qualsiasi uso di `Get-Content -Encoding Byte` (deprecato e non supportato in pwsh 7). Lo streaming di byte per stdin e file binari viene eseguito tramite flussi nativi .NET `[System.IO.File]::ReadAllBytes` e `Process.StandardInput`, garantendo parità tra Windows PowerShell 5.1 e Linux/macOS PowerShell 7+.
4. **Risoluzione Percorsi File Intent**:
   In `RemoteServerService.java`, gli handler di backup e restore risolvono correttamente percorsi relativi rispetto a `getFilesDir()`.
5. **Verifica Negativa vs Verifica Affermativa**:
   I test di collaudo sono divisi rigorosamente tra **Test Negativi (Fail-Closed)** (che dimostrano il blocco in presenza di anomalie, permessi negati o parametri mancanti) e **Test E2E Affermativi (Success Path)** (che dimostrano l'esecuzione corretta e la parità di hash in condizioni operative normalizzate).
