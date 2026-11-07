# AKAI JARVIS v15.3 — Revisione completa dei sorgenti e proposta UX v16

**Data:** 7 novembre 2026  
**Archivio ispezionato:** `AKAI_JARVIS_Sorgenti_e_File_Funzionamento.zip` (102 voci; versione fornita in chat).  
**Tipo di esame:** revisione statica del server Android, AI, controller TV, memoria, TTS, sicurezza, interfaccia web, service worker, launcher, manifest, script e test; esecuzione dei test host-side disponibili.  
**Limite:** non è stato possibile installare gli APK, interagire con la TV AKAI reale o collaudare Safari/Chrome su telefoni veri. Tutti i risultati runtime presentati da Antigravity rimangono dichiarazioni esterne, non riproduzioni di questa revisione. Le proposte grafiche sono autonome e non sono ancora parte della build APK.

## Sintesi esecutiva

**Decisione:** conservare `it.akai.customremote`, `it.akai.customhome`, SQLite e le API esistenti. **Non aggiungere un nuovo assistente**. Prima correggere la rete/API, poi i falsi esiti, poi il protocollo delle conversazioni vocali. Solo dopo integrare il nuovo layout mobile.

Il limite monetario è impostato dall'utente presso il provider. L'accounting applicativo può restare informativo, evitando che messaggi UI lo spaccino per garanzia del saldo reale; non è la priorità di questa revisione.

## P0 — Errori da correggere prima di dichiarare l'app pronta

### P0-01 — Parser HTTP legge caratteri invece di byte
**Evidenza:** `akai-remote-tv/app/src/main/java/it/akai/customremote/RemoteServerService.java:299–345` usa `BufferedReader` UTF-8 e legge un `char[contentLength]`, mentre l'header `Content-Length` è espresso in **byte**. Es.: `{"query":"più"}` contiene un carattere `ù` codificato in due byte; il server prova a leggere un carattere in più. Può restare in attesa fino al timeout di socket e non rispondere correttamente. Il parser non limita il `Content-Length` né le dimensioni degli header e non verifica che il corpo sia stato letto integralmente.

**Fix:** parser HTTP robusto o libreria adatta ad Android 9; leggere fino a esattamente N **byte** dal flusso binario con limiti (es. body JSON ≤ 32 KB), convertire solo dopo con UTF-8; timeout e risposte HTTP 400/413 esplicite; limitare dimensione header, validare `Content-Length`, `Transfer-Encoding`, metodo e Content-Type. Evitare di mescolare BufferedReader read-ahead e InputStream sullo stesso socket. 

**Test:** `cambia volume`, `più forte`, `cos'è`, `perché`, emoji, Unicode composto, body chunked non supportato, 32 KB/32 KB+1, corpo troncato. Nessuna richiesta deve bloccarsi.

### P0-02 — Le sequenze di azioni possono fallire e restituire comunque successo
**Evidenza:** `TvController.java:269–347`. `executeActionSequence` ignora i `CommandResult` di `launchAppPackage`, `executeCommand`, `setVolumeAbsolute`, `tuneDtvChannel`. Non interrompe la sequenza se `clickNodeByText` fallisce (`:295–307`). Scarta tipi di azione sconosciuti (`:337–340`) ma restituisce `CommandResult(true, ...)` a fine ciclo (`:342`). Anche `tuneDtvChannel` (`:247–265`) può restituire `true` senza UInput disponibile o invio riuscito.

**Fix:** esito strutturato per ogni step (`success`, `reason`, `observed_state`, `elapsed_ms`), interrompere su fallimento significativo, allowlist dei tipi/parametri, massimo step e durata/wait; distinguere `SENT`, `ACTION_CONFIRMED`, `TARGET_VERIFIED`; non considerare un broadcast come prova della sintonizzazione.

**Test:** app inesistente, nodo UI assente, UInput disabilitato, comando sconosciuto, step successivo non deve proseguire; nessuna procedura fallita può essere salvata come riuscita.

### P0-03 — Memorie «verificate» vengono create senza collaudo e possono sovrascrivere procedure reali
**Evidenza:** `AkaiMemoryEngine.java:194–294` crea da codice le procedure Italia 2 e Rai 1 con `success_count=1` e `last_verified=now`. Italia 2 contiene **11 pressioni a destra** (`:227–232`), la condizione `player_active` generica (`:241`). `onUpgrade` richiama il seeding per versioni inferiori a 4 e 5 (`:167–190`), usando `CONFLICT_REPLACE` (`:248`, `:273`): una migrazione può sostituire procedure precedentemente modificate o apprese. `resetProcedures()` richiama **`seedInitialData`** (`:501–506`), che reinserisce anche **preferenze e statistiche** (`:194–211`), rischiando di sovrascrivere preferenze dell'utente e contatori.

**Fix:** procedure iniziali marcate `UNVERIFIED_TEMPLATE`, mai con `last_verified=now`; non riseminare in migrazione senza preservare record appresi; resettare solo la tabella procedural_memory e lasciare intatte preferenze, cronologia e statistiche. Eliminare o invalidare la macro non affidabile «Italia 2».

**Test:** migrazione v4→v5 preserva procedura custom; reset delle procedure non modifica preferenze; Italia 2 non è dichiarato riuscito se si apre Harry Potter/una Home.

### P0-04 — Chiave privata TLS riutilizzabile distribuita nell'APK
**Evidenza:** `RemoteServerService.java:174–184` carica `server_keystore.p12` dagli asset con password hardcoded; chiave presente anche in `binaries/server_keystore.p12`. File di firma `binaries/debug.keystore` incluso. `generate_tv_tls_keystore.ps1` incorpora password analoga. **L'APK e lo ZIP non sono contenitori segreti.**

**Fix:** credenziale TLS unica per installazione, chiave privata mai distribuita, conservazione in spazio privato o Keystore Android quando fattibile. Sostituire certificati fidati solo dopo verifica dell'identità/fingerprint e procedura di migrazione. Escludere dalla release `*.p12`, `debug.keystore`, altre chiavi private. Nota: questa revisione non esegue né consegna un bundle con chiavi private.

### P0-05 — Accesso HTTP alle funzioni sensibili e diagnostica aperta
**Evidenza:** HTTP 8088 e HTTPS 8443 usano `routeRequest` comune; nessun controllo TLS per pairing, token e configurazione (`RemoteServerService.java:200–366,423–465,757–785`). `/api/diagnostics` non richiede autenticazione (`:398–420`); risposta con `Access-Control-Allow-Origin: *` (`:1004–1012`). `AndroidManifest.xml:31–36` dichiara `allowBackup="true"`, non ideale per app che gestisce credenziali e sessioni.

**Fix:** HTTPS verificato per endpoint sensibili, HTTP soltanto bootstrap/redirect senza segreti; autentica diagnostica, minimizza i log, restrizioni Origin/CORS e request size; backup disattivato o rules granulari che escludano dati sensibili. L'affidabilità del certificato su iOS/Android va testata realmente.

## P1 — Bug funzionali, conversazione e affidabilità

### P1-01 — Pool esauribile: il telecomando può impallarsi
`RemoteServerService.java:88,200–290,545–560`: 4 thread per 2 loop `accept()` permanenti e tutte le richieste HTTP, AI, DB e TTS; Azure Speech esegue download sincrono (`CloudSpeechAdapter.java:74–103,106–169`). Due richieste lente bastano a bloccare il servizio. **Fix:** acceptor dedicati, thread pool bounded distinto dal queue executor per AI/TTS, limite concorrenza e deadline; evitare che polling/stato attenda un LLM.

### P1-02 — Il medesimo turno vocale può partire più volte
`akai-remote-web/app.js:352–415,482–510`: `onresult(final)`, timer di 1400 ms e `onend` possono richiamare `commitTurn`; manca un flag/ID per turno o lock; `commitTurn` non verifica che lo stato sia `LISTENING` e la sessione corrente. **Fix:** `sessionId`, `turnId`, stato atomico `LISTENING → SUBMITTING`, dedup per final/interim e `AbortController`, scarto di callback di sessioni superate.

### P1-03 — Microfono riaperto prima della fine reale della voce
`app.js:512–555` assume che il primo `speaking:false` dopo 600 ms sia la fine; interrompe il polling dopo 15 tentativi e riapre comunque. `AkaiSpeechEngine.java:210–212` usa due booleani aggiornati solo quando TTS inizia/riproduce; il download Azure e `prepareAsync` avvengono prima di `mIsPlaying=true` (`CloudSpeechAdapter.java:84–97,171–221`). **Fix:** TTS con `speech_id`, eventi `QUEUED→FETCHING→PREPARING→STARTED→DONE|ERROR|CANCELLED`, `GET /speech_status?id=...`; non riavviare microfono per stato ambiguo. Gestire più telefoni, stop ed errori senza eco.

### P1-04 — Nessun timeout/annullamento lato browser
`app.js:585–626` invia `/api/ai/ask` senza timeout `fetch` e `commitTurn` attende sempre `askAi`, anche dopo Stop (`:482–509`). Un vecchio risultato può contaminare la nuova sessione. **Fix:** `AbortController`, timeout 20–30 s (o job async), `sessionId`/`turnId`, disabilita invio concorrente, UI errore/Riprova, annulla il pending sullo Stop.

### P1-05 — Esito API e toast troppo ottimistici
`RemoteServerService.java:545–561` restituisce sempre HTTP 200 anche se `aiRes.status` è `ERROR` / `COMPLETED_UNVERIFIED`. `app.js:613–615` visualizza «Comando completato» quando `verified=false`, senza verificare `data.success`. `displayAiResponse` mostra default «Comando completato» quando non c'è reply (`:629–665`). **Fix:** contratto errori stabile, `success`, `verified`, `status`, `reason`, request ID, never say success on unknown; test UI dei fallimenti.

### P1-06 — `player_active` non prova identità del canale
`ScreenPerceptionEngine.java:240–249`: basta package app più un SurfaceView o MUSIC attivo. Non verifica Italia 2, Rai 1 o il contenuto riprodotto. **Fix:** verificadori specifici per app/contenuto, evidenze UI/accessibility/MediaSession quando disponibili, `UNVERIFIED` se non si può dimostrare. Il codice attuale non effettua una vera esplorazione osserva-decidere per ciascun passo: esegue macro e verifica quasi solo alla fine.

### P1-07 — Modalità ospite e «elimina dati personali» incomplete
`AkaiMemoryEngine.java:619–641` salva ogni conversazione senza controllo `isGuestMode()`; `clearPersonalPreferencesOnly()` (`:602–611`) elimina preferenze personali ma **non la tabella `conversations`**. L'API dichiara «Memorie personali eliminate» (`RemoteServerService.java:829–844`) e l'utente può credere che siano sparite tutte. **Fix:** guest non persistente per testi/ricordi, separazione di sessioni per dispositivo/profilo, cancellazione completa e verificabile dei dati personali (con opzione preserva procedure tecniche).

### P1-08 — Azzeramento procedure altera impostazioni utente
`AkaiMemoryEngine.java:501–506` richiama il seed globale: può ripristinare canali/genre/app favoriti predefiniti e statistiche quando l'utente sceglie «Reset procedure». **Fix:** test di regressione delle preferenze; reset isolato della sola tabella.

### P1-09 — `Clear cache` può eliminare un file mentre viene riprodotto
`CloudSpeechAdapter.java:171–228,259–295`: cache MP3 e file temporanei nell'unica directory; LRU può cancellare file in uso; `tts_tmp_` non è eliminato esplicitamente su completion/error/stop. Il client **non** fa streaming Azure→MediaPlayer: scarica prima un MP3 su file. **Fix:** file temporanei atomici, lifecycle di cancellazione, cache solo di frasi generiche, non di dialoghi personali, esclusione file in uso dalla pulizia.

### P1-10 — AudioFocus usa richieste diverse per acquisire e rilasciare
`AkaiSpeechEngine.java:264–295` e `CloudSpeechAdapter.java:337–368`: su Android 8+ `requestAudioFocus(AudioFocusRequest)` ma `abandonAudioFocus(mFocusListener)`; occorre trattenere lo stesso `AudioFocusRequest` e usare la forma di abbandono corrispondente. **Fix:** un unico gestore AudioFocus con request persistente e log verificabili; evitare focus posseduto contemporaneamente da cloud e offline.

### P1-11 — Certificato, host e IP statico rendono fragile il pairing
`app.js:12–16`, `index.html:315–325` e `RemoteServerService.java:1035–1051` fissano/fanno fallback a `192.168.1.8`; cambiare IP rompe URL e SAN del certificato. **Fix:** hostname locale affidabile e discovery/pairing QR, non usare un certificato per IP che potrebbe cambiare; configurare riserva DHCP o provisioning.

### P1-12 — Token scaduto difficile da riassociare
`app.js:1480–1487`: cliccando lo stato connessione, se `state.token` esiste chiama solo `checkConnection()`, anche quando il server risponde 401, senza proporre una nuova associazione. **Fix:** 401 → rimuovi/segna token scaduto, apri pairing con richiesta esplicita, conserva spiegazione all'utente.

### P1-13 — Revoca mostrata come completata anche senza conferma
`app.js:1252–1267`: l'errore di rete nella POST `/api/auth/revoke` viene ignorato, il token viene cancellato dal telefono, poi toast «Sessione revocata», anche se il server potrebbe non averlo revocato. **Fix:** distinguere revoca lato server da eliminazione token locale, eventuale comando di revoca da TV.

### P1-14 — Il parser italiano perde accenti
`LocalIntentParser.java:60–62` usa `replaceAll("[^a-z0-9\\+\\s]", " ")`; «più forte» diventa «pi forte», mentre il parser cerca `piu forte` (`:79`). **Fix:** Unicode NFD e rimozione dei soli segni diacritici, tokenizzazione italiana e test espressivi/negazioni. Non usare matcher di sottostringa che confondono comandi opposti.

### P1-15 — Progressi voce e memoria sono globali, non isolati per smartphone
`RemoteServerService.java:564–571` fornisce stato globale TTS; `AkaiAiController.java:192–194` recupera tre ultimi scambi globali. Con due telefoni, conversazioni e microfono possono interferire e le domande dell'uno recuperano contesto dell'altro. **Fix:** profili/sessioni autorizzate e contesto per `conversation_id`, con condivisione esplicita dei ricordi tecnici.

### P1-16 — Messaggi di successo conversazionale impropriamente «verificati»
`AkaiAiController.java:204–220`: risposte del LLM senza azioni vengono dichiarate `SUCCESS_VERIFIED` e `verified=true` anche quando sono semplici consigli o informazioni non verificate. **Fix:** distinguere `ANSWERED` da `TARGET_VERIFIED` e da `NOT_VERIFIABLE`.

## P2 — UX, qualità e manutenzione

### P2-01 — PWA Service Worker non registrato nei sorgenti
`akai-remote-web/sw.js` esiste, ma non compare alcun `navigator.serviceWorker.register()` in `app.js` o `index.html`; quindi il worker non è attivato dai file visibili. Inoltre `CACHE_NAME='akai-remote-v1'` fisso (`sw.js:1`) e politica cache-first possono lasciare versioni vecchie dopo un aggiornamento, se mai il worker viene registrato. **Fix:** registrazione HTTPS, versioning per build, network-first o stale-while-revalidate per shell; API mai cache; nessuna falsa promessa offline per il riconoscimento vocale.

### P2-02 — Orb principale non accessibile da tastiera/assistive technology
`index.html:61` usa `<div id="jarvis-orb">` cliccabile, non `<button>`, senza ruolo, `aria-label`, navigazione tastiera o stato `aria-pressed`. **Fix:** `<button type="button">`, stato accessibile; `aria-live="polite"` per stato e trascrizione.

### P2-03 — Zoom disabilitato e testo troppo piccolo
`index.html:5` imposta `maximum-scale=1, user-scalable=no`; `style.css` contiene numerosi testi di 10–11 px. **Fix:** consentire zoom, font ≥ 13–14px per metadati principali e ≥ 16px per testo di conversazione, target touch ≥ 44×44px, contrasto WCAG, gestione font ingranditi.

### P2-04 — Gerarchia visiva confusa
Screenshot HTML/CSS a viewport 390px: orb e input vocale duplicano il microfono; pannello vocale, sorgenti, D-Pad, volumi, input testo e app sono tutti nella stessa pagina scrollabile. I controlli più bassi compaiono sotto lo scroll; stato e nomi tecnici sono troppo prominenti. **Fix:** layout mobile con 3 sezioni (Assistente, Telecomando, Attività), impostazioni avanzate separate, una sola azione primaria per modalità.

### P2-05 — Error feedback e caricamenti non progettati per recupero
Toast di 2,5 secondi (`app.js:151–160`), modali senza gestione Escape/focus, nessuno stato `retry`, nessuna conferma permanente quando il server perde la connessione. **Fix:** banner recuperabile, retry contestuale, focus management, loading cancellabile, report di verifica in linguaggio utente.

### P2-06 — Modelli non validati prima del salvataggio
`AiProviderAdapter.java:121–146`: il model id è una stringa persistita senza validazione; cambiare provider non normalizza sempre un modello incompatibile. **Fix:** catalogo versionato dal provider, check esistenza, fallback solo previa notifica e nessun consumo API non autorizzato.

### P2-07 — I test host non coprono i bug emersi
`akai-remote-tests/UnitTests.java` contiene 9 test principalmente su PIN, token, subnet, QR; «Test 7» incrementa PASS senza verificare nulla. Non copre parser HTTP, error propagation, speech lifecycle, SQLite migrations, media, PWA, UI. **Fix:** test unit/integration nuovi con fixture Android e browser mock, poi real device test.

### P2-08 — Compilazione e distribuzione non riproducibili direttamente dallo ZIP
`run_unit_tests.ps1` e gli script build usano path assoluti Windows e toolchain esterna; gli APK sono inclusi ma il pacchetto da 384 KB non è un ambiente di build autonomo. **Fix:** variabili di progetto basate su `$PSScriptRoot`, README prerequisiti/versioni, checksum/artifact manifest, release ZIP senza segreti, smoke test APK e procedura rollback documentata.

## Verifiche effettivamente eseguite durante questa revisione

- `node --check akai-remote-web/app.js` e `node --check akai-remote-web/sw.js`: **OK** (sintassi JavaScript). Questo NON prova l'assenza di bug logici.
- `javac` e `java` contro gli host mock e `UnitTests.java`: **9/9 PASS**. Copertura limitata come indicato sopra.
- Ispezione struttura HTML: **85 ID distinti e nessun ID duplicato**; orb è un `div` interattivo senza semantica di bottone.
- Confronto dei file Web Remote nella cartella root e negli assets Android (`app.js`, `style.css`): **identici** in questo ZIP.
- Rendering statico viewport **390×844**: il layout originale richiede scroll verticale (altezza documento ~1130px); acquisita screenshot `akai_review/current_mobile.png`.
- **Non effettuati:** esecuzione APK reale, collaudo microfono Safari/Android, test Azure reale, player Italia 2, streaming, misura PSS, test Android Accessibility, emissione TTS reale.

## Design UX v16 — Non riscrivere il backend

**Prototipo:** `AKAI_JARVIS_v16_anteprima_interfaccia.html` — file HTML indipendente e dimostrativo, senza rete e senza accesso al microfono.

1. **Assistente:** una sola orb e CTA grande, stato `Pronto / Ascolto / Elaboro / Parlo / Errore`, trascrizione e risposta, Stop sempre visibile durante la sessione. Non mostrare badge tecnici in primo piano.
2. **Telecomando:** D-Pad e OK grandi, Home/Back/Menu, Volume e Canale, ingresso HDMI/TV, scorciatoie. Layout di una mano, con tattilità ≥44px.
3. **Attività:** cronologia conversazioni ed esecuzioni con prove, `Verificato` solo quando realmente supportato, `Non verificato` e pulsante `Riprova` quando necessario.
4. **Impostazioni:** connessione TV, dispositivi associati, voce, API, privacy, diagnostica e memoria; mantenere queste funzioni, ma fuori dal percorso quotidiano.
5. **Qualità visiva:** dark navy, accento turchese e viola contenuti, tipografia 16px+, bordi e gerarchia coerenti, motion ridotta per accessibilità, adattamento iOS Safe Area e Android; evitare animazioni continue troppo pesanti.

**Importante:** il prototipo è SOLO un mockup interattivo, non un Web Remote sostitutivo. Gemini deve riutilizzare i DOM ID/endpoint funzionanti dell'app in produzione oppure migrare con test di compatibilità. Non copiare il prototipo sopra `index.html` senza collegamenti, smoke test e rollback.

## Piano di correzione e criteri di accettazione

**Wave A — Rete/affidabilità (prima di qualsiasi nuovo stile):** parser UTF-8 a byte, request limits, thread pool, HTTP/TLS, token scaduti. Test Unicode e 10 richieste concorrenti mentre un'AI call è lenta; volume/Home devono continuare a rispondere.

**Wave B — Motore azioni e memoria:** propagazione dei fallimenti step-by-step, condizioni di successo semantiche, eliminazione dei seed «verificati» fittizi, reset e upgrade isolati, guest privacy. Test «Italia 2 da Harry Potter»/«Italia 2 da Home» con prove verificabili e cancellazione memoria personale.

**Wave C — Conversazione:** un turno per volta, `sessionId`/`turnId`/`speechId`, timeout e cancel, TTS queue/start/done, vero fallback, due telefoni. Test 3–5 turni reali in Safari iOS e Chrome Android; la TV parla, il telefono tace durante la risposta e si riattiva correttamente.

**Wave D — UI v16:** integrare il concept nel Web Remote attuale, accessibilità e impostazioni, aggiornamento PWA affidabile e screenshot 360/390/430px e tablet. Verificare che un utente trovi D-Pad, Home e volume in massimo un tocco dal tab Telecomando.

**Wave E — Collaudo di stabilità:** misurare PSS + MemAvailable (non solo PSS del demone), 30 minuti di streaming+comandi+voce, reboot TV, nessuna regressione su RaiPlay/Mediaset/launcher; preparare rollback firmato dalla stessa chiave release, senza includere il keystore nell'archivio condiviso.
