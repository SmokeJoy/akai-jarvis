# AKAI JARVIS v16 — Audit indipendente dello snapshot congelato

**Data:** 7 novembre 2026  
**Oggetto:** i sette ZIP forniti dall'utente, i sorgenti Web/Android/JNI, il launcher, gli script PowerShell, i mock/test Java, gli APK e il manifest di snapshot.  
**Metodo:** revisione statica e confronto dei contratti tra componenti; nessuna modifica alla TV, nessuna installazione né esecuzione di script PowerShell/Android sul dispositivo. Esecuzione host dei test Java disponibili, `node --check` su `app.js`/`sw.js`, controllo ZIP/SHA-256 e verifica JAR v1 degli APK. Confronto puntuale con lo snapshot v15.3 precedentemente fornito.  
**Esito generale:** **NON PRONTO AL DEPLOYMENT.** I pacchetti sono integri, ma il controllo funzionale di base contiene regressioni bloccanti e il binario rilasciato incorpora una credenziale TLS privata.

## A. Integrità e prove effettivamente eseguite

- **7/7 archivi ZIP**: apribili, CRC valido (`testzip() == None`), SHA-256 identico al manifest.
- **302/302 file del manifest**: presenti e hash SHA-256 corrispondenti (normalizzando i separatori Windows `\\` delle entry ZIP).
- **APK v16**: i file `assets/www/app.js`, `index.html`, `style.css`, `sw.js` coincidono byte per byte con l'archivio Web Remote.
- **Sintassi JavaScript**: `node --check` passa per `app.js` e `sw.js`.
- **HTML/JS**: 87 riferimenti `document.getElementById` presenti nell'HTML; nessun ID duplicato in `index.html`.
- **Java host**: 12/12 test disponibili eseguiti con Java 21 e i mock distribuiti; passano. **Non sono test di integrazione Android**.
- **Firma APK**: `jarsigner -verify` segnala `jar verified` per entrambi gli APK, con avvisi per firma self-signed e consistenza `JarFile`/`JarInputStream`; non equivale a verifica APK Signature Scheme v2 né a collaudo dell'installazione.
- **Confronto con v15.3**: 17 file di sorgente/Web condivisi hanno contenuti diversi. Non è disponibile una cronologia Git autentica per attribuire i singoli cambiamenti.
- **Test automatici nuovi**: lo script allegato `AKAI_JARVIS_v16_verifica_contratti.py` eseguito sullo snapshot produce **11 FAIL / 2 PASS**. I FAIL sono violazioni statiche dei contratti o rischi verificabili e non sostituiscono i collaudi runtime.

## B. Difetti bloccanti — P0

### P0-01 — Endpoint REST non compatibili tra Web Remote v16 e server Android

- **Client:** `akai-remote-web/app.js:727–779` usa `POST /api/command` per tasti e input testuale. `app.js:1313` usa `POST /api/auth/pair` per completare il PIN.
- **Server:** `RemoteServerService.java:460–508` espone `POST /api/auth/pair/request` e `POST /api/auth/pair/verify`. `RemoteServerService.java:522–574` espone `POST /api/control/command` e `POST /api/control/text`.
- **Impatto:** associazione di un telefono nuovo, D-Pad, Home/Back/volume e invio testo non funzionano tramite la UI v16: le richieste ricadono nel 404 della gestione file statici.
- **Confronto con v15.3:** il precedente `akai-remote-web/app.js` chiamava gli endpoint coerenti; **regressione del frontend v16**.
- **Correzione:** ripristinare gli URL corretti *nel client*, richiamare la sequenza `POST /api/auth/pair/request` seguita da `POST /api/auth/pair/verify` e inviare per testo `{text: ...}` a `/api/control/text`. Aggiungere test di contratto automatici e test HTTP con autenticazione contro un server locale di test. Non affidarsi al solo `node --check`.

### P0-02 — UI con quattro comandi TV non implementati

- **Client:** `index.html` contiene `data-cmd="menu"`, `channel_up`, `channel_down`, `channel_prev`.
- **Server:** `TvController.java:44–169`, nello `switch`, non gestisce tali valori. `open_numpad` è invece gestito esclusivamente dal JS, non è un problema.
- **Impatto:** quei tasti continueranno a fallire **anche dopo** la correzione degli URL.
- **Correzione:** implementare azioni reali e testate via input uinput/Accessibility, oppure disabilitare i pulsanti non supportati e spiegarne la ragione. Niente successi simulati.

### P0-03 — Credenziale TLS privata ancora incorporata nel binario consegnato

- **Binario:** `06_AKAI_BINARIES_RELEASE.zip > AKAI_JARVIS_Remote_v16.apk > assets/server_keystore.p12` esiste davvero (4.505 byte), benché assente dallo ZIP dei sorgenti.
- **Codice:** `RemoteServerService.java:176–190` carica il keystore direttamente dagli assets e contiene la password del file come stringa hardcoded.
- **Build:** `scripts/08_compile_akai_remote_apk.ps1:113–124` impacchetta in modo indiscriminato tutta la directory `assets`.
- **Impatto:** la chiave privata della specifica identità TLS della TV può essere estratta dall'APK; **la dichiarazione di sanitizzazione degli archivi non vale per il binario**.
- **Correzione:** non pubblicare/riutilizzare questo binario come versione sicura; generare un'identità TLS nuova specifica della TV, conservarne la chiave privata in spazio applicativo protetto (idealmente generazione chiave tramite Android Keystore se compatibile), rimuovere password fissa e materiale privato dal packaging, aggiungere controllo automatico sul contenuto dell'APK. Pianificare la migrazione di fiducia dei telefoni prima di ruotare i certificati, per non perdere l'accesso al telecomando.

### P0-04 — Risposta `/api/ai/memory` duplicata e incompatibile con la UI

- **Server:** `RemoteServerService.java:739–761` gestisce `GET /api/ai/memory` restituendo `conversations`, `preferences`, `stats`, ecc. **Poi** `RemoteServerService.java:949–968` gestisce la stessa combinazione path/metodo con `procedures`, `recent_conversations`, `guest_mode`: il secondo ramo non è raggiungibile.
- **Client:** `app.js:795–818` cerca `recent_conversations`, `procedures`, `guest_mode`; riceve campi mancanti e costruisce schermate vuote.
- **Impatto:** la tab Attività mostra cronologia/procedure assenti quando possono essere presenti nel database.
- **Correzione:** definire un solo contratto e una sola route, con `conversations`, `recent_conversations` o altra struttura concordata; aggiornarne il client e testare la risposta con dataset non vuoto.

### P0-05 — Modalità Ospite aggirabile nel parser locale delle preferenze

- **DB:** `AkaiMemoryEngine.java:472–476` non espone `getAllPreferences()` in Guest Mode, e `saveConversationExchange():568–573` non salva nuovi turni durante Guest Mode.
- **Parser:** `LocalIntentParser.java:158–179` legge direttamente `getPreference("favorite_channels" ...)` e `getPreference("favorite_genres" ...)`, **senza controllare Guest Mode**.
- **Impatto:** un telefono ospite può chiedere vocalmente i gusti/canali precedentemente memorizzati, nonostante l'intento della modalità privacy.
- **Correzione:** usare un contesto utente/sessione con autorizzazioni esplicite; verificare guest mode in tutti i percorsi, inclusi comandi locali, memoria procedurale e prompt AI. Aggiungere test di non divulgazione in modalità Ospite.

### P0-06 — Esecuzione possibile di procedure mai verificate, comprese quelle ereditate

- **Memoria:** `AkaiMemoryEngine.java:265–320` cerca procedure con uguaglianza e substring e ordina per `success_count DESC`, **ma non impone `success_count > 0` e `last_verified_at > 0`**.
- **Parser:** `LocalIntentParser.java:220–233` crea un `ParsedIntent(matched=true)` anche per un template con zero successi.
- **AI:** `AkaiAiController.java:99–113` quando manca `successCondition` usa `cmdRes.success` come prova, contraddicendo la semantica di `SUCCESS_VERIFIED`.
- **Migrazione:** `AkaiMemoryEngine.onUpgrade():149–190` non invalida le vecchie procedure difettose di Italia 2 già presenti nel DB del televisore; rimuovere il template dai nuovi sorgenti non rimuove i record già installati.
- **Impatto:** vecchie macro errate possono continuare a essere invocate e segnate come riuscite senza prova sul canale.
- **Correzione:** distinguere `TEMPLATE`, `VERIFIED`, `STALE`, `FAILED`; eseguire soltanto `VERIFIED` per fast path; migrazione idempotente mirata dei record vecchi, preservando preferenze e cronologia; verifica specifica di canale/payload/media.

## C. Problemi importanti — P1

### P1-01 — Pool HTTP dichiarato bounded ma effettivamente illimitato nella coda

- **Codice:** `RemoteServerService.java:90` usa `Executors.newFixedThreadPool(12)`, che crea una **coda di lavoro non limitata**, non il `ThreadPoolExecutor(12, queue=50)` descritto in `AKAI_ARCHITETTURA_COMPLETA.md`.
- **Impatto:** carichi concorrenti possono accodare lavoro e consumare RAM. `processQuery` gira sincrono su un worker (`RemoteServerService.java:583–598`).
- **Correzione:** pool bounded con rejection gestita (HTTP 503), worker dedicati per chiamate cloud lente, timeout operativi, limiti di concorrenza per sessione, risposte asincrone con job ID.

### P1-02 — Stop browser non ferma realmente la TV

- **Client:** `app.js:429–459` ferma il riconoscimento e abortisce solo `fetch` lato browser.
- **Server:** manca un endpoint di cancellazione per la richiesta AI in corso e per la sintesi TV; l'azione può continuare anche se il client ha chiuso il dialogo.
- **Impatto:** la TV può iniziare o proseguire a parlare dopo il pulsante Stop; un comando TV già inviato può comunque essere eseguito.
- **Correzione:** sessionId + turnId + jobId; cancellazione esplicita e cooperativa del job, TTS stop con controllo proprietario per sessione, non interrompere un altro telefono per errore.

### P1-03 — Microfono non correlato alla risposta vocale corretta

- **Server:** `GET /api/ai/speech_status` invia `speech_id` (`RemoteServerService.java:602–610`).
- **Client:** `app.js:499–555` ignora `speech_id` e guarda solo `speech_state/speaking`. Può confondere risposte di due telefoni; dopo 4 secondi senza aver osservato sintesi assume che non vi sia voce e riapre il microfono; dopo massimo 16 secondi esce comunque dal loop.
- **Impatto:** ripresa dell'ascolto durante risposte tardive/lunghe o mentre sta parlando la risposta di un altro telefono.
- **Correzione:** associare ID di turno e ID vocale; polling per risposta specifica, eventi o stato finale esplicito, retry/timeout con UI “riprendi”, nessuna riapertura automatica su stato ambiguo.

### P1-04 — Le chiamate vocali cloud bloccano direttamente il percorso della richiesta

- **Codice:** `AkaiAiController.completeAndSpeak():343–359` chiama `speech.speak()`; `AkaiSpeechEngine.speak():164–190` chiama in modo sincrono `CloudSpeechAdapter.speakNeural`; `CloudSpeechAdapter.fetchFromAzure():120–183` attende rete e scarica MP3.
- **Impatto:** la risposta HTTP a `/api/ai/ask` può attendere il download della voce; altri comandi possono soffrire per saturazione o timer frontend.
- **Correzione:** coda TTS asincrona e limitata, stato per request, timeouts, stop verificabile; il backend restituisce un identificatore job prima di avviare la fase audio.

### P1-05 — Verifica player insufficiente per identificare il programma

- **Codice:** `ScreenPerceptionEngine.java:241–263` considera `isMusicActive` o la presenza di una vista player e `expectedText` opzionale, senza legare in modo robusto lo stato multimediale al contenuto richiesto. Il testo del canale può comparire anche nelle liste.
- **Impatto:** falso positivo su Italia 2 e altri canali quando il player è aperto ma non c'è la diretta giusta.
- **Correzione:** distinguere app aperta / player visibile / player in riproduzione / contenuto identificato; usare più segnali congruenti per ogni app, compresi media session/metadata quando esposti, UI player controllata e stabilità temporale; `UNVERIFIED` quando mancano prove.

### P1-06 — Server HTTP in chiaro rimane abilitato per operazioni sensibili

- **Codice:** HTTP porta 8088 e HTTPS 8443 condividono `routeRequest` senza restrizioni differenziate (`RemoteServerService.java:208–278`, `398+`). `Access-Control-Allow-Origin: *` su tutte le risposte (`1046–1060`).
- **Impatto:** token bearer, PIN, domande personali e chiavi API potrebbero transitare su HTTP se il client sceglie la porta non cifrata.
- **Correzione:** accesso configurazioni, pairing e API AI soltanto via HTTPS con certificato attendibile; su HTTP al massimo redirect dell'interfaccia pubblica o disabilitazione dopo migrazione; verificare le policy CORS e l'origine dei client autorizzati.

### P1-07 — Limite persistente di 15 MB non corrisponde all'occupazione totale

- **Codice:** `AkaiMemoryEngine.getDatabaseSizeBytes():628–650` usa `page_count * page_size`, non misura i file WAL/SHM o gli MP3 della cache; `checkAndEnforceStorageBudget():653–666` verifica solo `> MAX_STORAGE_BYTES` e invoca `VACUUM` dopo la scrittura.
- **Impatto:** il limite totale dichiarato è superiore alla dimensione misurata, `VACUUM` può comportare I/O costoso e non garantisce un limite rigido.
- **Correzione:** misura file fisici DB/WAL/SHM/cache separatamente e nel totale, checkpoint/compattazione solo in idle e non nel percorso di risposta, politica di retention dichiarata e verificabile.

### P1-08 — Memoria “personale” precaricata con preferenze inventate

- **Codice:** `AkaiMemoryEngine.java:193–210` inserisce `favorite_channels` e `favorite_genres` già valorizzati come personali; non sono ricordi derivati da una scelta verificata dell'utente.
- **Impatto:** JARVIS afferma «i tuoi canali preferiti» anche senza un'impostazione effettiva; dati condivisi da tutti i telefoni.
- **Correzione:** lasciare preferenze non definite finché l'utente non le imposta; gestione profili opzionale; privacy multiutente esplicita.

### P1-09 — Cache audio salva anche contenuti conversazionali privati

- **Codice:** `CloudSpeechAdapter.java:155–170` salva normalmente MP3 su disco; `containsSensitiveData():356–360` filtra soltanto poche parole e sequenze numeriche. `clearCache` esiste ma non equivale alla privacy predefinita.
- **Impatto:** nomi, frasi personali e altre risposte sensibili non numeriche possono rimanere nei file audio.
- **Correzione:** niente cache delle risposte dinamiche personali, solo frasi di sistema prefissate e non sensibili; file temporanei sempre rimossi (anche dopo crash, con pulizia all'avvio).

### P1-10 — Test unitari fuorvianti rispetto alle parti critiche

- **Test:** `UnitTests.java:~88` Test 7 stampa PASS senza effettuare assert; Test 11 prova una conversione `String → byte[] → String`, **non** il parser `handleClient`; Test 12 usa un ciclo simulato, **non** `TvController.executeActionSequence`.
- **Impatto:** 12/12 PASS è corretto per il test eseguito, ma non misura le regressioni Web/Backend, la verifica dei player o la reale gestione del TTS.
- **Correzione:** test di contratto endpoint, mock server con richieste reali JSON UTF-8, test del controller con input iniettato, test di upgrade SQLite v4→v5, test di Guest Mode e test del ciclo audio con eventi ritardati.

### P1-11 — Problema di riproducibilità del rollback e stato release

- **Archivio effettivo:** `06_AKAI_BINARIES_RELEASE.zip` contiene **tre** file (`AKAI_JARVIS_Remote_v16.apk`, `AKAI_Custom_Home_v8.apk`, `AkaiRootCA.crt`): NON contiene il `LTvLauncher_Factory_Backup.apk` menzionato nel riepilogo di Antigravity.
- **Script:** `99_emergency_restore.ps1` riabilita *un package disabilitato*; non è da solo un backup completo del launcher o del database.
- **Correzione:** prima di qualsiasi installazione produrre backup verificati fuori dal repository, tabella versioni APK/hash/certificati, procedura rollback realmente testata, export dati consentito e checkpoint ADB. Mai promettere «ripristino totale» senza provarlo.

### P1-12 — Mancanza di storicizzazione Git

- **Archivio 05:** contiene documenti narrativi, non commit/diff autentici. La repository `SmokeJoy/akai-jarvis` non risulta accessibile su GitHub alla data della revisione (404 dal collegamento disponibile).
- **Impatto:** non si può verificare «tutto ciò che Antigravity ha fatto» nel tempo; si può auditare l'attuale snapshot e confrontarlo con il precedente ZIP v15.3.
- **Correzione:** inizializzare repository PRIVATA solo con sorgenti sanitizzati, baseline congelata e tag `audit-v16-frozen`, PR separate con diff e test CI. Mai pubblicare l'APK v16 con keystore privato.

### P1-13 — Testi immessi registrati nei log prima del controllo della password

- **Codice:** `AkaiAccessibilityService.java:225–229` registra in log il contenuto integrale passato a `setFocusedText`, prima del controllo `targetNode.isPassword()` a `:265–271`.
- **Impatto:** testo immesso dal telecomando, comprese potenziali informazioni personali, finisce nei log diagnostici se disponibili; il successivo blocco del campo password non cancella il dato già registrato.
- **Correzione:** eliminare il logging del valore testuale; registrare solo lunghezza, classe dell'azione, codice esito e ID richiesta non sensibile. Aggiungere test per la non esposizione di segreti nei log.

### P1-14 — Contesto multi-telefono non isolato

- **Codice:** il frontend dispone di `currentTurnId` locale (`app.js:33–45`), ma `POST /api/ai/ask` invia solo `query`, `speak`, `source` (`app.js:611–619`). Il backend ricava il contesto dalle ultime tre conversazioni globali (`AkaiAiController.java:192–194`), non da un ID di sessione utente.
- **Impatto:** richieste contemporanee da due telefoni autorizzati possono condividere impropriamente riferimenti e risposte; la memoria globale non equivale a una conversazione privata coerente.
- **Correzione:** introdurre un identificatore di sessione per dispositivo e separare cronologia volatile dei turni dall'eventuale memoria condivisa esplicitamente autorizzata. Guest Mode deve valere anche per questa separazione.

## D. Limiti e opportunità UI — P2

1. Layout a tre tab **Assistente / Telecomando / Attività** presente nel codice, ma non ancora dimostrato su Safari iOS e Chrome Android reali; gli screenshot di anteprima sono riferimenti grafici, non prove end-to-end.
2. `index.html:76` (Orb) e `index.html:123` (microfono rapido) creano due modalità di ascolto concorrenti; semplificare la navigazione primaria o chiarire le differenze all'utente.
3. Separare i messaggi *comando inviato*, *eseguito*, *verificato*, *errore* con evidenze e richiesta di riprova; non usare colorazioni di successo per `COMPLETED_UNVERIFIED`.
4. D-Pad e tasti rapidi devono essere validati con contratto `data-cmd` condiviso dal backend, non solo con screenshot.
5. Integrare test viewport 320/375/390/430 px, font scaling/accessibilità, VoiceOver iOS, TalkBack Android, tastiera, orientamento, safe-area e contrasto. Il CSS contiene `safe-area`, ma non sostituisce il collaudo.
6. In fase di pairing usare onboarding HTTPS affidabile e messaggi chiari quando il certificato non è riconosciuto; l'abilitazione del microfono non è garantita soltanto perché una porta TLS risponde.

## E. Stato del prodotto: cosa è realmente dimostrato

| Dimensione | Stato nella revisione |
|---|---|
| Integrità dei 7 archivi | **PASS** 7/7 |
| Inventario manifest | **PASS** 302/302 |
| Sintassi JS | **PASS** |
| Riferimenti HTML-ID | **PASS** |
| Test host Java eseguiti | **PASS** 12/12, copertura insufficiente |
| APK v16 corrisponde agli asset Web consegnati | **PASS** |
| Associazione da nuovo telefono | **FAIL di contratto** `/api/auth/pair` non esiste |
| Telecomando Web v16 | **FAIL di contratto** `/api/command` non esiste |
| Attività / memorie | **FAIL di contratto** schema divergente |
| Esclusione chiavi private dai binari | **FAIL** keystore TLS in APK |
| Limite RAM 8.2 MB in tutte le condizioni | **NON VERIFICATO** (telemetria parziale, nessun carico sostenuto) |
| Conversazione continua su Safari e Chrome reali | **NON VERIFICATA** |
| Audio neurale Azure realmente udibile | **NON VERIFICATO in questo audit** |
| Italia 2 in diretta con conferma attendibile | **NON VERIFICATO**; algoritmo suscettibile a falsi positivi |
| Ripristino totale del dispositivo | **NON VERIFICATO** |
| Test compilazione APK nel container | **NON ESEGUITO** (toolchain Android completa non inclusa) |
| Storia Git autentica | **ASSENTE nello snapshot** |

## F. Piano di riparazione PR per PR — preservare la codebase

**PR 00 — Backup e baseline privata (nessun deployment).** Archiviare i 7 ZIP in luogo privato; tenere fuori da Git APK vulnerabile/keystore/token e database utenti; creare repository privata, branch `main` solo baseline approvata, tag snapshot; acquisire versione installata sulla TV e piano rollback senza alterare il dispositivo.

**PR 01 — Contratti REST e telecomando (P0).** Ripristinare endpoint client, adeguare body `text`, verificare i 4 comandi UI non supportati, rimuovere duplicazione di `/api/ai/memory`. Aggiungere test automatici contro API mock e UI. **Criterio:** pairing, D-Pad, Back, Home, volume, menu/canali, input testo, Attività funzionano in staging.

**PR 02 — TLS e sessioni (P0).** Rimuovere certificati/chiavi private dal binario e password fissa; generare chiavi per dispositivo; transizione sicura certificati telefoni; isolare le API sensibili su HTTPS. **Criterio:** scansione APK non trova alcun private keystore; richieste sensibili su HTTP rifiutate; pairing HTTPS funzionante su dispositivi autorizzati.

**PR 03 — Memoria/semantica/guest (P0).** Correggere guest preference leak, invalidare macro Italia 2 vecchie senza cancellare dati utente, separare template/verified, vietare `SUCCESS_VERIFIED` senza condizione verificabile, migrazioni database testate da copie sanitarie. **Criterio:** Ospite non legge preferenze; reset non elimina gusti; Italia 2 falso non passa; backup/migrazione preservano dati.

**PR 04 — Concorrenza, timeout e sessione voce (P1).** Executor bounded con code e errori 503, TTS asincrono, ID per conversazione/turno/audio, Stop server-side, limiti di 2 telefoni concorrenti, status distinti. **Criterio:** telecomando reattivo con cloud lento; nessun riavvio microfono durante audio; Stop ferma realmente la voce in corso per quella sessione.

**PR 05 — Verifica canali e apprendimento (P1).** Evidenze semanticamente robuste per app/player/contenuto; navigazione con osservazione e step check, invalidazione delle procedure scadute. **Criterio:** cold launch Italia 2 da Home, da player diverso, da schermata film; su errore non dichiarare successo.

**PR 06 — Privacy, storage e UI (P1/P2).** Cache TTS privata temporanea, budget fisico DB/WAL/cache, layout mobile semplificato, test accessibilità e PWA. **Criterio:** RAM, storage, batteria, 3 turni iOS e 3 Android reali, memoria e guest mode senza perdite.

**Deployment:** solo dopo review diff + test CI + backup/rollback + test TV in ambiente controllato. Nessun auto-merge, nessun rollout OTA/firmware.

## G. Come verificare automaticamente una successiva revisione

1. Eseguire `python AKAI_JARVIS_v16_verifica_contratti.py <directory_snapshot_estratta>` e controllare i 13 controlli, che vanno poi estesi ai test endpoint live.
2. Eseguire test host Java, sintassi JS, scansione segreti sull'**intero APK**, non solo sui sorgenti.
3. Aprire una PR per ogni gruppo sopra, allegando output reale di test e differenze tra commit.
4. Durante le PR controllare da GitHub codice, script e workflow, ma richiedere evidenze da TV e smartphone per hardware/voce/streaming.

> **Importante:** questo audit non prova che la TV sia stata modificata in modo irreversibile. Dimostra invece difetti nella release v16 consegnata. Lo snapshot va mantenuto congelato; la correzione deve avvenire nel codice con test e rollback prima di qualsiasi nuova installazione.
