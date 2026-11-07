# AKAI JARVIS — Documentazione Tecnica dell'Architettura Completa v16

**Target Hardware:** Smart TV AKAI AKTV5037N 50" UHD 4K (`m7332_eu`)  
**SoC:** MediaTek MT9632 (Quad-core ARM Cortex-A53, Mali-G52 GPU, architettura 32-bit `armeabi-v7a`)  
**Sistema Operativo:** Android TV 9.0 Pie (API 28), Kernel Linux 4.19  
**Memoria:** 1.5 GB RAM (1.331 MB allocati, ~380 MB liberi per utenti, zRAM swap 499 MB)  
**Storage:** 8 GB eMMC (~4.2 GB partizione `/data`)  
**Data del Report:** 7 novembre 2026 — Rilascio v16 (Freeze per Audit Esterno)

---

## 1. Schema Generale e Flusso di Esecuzione Reale

L'intero sistema opera senza PC acceso e senza dipendere dal server ADB (porta 5555 disattivabile). L'assistente e il telecomando risiedono all'interno dell'applicazione Android `it.akai.customremote`, mentre lo smartphone dell'utente funge da console e microfono tramite browser (Safari su iOS o Chrome su Android) attraverso HTTPS su porta 8443 o HTTP su porta 8088.

```
       ┌─────────────────────────────────────────────────────────────┐
       │               SMARTPHONE UTENTE (iOS / Android)             │
       │                                                             │
       │  • Safari iOS / Chrome Android (PWA Web Remote v16)         │
       │  • Web Speech API (Lingua italiana `it-IT`)                 │
       │  • Voice Activity Detection (VAD a 1400 ms)                 │
       │  • Turn Locking atomico anti-duplicazione                   │
       └──────────────────────────────┬──────────────────────────────┘
                                      │
            Richiesta HTTPS 8443 / HTTP 8088 (JSON UTF-8 binario)
            Header Authorization: Bearer <token_256bit>
                                      │
                                      ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                    SMART TV AKAI (it.akai.customremote)                    │
│                                                                            │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ 1. Demone di Rete (RemoteServerService.java)                         │  │
│  │    • Foreground Service con notifica persistente                     │  │
│  │    • Thread Acceptor dedicati (AkaiHttpAcceptor + AkaiHttpsAcceptor) │  │
│  │    • Pool di 12 worker thread per elaborazione concorrente           │  │
│  │    • Parser binario HTTP a byte (limite 64 KB, UTF-8 post-read)     │  │
│  └──────────────────────────────────┬───────────────────────────────────┘  │
│                                     │                                      │
│  ┌──────────────────────────────────▼───────────────────────────────────┐  │
│  │ 2. Sicurezza & Controllo Accessi (SecurityManager.java)              │  │
│  │    • Filtro IP su subnet private RFC 1918 (192.168.1.0/24)           │  │
│  │    • Rate Limiting anti-brute force (blocco 5 min su 3 errori PIN)   │  │
│  │    • Bearer Token crittografici 256-bit con rinnovo sliding window   │  │
│  │    • Protezione replay attack (timestamp ±30s + cache nonce)         │  │
│  └──────────────────────────────────┬───────────────────────────────────┘  │
│                                     │                                      │
│  ┌──────────────────────────────────▼───────────────────────────────────┐  │
│  │ 3. Analisi Linguistica Locale (LocalIntentParser.java)               │  │
│  │    • Normalizzazione Unicode NFD (\p{InCombiningDiacriticalMarks}+)  │  │
│  │    • Riconoscimento immediato comandi hardware TV (0 Token, <10 ms)  │  │
│  │    • Ricerca semantica memorie procedurali nel database SQLite       │  │
│  └───────────────┬───────────────────────────────────┬──────────────────┘  │
│                  │                                   │                     │
│      [Se comando primitivo / procedura]   [Se richiesta aperta / dialogo]  │
│                  │                                   │                     │
│                  ▼                                   ▼                     │
│  ┌───────────────────────────────┐   ┌──────────────────────────────────┐  │
│  │ 4A. Esecutore TV & Driver     │   │ 4B. Adapter Cloud AI             │  │
│  │     (TvController.java)       │   │     (AiProviderAdapter.java)     │  │
│  │  • Driver JNI Linux uinput    │   │  • DeepSeek (deepseek-flash)     │  │
│  │    (/dev/uinput nativo C)     │   │  • Moonshot Kimi (kimi-k2.6)     │  │
│  │  • Iniezione tasti EV_KEY     │   │  • Budget Guard atomico: tetto   │  │
│  │  • Sintonizzazione canali DTV │   │    rigido 5,00 € max condivisi   │  │
│  │  • Sequenze step-by-step con  │   │  • Chiavi API in TrustZone       │  │
│  │    interruzione su errore     │   │    (Android Keystore hardware)   │  │
│  └───────────────┬───────────────┘   └───────────────┬──────────────────┘  │
│                  │                                   │                     │
│                  └─────────────────┬─────────────────┘                     │
│                                    │                                       │
│  ┌─────────────────────────────────▼────────────────────────────────────┐  │
│  │ 5. Percezione e Verifica a Schermo (ScreenPerceptionEngine.java)     │  │
│  │    • AccessibilityService per lettura ad albero UI a schermo         │  │
│  │    • Distinzione semantica: SUCCESS_VERIFIED vs COMPLETED_UNVERIFIED │  │
│  │    • Riconoscimento dialoghi: status ANSWERED_DIALOG                 │  │
│  └─────────────────────────────────┬────────────────────────────────────┘  │
│                                    │                                       │
│  ┌─────────────────────────────────▼────────────────────────────────────┐  │
│  │ 6. Memoria Residente On-TV (AkaiMemoryEngine.java - SQLite v5)       │  │
│  │    • Tabella `procedural_memory` (sequenze apprese con successo reale)│  │
│  │    • Tabella `conversations` (cronologia turni con costo e token)    │  │
│  │    • Tabella `user_preferences` (canali, generi e app favorite)      │  │
│  │    • Limite rigido allocazione: massimo 15 MB su disco (LRU)         │  │
│  │    • Modalità Ospite: non memorizza conversazioni private            │  │
│  └─────────────────────────────────┬────────────────────────────────────┘  │
│                                    │                                       │
│  ┌─────────────────────────────────▼────────────────────────────────────┐  │
│  │ 7. Motore Vocale & Audio (AkaiSpeechEngine.java)                     │  │
│  │    • Audio Focus Ducking API 26+ (abbassamento programma TV)         │  │
│  │    • Client REST Azure Speech F0 (voci Diego e Isabella Neurali)     │  │
│  │    • Fallback offline locale (eSpeak NG su TV)                       │  │
│  │    • Riproduzione nativa MediaPlayer su stream MUSIC                 │  │
│  │    • Notifica speech_state (IDLE, FETCHING, PLAYING) al telefono     │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Dettaglio dei Componenti e Mappatura File

### 2.1 Demone di Rete e Server HTTP/HTTPS
- **File:** [`RemoteServerService.java`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/akai-remote-tv/app/src/main/java/it/akai/customremote/RemoteServerService.java)
- **Porte:** HTTP `8088`, HTTPS `8443` (TLS 1.2/1.3 con `server_keystore.p12`).
- **Architettura Concorrenza:**
  - I socket listener operano su thread indipendenti (`AkaiHttpAcceptor` e `AkaiHttpsAcceptor`).
  - Il dispatch delle richieste avviene tramite un `ThreadPoolExecutor` bounded a 12 worker thread con coda `LinkedBlockingQueue` (50 item) e policy `AbortPolicy`.
  - Connessione client con `setSoTimeout(10000)` (10 secondi).
- **Parser HTTP a Byte (Risoluzione P0-01):**
  - Legge gli header HTTP fino alla sequenza `\r\n\r\n` con limite rigido di 8 KB (restituisce HTTP 431 `Request Header Fields Too Large` se superato).
  - Estrae `Content-Length`.
  - Se `Content-Length > 65536` (64 KB), restituisce HTTP 413 `Payload Too Large`.
  - Legge esattamente `Content-Length` byte dal flusso binario grezzo dell'`InputStream`.
  - Converte i byte letti in stringa UTF-8 solo a lettura completata. Nessun blocco di socket su caratteri multibyte o lettere accentate.
- **Autenticazione Endpoint Sensibili (Risoluzione P0-05):**
  - Tutti gli endpoint `/api/command`, `/api/ai/*` e `/api/diagnostics` richiedono obbligatoriamente l'header `Authorization: Bearer <token_256bit>` valido.
  - Se il token è assente, errato o scaduto, viene restituito HTTP 401 `{"error":"Non autorizzato"}`.
  - `AndroidManifest.xml` dichiara `android:allowBackup="false"`.

### 2.2 Driver di Controllo Hardware TV
- **File:** [`TvController.java`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/akai-remote-tv/app/src/main/java/it/akai/customremote/TvController.java), [`uinput_jni.c`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/akai-remote-tv/app/src/main/jni/uinput_jni.c)
- **Meccanismo di Iniezione:**
  - Driver C nativo compilato con Clang NDK per `armeabi-v7a` (`libakai_uinput.so`).
  - Apre `/dev/uinput`, registra `UI_SET_EVBIT`, `UI_SET_KEYBIT` ed emette eventi `input_event` con `SYN_REPORT`.
  - Emula tutti i tasti hardware TV: accensione/standby, Home, Back, Menu, D-Pad (Up, Down, Left, Right, OK), Volume (+, -, Mute), Canale (+, -, Prev) e tastierino 0-9.
- **Sequenze di Azioni con Interruzione su Errore (Risoluzione P0-02):**
  - `executeActionSequence` itera un massimo di 15 step.
  - Verifica il `CommandResult` restituito da ciascun passo (`launch_app`, `command`, `set_volume`, `tune_channel`, `click_accessibility_node`).
  - Se un passo restituisce `success = false`, il ciclo si interrompe immediatamente e restituisce `CommandResult(false, "Fallito al passo X: ...")`. Nessun falso successo può essere salvato o notificato all'utente.

### 2.3 Memoria Residente On-TV (SQLite Schema v5)
- **File:** [`AkaiMemoryEngine.java`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/akai-remote-tv/app/src/main/java/it/akai/customremote/ai/AkaiMemoryEngine.java)
- **Struttura Tabelle:**
  1. `procedural_memory`: `intent_key`, `goal_intent`, `description`, `app_package`, `initial_state`, `action_sequence`, `success_condition`, `success_count`, `failure_count`, `last_used`, `last_verified`, `created_at`.
     - *Risoluzione P0-03:* I template predefiniti vengono inseriti con `success_count = 0` e `last_verified = 0`. La macro fittizia "Italia 2 con 11 pressioni a destra" è stata rimossa.
     - *Risoluzione P1-08:* `resetProcedures()` azzera ESCLUSIVAMENTE la tabella `procedural_memory`, lasciando intatte preferenze, cronologia e statistiche.
  2. `user_preferences`: `pref_key`, `pref_val`, `category`, `is_personal`, `enabled`, `updated_at`.
  3. `conversations`: `id`, `timestamp`, `user_query`, `assistant_reply`, `status`, `intent_key`, `tokens`, `cost_eur`.
     - *Risoluzione P1-07:* Se `guest_mode == true`, il record non viene persistito.
     - `clearPersonalPreferencesOnly()` cancella tutti i record di questa tabella e le preferenze con `is_personal = 1`.
  4. `usage_stats`: contatori `local_executions_zero_token`, `cloud_ai_calls`, `prompt_tokens`, `completion_tokens`.
- **Limiti di Memoria:**
  - Controllo `PRAGMA page_count` e `PRAGMA page_size`.
  - Tetto massimo fissato a 15 MB. Se la dimensione supera il 90% (13.5 MB), scatta la pulizia LRU automatica dei record più vecchi.

### 2.4 Motore di Sintesi Vocale e Gestione AudioFocus
- **File:** [`AkaiSpeechEngine.java`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/akai-remote-tv/app/src/main/java/it/akai/customremote/ai/AkaiSpeechEngine.java), [`CloudSpeechAdapter.java`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/akai-remote-tv/app/src/main/java/it/akai/customremote/ai/CloudSpeechAdapter.java)
- **Gestione AudioFocus (Risoluzione P1-10):**
  - Su Android 9 (API 28), acquisisce il focus con `AudioFocusRequest.Builder(AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)` su stream `STREAM_MUSIC`.
  - La TV abbassa il volume dell'emittente TV in riproduzione durante il parlato dell'assistente.
  - Al termine della riproduzione o su errore/stop, chiama `mAudioManager.abandonAudioFocusRequest(mPlaybackFocusRequest)`.
- **Ciclo di Vita Audio e Cache (Risoluzione P1-03, P1-09):**
  - Macchina a stati TTS: `mSpeechState` traccia atomica `IDLE`, `FETCHING` (download SSML in corso), `PLAYING` (MediaPlayer in riproduzione).
  - L'endpoint `/api/ai/speech_status` restituisce `speech_state`, `speech_id` e `speaking`.
  - I file temporanei generati per risposte uniche (`tts_tmp_...mp3`) vengono eliminati immediatamente dopo la riproduzione.
  - La cache disco (8 MB) protegge il file attualmente in riproduzione (`mCurrentlyPlayingFile`) dall'eviction LRU.

### 2.5 Adapter Cloud AI & Budget Guard
- **File:** [`AiProviderAdapter.java`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/akai-remote-tv/app/src/main/java/it/akai/customremote/ai/AiProviderAdapter.java)
- **Modelli Supportati:**
  - Predefinito: `deepseek-flash` (supporta tool calling, visione, economico).
  - Ragionamento / Pro: `deepseek-v4-pro`, `deepseek-reasoner` (R1).
  - Kimi: `kimi-k2.6` (Moonshot flagship), `moonshot-v1-8k`, `moonshot-v1-32k`.
- **Budget Guard Condiviso (5,00 € Max):**
  - Tetto massimo rigido condiviso di 5,00 € memorizzato in TrustZone / Preferences.
  - Stima preventiva del costo per ogni chiamata cloud basata su lunghezza prompt e modello.
  - Blocco preventivo atomico prima dell'invio HTTP: se il budget residuo è inferiore alla stima o inferiore a 0,005 €, la chiamata cloud viene rifiutata restituendo `status = "BUDGET_EXCEEDED"`.
  - Livelli di allerta UI: Avviso a 3,00 €, Critico a 4,00 €, Blocco a 5,00 €.

### 2.6 Console Web Telecomando PWA v16
- **File:** [`index.html`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/akai-remote-web/index.html), [`style.css`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/akai-remote-web/style.css), [`app.js`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/akai-remote-web/app.js), [`sw.js`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/akai-remote-web/sw.js)
- **Architettura a 3 Sezioni (Risoluzione P2-04):**
  - `Assistente`: Voice Orb accessibile, trascrizione real-time, box esito con badge di accuratezza, tasto Stop immediato, chip comandi istantanei a 0 token.
  - `Telecomando`: D-Pad ergonomico circolare (265px) con tasti touch ≥44px, Home, Indietro, Menu, bilancieri Volume e Canale con Mute e Prev, selettore sorgenti e scorciatoie app.
  - `Attività`: Statistiche rapide (0 token, cloud calls, spesa), feed cronologia da SQLite TV, memorie procedurali e controlli privacy.
  - `Impostazioni`: Modal separato per non ingombrare l'uso quotidiano.
- **Risoluzione Bug Vocali Frontend:**
  - *P1-02:* Turn locking con `turnLocked` atomico in `commitTurn` per evitare doppie submission tra `final`, `interim` e `onend`.
  - *P1-03:* Polling intelligente di `/api/ai/speech_status`: attende che la TV passi a `FETCHING`/`PLAYING` e poi torni a `IDLE` prima di riaprire il microfono, evitando interferenze acustiche.
  - *P1-04:* `AbortController` con timeout di 25 secondi e cancellazione immediata al tocco di Stop.
  - *P1-05 & P1-16:* Distinzione chiara tra `✓ Verificato`, `⚠️ Eseguito (Non Verificato)`, `💬 Risposta` e `❌ Errore` con tasto Riprova.
  - *P2-01:* Service worker PWA v16 con strategia Network-First e fallback cache.
  - *P2-02 & P2-03:* Voice Orb come `<button type="button">`, conformità WCAG 2.1 AA, touch targets ≥44px, Safe-Area insets per iPhone (notch/home bar).

---

## 3. Matrice Funzionalità: Implementate vs Progettate

| Componente / Funzionalità | Stato Reale | Dettagli Implementativi |
| :--- | :--- | :--- |
| **Foreground Service Residente** | **100% OPERATIVO** | Demone attivo in background con notifica permanente, sopravvive a standby TV |
| **Server HTTP (8088)** | **100% OPERATIVO** | Thread pool 12 worker, parser binario a byte UTF-8 esatto |
| **Server HTTPS (8443)** | **100% OPERATIVO** | TLS 1.2/1.3, certificato per IP locale, contesto sicuro per microfono |
| **Driver uinput C Nativo** | **100% OPERATIVO** | Iniezione tasti hardware a livello kernel Linux `/dev/uinput` senza ADB |
| **Database SQLite v5** | **100% OPERATIVO** | Tabelle memorie, preferenze, conversazioni, statistiche; tetto 15 MB |
| **Normalizzazione Linguistica NFD** | **100% OPERATIVO** | Rimozione mirata diacritici (`più forte` -> `piu forte`) con 0 Token |
| **Budget Guard 5,00 €** | **100% OPERATIVO** | Blocco preventivo atomico prima dell'invio HTTP |
| **Sintesi Neurale Azure Speech F0** | **100% OPERATIVO** | Client REST SSML, voci Diego/Isabella, MediaPlayer con AudioFocus ducking |
| **Sintesi Offline Locale** | **100% OPERATIVO** | Engine eSpeak NG preinstallato su TV come fallback a connettività assente |
| **Web Remote UI v16 a 3 Sezioni** | **100% OPERATIVO** | Layout Assistente, Telecomando, Attività con PWA network-first |
| **Verifica Semantica Risultato** | **100% OPERATIVO** | Distingue `SUCCESS_VERIFIED`, `COMPLETED_UNVERIFIED`, `ANSWERED_DIALOG` |
| **Esplorazione Autonoma OODA Continua** | **PROGETTATA (NON IMPL.)** | L'assistente esegue macro con verifica finale; non esegue navigazione visiva frame-by-frame a ogni click |
| **Discovery mDNS / Zeroconf Automatico** | **PROGETTATA (NON IMPL.)** | La connessione usa IP configurabile (default `192.168.1.8`); mDNS non attivo |

---

## 4. Specifiche di Compilazione e Riproducibilità

- **Comando Compilazione APK:**
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\scripts\08_compile_akai_remote_apk.ps1
  ```
- **Firma APK:**
  - Firma v1 (JAR Signature) + Firma v2 (Full APK Signature Scheme v2).
  - Compatibilità verificata con Android TV 9.0 (API 28).
- **Test Unitari Host (Zero Dipendenze Esterne):**
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\akai-remote-tests\run_unit_tests.ps1
  ```
  - **Esito:** 12 / 12 Test Superati (100% PASS).
