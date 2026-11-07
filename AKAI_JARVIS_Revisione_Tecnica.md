# AKAI JARVIS — Revisione tecnica statica del pacchetto v15.3

**Data:** 7 novembre 2026  
**Fonte:** `AKAI_JARVIS_Sorgenti_e_File_Funzionamento.zip` (caricato dall'utente; circa 385 KB)  
**Ambito:** sorgenti Android Java, frontend PWA JavaScript, AndroidManifest, script TLS, APK e contenuto archivio.  
**Metodo:** ispezione statica; nessun APK o script eseguito, nessuna connessione alla TV né ai dispositivi mobili. L'ispezione non è un penetration test né una certificazione di funzionamento.

## Sintesi esecutiva

Il progetto è concreto e modulare: launcher separato, un solo demone di controllo TV, REST, accessibilità, adapter LLM, SQLite e TTS. Non è necessario sostituirlo o ricominciare. Tuttavia **non raccomando di caricare API key reali né distribuire questo ZIP/APK nella forma corrente**: contiene materiale TLS privato e altre lacune importanti di protezione, affidabilità e budget.

## P0 — Da correggere subito

### 1. Chiave privata HTTPS inclusa nell'APK e nello ZIP, password hardcoded
- `akai-remote-tv/app/src/main/assets/server_keystore.p12`; stesso file in `binaries/server_keystore.p12` e in `assets/server_keystore.p12` dell'APK precompilato.
- `RemoteServerService.java:174-184` carica il P12 dall'APK con password letterale; `scripts/generate_tv_tls_keystore.ps1:17,25-41` usa la stessa password.
- Ispezione del file PKCS#12: contiene una voce `Shrouded Keybag` (chiave privata); non è soltanto un certificato pubblico.
- **Rischio:** chi riceve il pacchetto può estrarre la credenziale TLS del server e impersonare la TV in circostanze in cui possa deviare o intercettare la connessione. Il Keystore Android delle chiavi API è una protezione diversa.
- **Correzione:** rigenerare certificato e chiave *sulla TV* o in provisioning controllato per dispositivo, salvando la chiave nel private app storage/Android Keystore se compatibile, non in assets né nello ZIP; eliminare la password statica; sostituire il certificato in uso e aggiornare la fiducia dei telefoni con identificazione sicura; non distribuire materiali privati.

### 2. HTTP 8088 continua ad accettare sessioni Bearer e chiavi API
- `RemoteServerService.java:200-215,293-357` avvia HTTP e HTTPS; il routing comune non impone TLS per pairing o configurazione; `RemoteServerService.java:445-465,757-785,627-649` accetta token e nuove credenziali sui medesimi endpoint.
- `akai-remote-web/app.js:12-16,139-140` seleziona il protocollo in base alle impostazioni e conserva il token in localStorage.
- `RemoteServerService.java:1009-1011` usa `Access-Control-Allow-Origin: *` anche per API autenticate.
- **Correzione:** HTTP solo redirect/informazioni pubbliche (oppure disabilitarlo dopo migrazione); autenticazione e configurazione segreti esclusivamente su TLS verificato, rimozione CORS wildcard, limite esplicito di origini affidabili, sessioni ruotate dopo la migrazione.

## P1 — Funzionalità e affidabilità

### 3. Il tetto «5 € totali» non è garantito dal codice
- `AiProviderAdapter.java:381-435` il metodo `testConnection` fa una chiamata reale al provider senza prenotazione né contabilizzazione; `RemoteServerService.java:847-864` espone questa funzione agli utenti autenticati.
- `RemoteServerService.java:795-800` consente `reset_budget` dall'endpoint ordinario; `AiProviderAdapter.java:251-256` azzera il totale.
- `AiProviderAdapter.java:263-326` usa tariffe e cambio USD/EUR hardcoded; stima il prompt da caratteri, con possibile sottostima perché `planActionSequence` aggiunge un ampio system prompt e cronologia (`AiProviderAdapter.java:452-482,520-569`). In error path `AiProviderAdapter.java:483-486,511-515` libera la prenotazione anche se il provider potrebbe aver fatturato.
- **Correzione:** budget guard obbligatorio per *tutti* i percorsi cloud incluso test; limiti di prezzo/configurazione aggiornabili; costo prudenziale dell'intero payload; accounting di richieste incerte; eliminazione del reset con un solo click dal budget non ricorrente (oppure reset esplicitamente controllato dopo verifica del saldo provider); tetto lato fornitore ove disponibile. La fatturazione reale può differire dal contatore dell'app.

### 4. Pool di thread sottodimensionato: rischio di blocchi del telecomando
- `RemoteServerService.java:88` crea `Executors.newFixedThreadPool(4)`.
- `RemoteServerService.java:200-240` e `245-280` occupano stabilmente almeno due worker per i loop `accept()` HTTP/HTTPS, lasciandone al massimo due per client, AI, TTS e polling.
- `RemoteServerService.java:545-560` elabora una chiamata AI in modo sincrono; `RemoteServerService.java:293-362` non impone limite alla dimensione del corpo e alloca `char[contentLength]`.
- **Correzione:** separare acceptor e worker, impostare pool e coda limitati, massimo body/header, timeout end-to-end; gestire richieste AI in modo asincrono con job ID; polling non deve attendere una richiesta LLM bloccata.

### 5. Rischio di falso successo nella riproduzione TV
- `ScreenPerceptionEngine.java:240-248` considera `player_active` vero se il package corrisponde e **un player qualsiasi oppure audio MUSIC** risulta attivo; non verifica che sia *Italia 2*.
- `AkaiAiController.java:99-113` in assenza di una condizione valida usa `cmdRes.success` come prova di completamento; `AkaiAiController.java:115-124` può pronunciare «Ho sintonizzato Italia 2» dopo questa verifica generica.
- **Correzione:** condizioni di successo specifiche per canale/contenuto con più evidenze affidabili; se identificazione canale non disponibile, stato `COMPLETED_UNVERIFIED`, mai `SUCCESS_VERIFIED`. Sospendere procedure che falliscono, riutilizzare verifiche semanticamente robuste.

### 6. Loop vocale multi-turn con possibili race condition e riapertura anticipata del microfono
- `akai-remote-web/app.js:482-510` invia richiesta e poi interroga speech status.
- `akai-remote-web/app.js:512-555` attende 600 ms, poi si ferma al primo `speaking:false` (anche prima dell'avvio reale del TTS), oppure dopo 15 polling da ~450 ms, riaprendo comunque il microfono.
- `/api/ai/speech_status` espone solo il flag globale `speaking` (`RemoteServerService.java:564-571`), senza identificare la risposta o la sessione.
- **Correzione:** job di sintesi con ID e stati `queued/started/completed/failed`, timeout/errore distinti, non riprendere l'ascolto se lo stato è ambiguo, test su due telefoni e risposta lunga. Il VAD attuale dipende dalle trascrizioni `SpeechRecognition.onresult`, non è un VAD audio indipendente.

### 7. Memoria: tetto e durata dei ricordi diversi da quanto promesso
- `AkaiMemoryEngine.java:619-639` conserva solo gli ultimi 20 scambi: non c'è qui una fase verificata di riassunto persistente delle vecchie conversazioni.
- `AkaiMemoryEngine.java:675-713` misura solo `PRAGMA page_count * page_size`; la soglia 15 MB non include automaticamente WAL/SHM, audio TTS e altri log/file. L'unica bonifica documentata elimina vecchie conversazioni e lancia `VACUUM`; non gestisce necessariamente crescita di procedure e preferenze.
- **Correzione:** misurare dimensione reale DB+WAL+SHM e cache; impostare quote per categoria, compattazione fuori streaming, riassunti compatti approvati dall'utente, scadenze e controllo dei dati personali; test con DB vicino alla quota.

### 8. Cache TTS non cifrata e classificazione sensibile parziale
- `CloudSpeechAdapter.java:141-158` scrive MP3 direttamente su disco in cache; il commento del README che parla di cache cifrata non è confermato dal codice.
- `CloudSpeechAdapter.java:297-312` rileva pochi pattern di dati sensibili (password/PIN/token/numeri). Altre informazioni personali possono finire in MP3 memorizzati. I file `tts_tmp_` sono creati per testi sensibili ma la routine di riproduzione `CloudSpeechAdapter.java:171-228` non documenta cancellazione immediata del file al termine della riproduzione.
- **Correzione:** evitare cache di risposte conversazionali per impostazione predefinita, usare cache solo per frasi fisse generiche, cancellare i temporanei dopo la riproduzione, considerare cifratura del contenuto realmente persistito.

## P2 — Manutenibilità e prove di produzione

### 9. Materiale di firma Android incluso
- `binaries/debug.keystore` è incluso nello ZIP. Si tratta di una credenziale di firma per lo sviluppo, non di un file da distribuire.
- **Correzione:** rimuovere dalla distribuzione e conservare separatamente; preparare una strategia di firma per futuri APK, tenendo conto che cambiare certificato su Android può impedire aggiornamenti in-place e richiedere migrazione dati.

### 10. API diagnostica non autenticata
- `RemoteServerService.java:398-420`: GET `/api/diagnostics` serve fino a 2 MB di log senza validazione Bearer. La sola verifica `isPrivateLanIp` non è autenticazione.
- **Correzione:** richiedere una sessione autorizzata e redigere i log per escludere credenziali, query personali e dettagli di rete.

### 11. Le metriche runtime non sono verificabili dai soli sorgenti
- L'archivio contiene APK e sorgenti, ma non una prova nativa ripetibile del PSS 8,2 MB, né test reali iOS Safari/Android Chrome; lo ZIP non contiene i risultati live dell'hardware.
- La pipeline di build dipende da strumenti installati esternamente: la dimensione 384 KB è il peso del pacchetto sorgente, non prova di installazione completamente standalone.
- **Correzione:** raccogliere log sanitizzati e test ripetibili dopo correzioni P0/P1: 20 minuti video + voce, due telefoni, failover TLS, timeout LLM, perdita rete, verifiche Italia 2, audio focus e MemAvailable.

## Ordine di intervento raccomandato

1. **Bloccare la diffusione dell'archivio e ruotare il certificato server**, eliminare la chiave TLS dall'APK e dal pacchetto; conservare solo i certificati pubblici sul telefono.
2. **Spostare pairing/configurazione/controllo su HTTPS autenticato**; togliere accesso sensibile da HTTP, chiudere CORS wildcard e proteggere diagnostica.
3. **Correggere accounting budget**, includendo `testConnection` e timeout fatturabili, evitare reset che vanifichi il tetto di 5 €.
4. **Separare acceptor/workers**, correggere limiti input e backpressure per non bloccare il telecomando.
5. **Riparare le prove di stato dei contenuti** (Italia 2), con esiti realmente verificabili.
6. **Rendere il turno vocale identificabile** con eventi di fine-sintesi, no polling globale ambiguo.
7. **Rendere la memoria e cache realmente limitate** e verificare RAM/storage sotto carico.
8. Solo dopo fare il collaudo iOS/Android completo con credenziali autentiche e provider cloud a budget concordato.

## Invarianti da preservare

- `it.akai.customremote` resta l'unico demone Android TV; `it.akai.customhome` resta launcher; nessun secondo assistente.
- Nessun flashing del firmware o modifiche al DRM.
- Compatibilità Android 9 API 28, ARMv7 e RAM circa 1,5 GB.
- Esecuzione locale 0 token per azioni note, SQLite leggero, fallimenti dichiarati, TTS su altoparlanti della TV, iPhone/Android come microfoni.
- Budget di 5 € è preventivo e va verificato anche nel conto/provider, non può essere garantito al centesimo dal solo codice client.
