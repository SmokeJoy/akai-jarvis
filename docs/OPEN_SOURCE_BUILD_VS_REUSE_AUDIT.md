# AKAI JARVIS — Audit Build-vs-Reuse Open Source e Roadmap di Accelerazione

**Repository:** `SmokeJoy/akai-jarvis` (`fix/pr01-endpoints-remote-activity`)  
**Baseline verificata:** commit `4fbf370894c8401f12afdf749ed0a3bbcad7d4e2` (`4fbf370`) — CI verde su `pull_request` ([run 43617440209](https://github.com/SmokeJoy/akai-jarvis/actions/runs/43617440209)) e `push` ([run 43617433825](https://github.com/SmokeJoy/akai-jarvis/actions/runs/43617433825)): Java `34/34`, Python SQLite/rollback `7/7` + `6/6`, PowerShell mocked ADB `29/29`  
**Riferimenti PR #1:** `#issuecomment-6880609252` (chiusura P0 TLS X.509), `#issuecomment-6880750275` (direttiva audit Build-vs-Reuse)

---

## 1. Sintesi Esecutiva

Con il commit `4fbf370` la verifica crittografica completa della catena X.509 (`Read-Asn1DerTlv`, `Test-X509CertificateSignature`, `Test-HttpsTlsEndpoint` e subtest `26b`/`28b`) è chiusa e validata in CI. Il codice di **JARVIS v6** è quindi pronto per le verifiche finali sulla TV reale (`192.168.1.101`, previo sblocco esplicito del freeze hardware): backup integrale SQLite v5 + WAL via `adb root` -> backup -> `adb unroot`, preflight reale e beta test da Safari iPhone su HTTPS `8443` a PC spento.

Questo documento analizza i candidati open source selezionati per accelerare **JARVIS** senza frammentarlo e senza introdurre dipendenze pesanti, rischi di sicurezza o regressioni sulla baseline attuale.

### Invarianti Architetturali Non Negoziabili
1. **Unica app JARVIS on-device**: mantenere integro il server HTTPS sulla porta `8443` con CA locale pinning (`TlsCertificateManager.java`, `AKAI Jarvis Local CA`), il driver nativo virtuale `/dev/uinput` (`0666`, `libakai_uinput.so`) e la memoria SQLite on-device con cap a **15 MB** (`procedures`, `success_count`, `fail_count`).
2. **Zero modifiche a Home v8 e tasto MENU**: `it.akai.customhome.v8` (vc11) resta completamente intoccata.
3. **Target hardware reale**: Android 9 (`userdebug`), ABI **32-bit ARMv7 (`armeabi-v7a`)**, RAM di sistema totale **~1.4 GB**, toolchain CI pura (`javac` + Android SDK `d8` / `aapt2` / `zipalign` / `apksigner` senza Gradle runtime bloat).
4. **Sicurezza prima di tutto**: nessun server HTTP in chiaro (`8080`), nessun loopback ADB TCP (`5555`), nessuna modifica autonoma di firmware/root, nessuna invocazione di LLM pesanti in locale su ARMv7 né invio di credenziali/schermate protette (`hasSensitiveFields` in `ScreenPerceptionEngine.java`).

---

## 2. Matrice Comparativa Candidati Open Source (8 Dimensioni)

> Le coppie con ruolo complementare/omogeneo (`vosk-api` + `vosk-android-demo`; `mobile-mcp` + `mobilerun`) sono valutate chiaramente entro 6 righe per confrontarne costi reali e confini operativi.

| Candidato | Funzione JARVIS già presente | Codice / pattern realmente riusabile | Licenza & obblighi | `minSdk` & ABI `armeabi-v7a` | RAM & footprint (`~1.4 GB` TV) | Sicurezza & conflitti IP/porte | Costo integrazione vs sviluppo & Decisione |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **1. `maxhayim/webmote`**<br>(Java puro, zero runtime deps in `app/build.gradle`) | Server Web + telecomando HTTPS `8443` + `TvController` + `AkaiAccessibilityService` + elenco app noto (`TvAppPackages`) | Bugfix Accessibility Android 9-12 in `RemoteService.java`: `View.FOCUS_UP/DOWN/LEFT/RIGHT`, `firstFocusable()`, loop `getParent().isClickable()`, fallback `ACTION_SCROLL_FORWARD/BACKWARD`, `getLeanbackLaunchIntentForPackage()`, deep-link YouTube TV `SEARCH_LINKS`, fallback `volume()`, discovery `Nsd.java` (`NsdManager` + `NetworkCallback`), query `CATEGORY_LEANBACK_LAUNCHER` in `Apps.java` | **MIT** (compatibile; preservare copyright e testo MIT nei file derivati/note) | `minSdk 28` (coincide con Android 9 TV); **Java puro**, nessuna lib nativa -> compatibile al 100% con `armeabi-v7a` e pipeline `javac`+`d8` | Bassissimo (~few MB); ridurre eventuale `LruCache` banner di `Apps.java` da `4 MB` a `1 MB` | Usa HTTP plaintext **`8080`**: **rifiutare trasporto e server HTTP**, tenere il nostro server HTTPS `8443` + `AKAI Jarvis Local CA`; eventuale NSD su service type dedicato (`_jarvis._tcp`) | **Costo basso** (porting mirato di poche funzioni Java in `TvController` / `AkaiAccessibilityService`) vs riscrittura tentativi empirici.<br>**Decisione: `ADAPT` (Quick Win #1)** |
| **2. `mahmutaunal/TVPilot`**<br>(Kotlin, AndroidX, Material, Shizuku `13.1.5`) | `TvController` + elevazione controllata in fase di deploy PowerShell (`adb root`/`unroot`) | Solo **pattern architetturali** portati in Java puro: interfaccia `SystemController` (standard vs privilegiate), regex package `PrivilegedCommandPolicy` (`[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+`), parser `PROCESS_STATE_*`, timeout monotonico `PrivilegedUserService.waitFor` con `System.nanoTime()` (`10_000L` ms) | **Apache-2.0** (verificata in `LICENSE`; obbligo attribuzione NOTICE/header se si adatta codice) | `minSdk 24` / `compileSdk 37`; usa Kotlin stdlib + AndroidX + `dev.rikka.shizuku:api/provider:13.1.5` (non compatibili con build leggera `javac`+`d8` senza refactoring toolchain) | Medio-alto come app completa (Kotlin + Material + Shizuku daemon); nullo se si portano solo le policy Java | Nessun conflitto di porta noto, ma **comandi `sleep`/`reboot`/`shutdown` non verificati su hardware MediaTek AKAI** -> rischio blocco/spegnimento non controllato | **Costo alto** come fork/dipendenza; **basso** per solo porting pattern policy/timeout in Java.<br>**Decisione: `ADAPT` (solo pattern in Java puro) / `REJECT` (dipendenze Kotlin e Shizuku)** |
| **3. `Legvan/tv-remote`**<br>(Kotlin/Python) | Telecomando Web HTTPS `8443`, mappatura tasti (`TvController`), lista app (`TvAppPackages`) | Solo documentazione UX e mappature di riferimento (`docs/keycodes.md`, `docs/apps.md`) | **MIT** (preservare nota MIT se si usano snippet) | Misto Kotlin/Python (richiede runtime Python/ADB lato host per `scripts/remote_server.py`) | Trasporto client/server esterno inadatto a girare senza PC come componente on-device snello | **Critico**: trasporto HTTP plaintext + loopback **ADB TCP `5555`** (superficie di attacco aperta su LAN TV e bypass modello TLS `8443`) | **Costo sfavorevole** rispetto a quanto JARVIS ha già in HTTPS + `/dev/uinput`.<br>**Decisione: `REFERENCE` (solo keycodes/UX docs) / `REJECT` (trasporto HTTP + ADB `5555`)** |
| **4. `alphacep/vosk-api` + `alphacep/vosk-android-demo`**<br>(Java + JNI/JNA) | Oggi la dettatura vocale passa dal browser iPhone verso HTTPS `8443` (**0 MB RAM TV**) | Integrazione `com.alphacephei:vosk-android:0.3.75@aar` + `jna:5.18.1@aar` e modello italiano compatto `vosk-model-small-it-0.22` per eventuale microfono locale TV offline | **Apache-2.0** (attribuzione + NOTICE) | `minSdkVersion 21`; `abiFilters 'armeabi-v7a'` presente e supportato; richiede gestione AAR/JNI nella build Android TV | **Pesante su TV ~1.4 GB**: modello `vosk-model-small-it-0.22` ~48 MB su flash e **~250-300 MB RAM runtime** (rischio LMK su processi UI/player) | Elaborazione offline locale (buona privacy), nessun conflitto porte, ma impatto memoria potenzialmente critico se attivo 24/7 | **Costo medio-alto** (AAR/JNA + benchmark RAM TV obbligatorio).<br>**Decisione: `ADAPT` in Fase 2 Post-Beta** (solo dopo misura reale RAM libera sulla TV) |
| **5. `k2-fsa/sherpa-onnx`**<br>(C++ / ONNX Runtime) | Nessun motore STT/KWS C++ on-device al momento | Riserva modulare ARMv7 per eventuale **VAD / wake-word (KWS)** leggero o STT quantizzato `int8` qualora Vosk superasse il budget RAM su `192.168.1.101` | **Apache-2.0** (attribuzione + NOTICE) | Android API >= 21, supporto `armeabi-v7a` documentato; richiede cross-compilazione/prebuilts NDK `.so` | Inferiore a Vosk per soli VAD/KWS; variabile per modelli STT completi (da misurare su ARMv7 32-bit senza NPU dedicata) | Offline on-device, zero porte di rete | **Costo integrazione elevato** (NDK `.so` ARMv7 + packaging modello).<br>**Decisione: `REFERENCE` (riserva Fase 2)** |
| **6. `mobile-next/mobile-mcp` (TS, PC dev-host) & `droidrun/mobilerun` (Python)**<br>(Tooling host + Orchestratore agente) | `ScreenPerceptionEngine` + `TvController.executeActionSequence` + SQLite `procedures` | **`mobile-mcp`**: ispezione UI ADB interattiva da PC sviluppatore accanto a REA/JADX.<br>**`mobilerun`**: solo il pattern concettuale del loop chiuso `Observe -> Plan -> Act -> Verify` | **`mobile-mcp`**: **Apache-2.0**<br>**`mobilerun`**: **MIT** | `mobile-mcp` gira su **PC host**, zero requisiti sulla TV.<br>`mobilerun` richiede stack Python + LLM/VLM (incompatibile on-device su Android 9 `armeabi-v7a`) | **`mobile-mcp`**: 0 MB sulla TV.<br>**`mobilerun`**: incompatibile con ~1.4 GB RAM se eseguito con modelli locali, o dipendente da cloud API | **`mobile-mcp`**: impostare **`MOBILEMCP_DISABLE_TELEMETRY=1`**, nessuna porta esposta su LAN e rispetto del freeze su `192.168.1.101`.<br>**`mobilerun`**: **rifiutare** LLM cloud non filtrati e **qualsiasi automodifica firmware/root** | **`mobile-mcp`**: costo nullo su TV -> **`ADOPT` (solo dev host PC)**.<br>**`mobilerun`**: **`REFERENCE` (solo pattern loop deterministico)**; **`REJECT` runtime Python/LLM/root su TV** |

---

## 3. Quick Win #1 — Analisi Tecnica Puntuale (Post-Beta, Fase 1.1)

L'audit comparativo tra `maxhayim/webmote`, `mahmutaunal/TVPilot` e i sorgenti reali di JARVIS ha individuato **tre difetti concreti e risolvibili a basso rischio in Java puro** senza modificare il server HTTPS `8443`, `/dev/uinput` o Home v8.

### 3.1 Bug delle direzioni D-Pad Accessibility in `TvController.java` (righe 96, 100, 104, 108)
Nel codice attuale di [`TvController.java`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/akai-remote-tv/app/src/main/java/it/akai/customremote/TvController.java#L93-L109), tutti e quattro i rami direzionali del fallback Accessibility passano la stessa costante `AccessibilityNodeInfo.FOCUS_INPUT` (valore `1`) invece delle costanti direzionali `View.FOCUS_*`:

- Riga 96 (`up` / `dpad_up`): passa `AccessibilityNodeInfo.FOCUS_INPUT` anziché `View.FOCUS_UP`.
- Riga 100 (`down` / `dpad_down`): passa `AccessibilityNodeInfo.FOCUS_INPUT` anziché `View.FOCUS_DOWN`.
- Riga 104 (`left` / `dpad_left`): passa `AccessibilityNodeInfo.FOCUS_INPUT` anziché `View.FOCUS_LEFT`.
- Riga 108 (`right` / `dpad_right`): passa `AccessibilityNodeInfo.FOCUS_INPUT` anziché `View.FOCUS_RIGHT`.

Finché `/dev/uinput` è operativo (`uinput_ready: true`) il driver hardware nasconde il problema, ma **in qualunque contesto in cui entra il fallback Accessibility** (es. nodi speciali o assenza temporanea di UInput), tutte e quattro le frecce cercano nella stessa direzione (`FOCUS_INPUT = 1`).  
*Correzione pianificata (Fase 1.1, post-beta)*: sostituire i quattro parametri in `executeDpad(...)` con `View.FOCUS_UP`, `View.FOCUS_DOWN`, `View.FOCUS_LEFT`, `View.FOCUS_RIGHT` (pattern confermato da `webmote/RemoteService.java`), **mantenendo `AccessibilityNodeInfo.FOCUS_INPUT` esclusivamente per `root.findFocus(...)`**.  
*Requisito di verifica unitaria*: simulare `uinputDriver.isAvailable() == false`, invocare ciascuno dei quattro comandi direzionali (`up`, `down`, `left`, `right`) e verificare che a `AkaiAccessibilityService.navigateFocus(int direction)` venga passata esattamente la costante attesa (`View.FOCUS_UP`, `View.FOCUS_DOWN`, `View.FOCUS_LEFT`, `View.FOCUS_RIGHT`), non soltanto che il metodo venga invocato.

### 3.2 Limiti di `clickFocusedNode()` e `navigateFocus()` in `AkaiAccessibilityService.java` (righe 183–223)
Ispezionando [`AkaiAccessibilityService.java`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/akai-remote-tv/app/src/main/java/it/akai/customremote/AkaiAccessibilityService.java#L183-L223) rispetto a `webmote/RemoteService.java` emergono tre lacune tipiche di Android TV 9:

1. **`clickFocusedNode()` (L183–200)**: invoca `focused.performAction(AccessibilityNodeInfo.ACTION_CLICK)` direttamente sul nodo focalizzato. Su molte schermate Leanback/Android TV il focus appartiene a un elemento figlio non direttamente cliccabile, mentre il contenitore padre espone `isClickable()`.  
   *Adattamento da `webmote` con guardia di sicurezza*: risalire gli antenati con `getParent().isClickable()` (riciclando correttamente ogni `AccessibilityNodeInfo` intermedio per evitare leak) finché `ACTION_CLICK` non trova il container cliccabile, **bloccando la risalita/click su schermate sensibili (`ScreenPerceptionEngine.hasSensitiveFields`) o su pulsanti distruttivi senza controllo esplicito**.
2. **`navigateFocus(int direction)` (L202–223) con focus iniziale assente**: se sia `FOCUS_INPUT` sia `FOCUS_ACCESSIBILITY` sono `null`, il metodo restituisce subito `false`.  
   *Adattamento da `webmote`*: fallback tramite `firstFocusable()` per agganciare il primo elemento focusabile nella finestra attiva.
3. **`navigateFocus(int direction)` ai bordi di una lista/griglia**: quando `focused.focusSearch(direction)` restituisce `null`, la navigazione si ferma.  
   *Adattamento da `webmote`*: fallback su `ACTION_SCROLL_FORWARD` / `ACTION_SCROLL_BACKWARD` risalendo al nodo `isScrollable()` compatibile con la direzione richiesta.

### 3.3 Lancio app Leanback e ricerca YouTube TV in `TvController.java` (riga 283)
1. **Avvio app Leanback**: `launchAppPackage(String pkg, String appName)` ([`TvController.java`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/akai-remote-tv/app/src/main/java/it/akai/customremote/TvController.java#L280-L293)) invoca soltanto `pm.getLaunchIntentForPackage(pkg)`. Su Android TV diverse app espongono l'entry-point Leanback tramite `pm.getLeanbackLaunchIntentForPackage(pkg)`. Provare `getLeanbackLaunchIntentForPackage(pkg)` prima del fallback a `getLaunchIntentForPackage(pkg)` migliora l'affidabilità di apertura app su TV senza rompere le app standard.
2. **Deep-link ricerca YouTube TV (`SEARCH_LINKS`)**: quando l'utente invia testo di ricerca verso YouTube TV (`com.google.android.youtube.tv`, già rilevata come installata in [`TvAppPackages.java`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/akai-remote-tv/app/src/main/java/it/akai/customremote/TvAppPackages.java)) e non è presente alcun campo editabile focalizzato per `setFocusedText()`, è possibile usare il fallback `Intent.ACTION_VIEW` verso `https://www.youtube.com/results?search_query=<encoded>` (pattern MIT da `webmote`).
3. **Resilienza discovery e policy Java pure**:
   - Da `webmote`: `NsdManager` + `ConnectivityManager.NetworkCallback` su servizio dedicato (senza confliggere con mDNS terzi) e catalogo app dinamico `CATEGORY_LEANBACK_LAUNCHER` con eventuale cache banner limitata a `1 MB`.
   - Da `TVPilot` (in **Java puro**, senza Kotlin/Shizuku): separazione `SystemController` e validazione rigida dei package name tramite regex `[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+`, parser stati processo `PROCESS_STATE_*` e timeout monotonici con `System.nanoTime()` (`10_000L` ms).

---

## 4. Architettura Agente Aggiornata (`#issuecomment-6881433641`: Cloud Opzionale DeepSeek/Kimi + Closed-Loop On-TV)

In base alla **decisione definitiva del proprietario (`#issuecomment-6881433641`)**, che rettifica le proposte esplorative local-only/split-brain (`#6880750275` e `#6881298340`), **JARVIS resta interamente residente sulla AKAI TV (`192.168.1.101`)** con nessun requisito di mini PC esterno, Termux o `llama.cpp` su ARMv7. L'inferenza AI sfrutta gli adattatori cloud opzionali **DeepSeek** e **Moonshot Kimi Open Platform** (`CLOUD_OPTIONAL`) con fallback esplicito `LOCAL_ONLY` e fast-path locale a **0 token**:

- **P0 Credenziali (`KeystoreSecurityHelper.java`)**: rimosso ogni fallback in chiaro (`b64:`); le nuove chiavi richiedono cifratura crittografica AES-256-GCM valida, `isHardwareBackedKeystore()` rileva realmente `KeyInfo.isInsideSecureHardware()` e i payload legacy non cifrati vengono rifiutati/migrati o purgati senza loggare segreti.
- **P1 Provider & Validazione (`AiProviderAdapter.java`)**: supporto selezionabile DeepSeek (`https://api.deepseek.com/chat/completions`) e Moonshot Kimi internazionale (`https://api.moonshot.ai/v1/chat/completions`, con opzione regione `cn` allowlisted, distinzione chiara tra key Moonshot Open Platform e `Kimi Coding`), validazione rigorosa dello schema JSON/`tool_calls` e whitelist azioni (tipi consentiti, package approvati, `wait` limitati, blocco `power`/azioni distruttive senza conferma owner, lettura bounded max `64 KB`, contatore client dichiarato come stima locale).
- **Privacy & Tassonomia Obbligatoria (`COMMAND_SENT`, `STATE_VERIFIED`, `FAILED`, `NOT_TESTED`)**: contesto schermo minimizzato e redatto (`toRedactedMinimalContextPrompt()`), blocco immediato su `hasSensitiveFields == true`, loop chiuso `Osserva -> Contesto Minimo Redatto -> Pianifica -> Valida -> Esegui -> Riosserva -> Verifica -> [max 1 replanning distinto] -> Salva in SQLite SOLO se STATE_VERIFIED`.

```
  [Richiesta Utente via HTTPS 8443]
                 │
                 ▼
      0. FAST-PATH LOCALE (0 Token) + LOOKUP SQLite `procedures`
         - Se noto e risolto -> esegue; verifica con ScreenPerceptionEngine
                 │
                 ▼ (solo se CLOUD_OPTIONAL + API key configurata)
      1. OSSERVA (ScreenPerceptionEngine)
         - Gate privacy obbligatorio: blocco immediato se `hasSensitiveFields == true`
         - Preparazione contesto MINIMO e REDATTO (`toRedactedMinimalContextPrompt`)
                 │
                 ▼
      2. PIANIFICA (DeepSeek / Moonshot Kimi con JSON/tool_calls)
         - Validazione rigorosa schema, tipi azione, package whitelist e `success_condition`
                 │
                 ▼
      3. AGISCI (`TvController.executeActionSequence` / singolo blocco sicuro)
         - Esito immediato classificato al massimo come `COMMAND_SENT` (mai `STATE_VERIFIED`)
                 │
                 ▼
      4. VERIFICA & REPLANNING (Max 1 replanning distinto su fallimento)
         - Rilettura `ScreenPerceptionEngine` -> classificazione `STATE_VERIFIED` vs `FAILED`
                 │
                 ▼
      5. IMPARA (SQLite local memory, cap `15 MB`)
         - Solo se `STATE_VERIFIED` -> incrementa `success_count` e salva procedura verificata
         - Se `FAILED` (inclusi `COMMAND_SENT` senza cambio stato osservato) -> NON salva come successo
```

### Piano Operativo per Fasi (Nessuna Deviazione sulla Baseline Beta)

| Fase | Obiettivo | Perimetro & Vincoli | Criterio di Uscita |
| :--- | :--- | :--- | :--- |
| **Fase 0 — Backup Reale (A) e Beta Gate (B)** | Eseguire prima **Autorizzazione (A)** (solo backup reale v5 + prova offline + riavvio immediato v5) e poi **Autorizzazione (B)** (deploy v6, HTTPS `8443` SAN `192.168.1.101`, iPhone Safari) | Procedura dettagliata in [`REAL_TV_V5_BACKUP_OPERATIONAL_PLAN.md`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/docs/REAL_TV_V5_BACKUP_OPERATIONAL_PLAN.md); codice invariato rispetto alla baseline CI verde | Fase A: backup v5/WAL consolidato SHA-256 + `adb unroot` -> `uid=2000` + v5 riavviato.<br>Fase B: preflight `APPROVED` e telecomando iPhone operativo |
| **Fase 1.1 — Quick Win #1 (Patch Java mirata post-beta)** | Risolvere D-Pad Accessibility (`View.FOCUS_*`), antenato `isClickable()` con guardia sensibile/distruttiva, `firstFocusable()`, scroll fallback, `getLeanbackLaunchIntentForPackage` & YouTube `SEARCH_LINKS` | Java puro compatibile `javac` + `d8`; nessuna lib esterna; test unitari con `uinput` disabilitato che verificano la costante esatta passata a `navigateFocus` | CI `34+` Java & `29/29` PowerShell verdi + verifica su TV |
| **Fase 1.2 — Cloud DeepSeek/Kimi (`CLOUD_OPTIONAL`) & Agente Closed-Loop Verificato** | Sbloccare inferenza opzionale DeepSeek & Moonshot Kimi con P0 Keystore cifrato, validazione schema/whitelist, contesto minimo redatto e loop `Osserva -> Pianifica -> Agisci -> Verifica -> [max 1 replan] -> Salva solo STATE_VERIFIED` | Nessun mini PC / Termux / `llama.cpp`; `LOCAL_ONLY` resta selezionabile esplicitamente; mock HTTP completi su CI senza traffico fatturabile | Mock DeepSeek/Kimi HTTP (`200/401/402/429/timeout/bad JSON/schema`), test `KeystoreSecurityHelper` senza `b64:`, test scenarios `'apri YouTube'` e `'apri impostazioni audio'` verdi in CI |
| **Fase 2 — Espansioni Opzionali Misurate (Voce Offline & Dev Tooling)** | Valutare voce on-device TV (`vosk-model-small-it-0.22` o riserva `sherpa-onnx` `int8`/VAD) e consolidare debug PC con `mobile-mcp` | **Obbligatorio benchmark RAM reale su TV (~1.4 GB)** prima di includere AAR/JNI ~250-300 MB; la dettatura da iPhone Safari via HTTPS `8443` rimane attiva a **0 MB RAM TV**. `mobile-mcp` confinato al PC host con `MOBILEMCP_DISABLE_TELEMETRY=1` | Decisione go/no-go basata su `dumpsys meminfo` reale senza OOM/LMK su player e Home v8 |

### Fase B — Riuso Selettivo Pattern MobileAgent-Android & AgentPaw (`#6881898084`)

Senza aggiungere librerie esterne, Kotlin/Compose, Shizuku, root agent o una seconda app sulla TV, i pattern architetturali verificati dei due progetti sono stati adattati direttamente nelle classi Java esistenti (`AkaiAiController.java`, `ScreenPerceptionEngine.java`, `AiProviderAdapter.java`):

- **Da MobileAgent-Android (Stepwise Executor & State Reflector)**: esecuzione per singoli step (`executeActionsStepwise`), lettura esplicita stato pre/post (`buildReflectorContext` via `toRedactedMinimalContextPrompt()`), massimo 1 replanning non ripetitivo con scarto automatico di piani identici, distinzione categorica `STATE_VERIFIED` vs `COMMAND_SENT` vs `FAILED` vs `NOT_TESTED`, salvataggio in memoria procedurale SQLite consentito **solo** su `STATE_VERIFIED`.
- **Da AgentPaw (Adaptive Bounded Wait & Cooperative Cancel)**: sostituzione delle attese fisse bloccanti (`800/1200/1500 ms` di `Thread.sleep`) con polling adattivo delimitato (`waitForConditionOrUiChange` / `waitForHomePackage`) che termina appena la UI o la `success_condition` soddisfa il criterio osservato, più supporto cooperativo `cancelCurrentTask()`.
- **Tradeoff misurati**: **0 nuove dipendenze** e incremento minimo sul solo codice applicativo (`classes.dex`); telemetria per richiesta (`cloud_calls`, `snapshot_count`, `wait_elapsed_ms`, `replan_count`, `execution_outcome`). Le metriche fisiche su AKAI TV (`RAM/PSS`, `CPU`, `cold-start`, latenza D-Pad reale) restano esplicitamente `NOT_TESTED` sotto freeze hardware.

---

## 5. Riferimenti ai File Analizzati nel Repository

- [`TvController.java`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/akai-remote-tv/app/src/main/java/it/akai/customremote/TvController.java#L93-L109) (`executeDpad` L231–241, `launchAppPackage` L280–293)
- [`AkaiAccessibilityService.java`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/akai-remote-tv/app/src/main/java/it/akai/customremote/AkaiAccessibilityService.java#L183-L223) (`clickFocusedNode` L183–200, `navigateFocus` L202–223)
- [`ScreenPerceptionEngine.java`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/akai-remote-tv/app/src/main/java/it/akai/customremote/ai/ScreenPerceptionEngine.java#L1-L120)
- [`TvAppPackages.java`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/akai-remote-tv/app/src/main/java/it/akai/customremote/TvAppPackages.java#L1-L76)
- [`TlsCertificateManager.java`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/akai-remote-tv/app/src/main/java/it/akai/customremote/TlsCertificateManager.java#L1-L632)
- [`ci.yml`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/.github/workflows/ci.yml#L1-L237)
