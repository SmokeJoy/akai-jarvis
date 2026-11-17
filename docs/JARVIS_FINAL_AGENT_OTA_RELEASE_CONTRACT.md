# AKAI JARVIS — Contratto di rilascio dell'agente autonomo e OTA (17/11/2026)

## Decisione del proprietario

- **Televisore attuale:** AKAI AKTV5037N, Android 9/API 28, ARMv7, RAM circa 1,5 GB. App `it.akai.customremote` A2 Preview `versionCode=3`, installata il 17/11/2026 e collaudata **solo per bootstrap**: `/api/status=ok`, `uinput_ready=true`, HTTP 200 e TLS operativo con fiducia CA OOB ancora da verificare.
- **Freeze hardware:** nessun altro aggiornamento/intervento sulla TV durante lo sviluppo, salvo necessità reale approvata esplicitamente. Niente auto-install, auto-deploy, merge automatico, uninstall, reset, root o mutazioni SQLite via CI/automazioni.
- **Priorità:** completare un agente autonomo realmente utile; OTA solo se non introduce un rischio maggiore e non aumenta sensibilmente memoria/processi.
- **REGOLA PERMANENTE E NON NEGOZIABILE (OWNER 17/11/2026): L'INFERENZA AI DI JARVIS USA ESCLUSIVAMENTE MODELLI CLOUD DEEPSEEK O KIMI (MOONSHOT), TRAMITE LE RISPETTIVE API. NESSUN ALTRO PROVIDER; NESSUN MODELLO AI LOCALE, NEMMENO COME FALLBACK, SU TV O PC.** La TV non ha hardware per eseguire LLM locali. Nessun Ollama, LM Studio, ONNX LLM, Termux ML, mini-LLM o stack AI terzo. Le API cloud richiedono consenso, credenziali e budget configurati dall'owner.
- **Eccezione voce del proprietario (17/11/2026):** il vincolo DeepSeek/Kimi rimane assoluto per ragionamento, pianificazione, percezione e comandi AI. Su richiesta esplicita di una **voce italiana più naturale ma gratuita**, è consentita soltanto la *sintesi di output vocale* tramite account **FreeTTS personale Free**, opt-in separato. Non è un terzo provider di agenti o un LLM locale. Vietato Azure con account dell'utente, upgrade, piano a consumo, chiamate TTS a pagamento o installazioni intermedie.
- **Distinzione rigorosa:** tasti, navigazione, policy, accessibilità, lettura SQLite, intent semplici e parser deterministici possono girare *localmente* perché sono **codice tradizionale, non modelli AI**. La modalità `LOCAL_ONLY`/provider `local` eventualmente presente nello storico significa solamente **nessuna chiamata AI** e comandi deterministici, mai un LLM on-device. Se un compito richiede inferenza e DeepSeek/Kimi non sono disponibili/autorizzati, JARVIS deve dichiarare indisponibilità, non eseguire un altro modello.
- **Vincolo di codice:** `CloudProviderPolicy` deve rifiutare ogni nome di provider diverso da `deepseek` e `kimi` per chiamate AI, impedire endpoint incrociati (inclusa fuga chiave API), non seguire redirect con `Authorization` e avere test regressivi negativi in CI. Nessun nome di modello locale o terzo aggiunto alle preferenze.
- **Sviluppo:** branch e PR draft, test CI + mock prima di ogni richiesta di collaudo reale. Accogliere report utente A2 senza confondere simulazioni e prove sul dispositivo.

## Baseline e rollback

- APK A1, DB SQLite e identità TLS salvati prima di A2 in `C:\Users\danie\JARVIS-backup-TV\backup_20261117_002515`; vault DPAPI separato sotto `%LOCALAPPDATA%\AkaiTvSecureVault\it.akai.customremote\backup_20261117_002515\tls_identity`.
- Esiste anche il backup `backup_20261117_001805` con 5/5 file TLS verificati indipendentemente.
- L'installazione A2 ha richiesto l'approvazione esplicita dell'utente, con APK firmato dallo stesso certificato e script locale corretto (non committato).
- Rollback **non ancora collaudato sul caso reale A2→A1**: non dichiararlo garantito. Schema SQLite e certificati HTTPS sono parte inseparabile del recupero.

## Requisiti di accettazione: agente completo

1. **Apertura app:** inventario locale delle app effettivamente installate e avviabili; nome esatto, package reale, nessun package inventato e nessun token cloud per `apri <app>`.
2. **Percezione e navigazione:** prima Accessibility, etichette realmente cliccabili, esecuzione stepwise con ricattura UI, fallback su schermi opachi **solo con consenso esplicito MediaProjection**; no click ciechi su schermi non osservabili. Se il contenuto DRM resta opaco, dichiarare limite.
3. **Interpretazione cloud:** DeepSeek/Kimi configurabile, consenso separato per dati UI e immagini, modello realmente compatibile con input multimodale, budget/tokens e limiti di chiamate. Per DeepSeek, la [guida Vision ufficiale](https://api-docs.deepseek.com/guides/vision/) aggiornata al 17/11/2026 documenta input JPEG/PNG in Chat Completions con modello `deepseek-flash`: è un possibile backend, **non ancora un'integrazione JARVIS implementata o collaudata**. Verificare separatamente il modello Kimi scelto. Non inviare schermate con credenziali, pairing o dati sensibili.
4. **Obiettivo finale:** distinguere `COMMAND_SENT` da `STATE_VERIFIED`. `launch_app` non prova la riproduzione; verificare app in foreground, UI, stato player e, per dirette, identità del canale visibile quando possibile. Nessuna falsa skill appresa.
5. **Memoria:** SQLite consistenza e WAL/checkpoint, solo successi comprovati, limiti di spazio, cancellazione/rollback controllati; nessun auto-learning su esiti ambigui.
6. **Controlli operativi:** annullamento immediato, limiti su azioni/tempo/replanning/consumo; comandi distruttivi o acquisti devono essere bloccati senza conferma proprietario.
7. **Affidabilità:** TV riparte dopo reboot, telecomando Web da smartphone senza PC, tasti D-pad/Home/Back e launcher Home v8 non regressivi; RAM/CPU e file descriptor limitati.
8. **Test reale finale:** scenari italiani (Nova Player/YouTube/Mediaset Infinity Italia 2, impostazioni audio, app non installata, UI ambigua, schermata protetta, assenza rete/provider, reboot e cancel). Rapporto PASS/FAIL per comportamento effettivamente osservato.
9. **Rilascio:** build Android 9 ARMv7 da HEAD revisionato, firma originale locale, zero keystore TLS nell'APK, CI verde, backup aggiornato APK+SQLite+TLS, piano di recupero, approvazione esplicita prima dell'unico deploy finale.

## Incremento implementato in PR #18 — Inferenza soltanto DeepSeek/Kimi

- `CloudProviderPolicy.java` autorizza esclusivamente endpoint ufficiali DeepSeek (`api.deepseek.com/chat/completions`) e Kimi (`api.moonshot.ai/.cn/v1/chat/completions`), lega le credenziali al provider e blocca redirect dell'header Bearer. La modalità senza cloud è soltanto esecuzione di regole deterministiche: **mai LLM locale**.
- `CloudVisionRequestPolicy.java` impone tre prerequisiti distinti prima di trasferire un JPEG: consenso MediaProjection Android, consenso esplicito **all'invio cloud di questa immagine**, e consenso cloud nelle preferenze. Blocca schermate sensibili e payload oltre 256 KiB/960×540. Solo `deepseek-flash` o `kimi-k2.6` per immagini; ogni altro modello rifiutato.
- `AiProviderAdapter.describeScreenJpegOnce` invia via HTTPS un singolo JPEG base64 in RAM, con prenotazione conservativa del budget condiviso, e restituisce **testo non attendibile**: l'AI non clicca né apprende procedure dalla descrizione visiva.
- `LocalVisualCaptureActivity` espone, dopo una cattura locale, un pulsante separato con conferma per inviare a DeepSeek/Kimi. Nessun servizio di AI residente, upload automatico, screenshot persistente o nuovo processo stabile.
- Compilazione/unit test host e Android CI in verifica sulla SHA esatta. Nessuna chiamata API fatturabile eseguita e nessuna modifica alla TV. **Non dichiarare l'agente visuale autonomo completo**: la prossima fase dovrà integrare le evidenze visive nel planner in modo verificabile, senza click ciechi e con consenso distinto.

Riferimenti: [DeepSeek Vision](https://api-docs.deepseek.com/guides/vision/), [Kimi K2.6](https://huggingface.co/moonshotai/Kimi-K2.6) (modello ufficiale Moonshot, supporto image input).

## Incremento di sviluppo: handoff visivo verso il planner (nessun deploy intermedio)

- `VisualObservationBridge.java` conserva **solo una descrizione testuale** restituita da DeepSeek/Kimi, mai il JPEG: TTL massimo 45 s, una sola lettura, vincolo sullo **stesso provider, package Android e fingerprint dello snapshot Accessibility redatto**. Un cambio schermata, una schermata sensibile, un provider diverso o un testo potenzialmente iniettato invalidano il passaggio.
- La `LocalVisualCaptureActivity` registra l'origine della schermata al momento del frame (package/UI redatta) e, solo se l'owner ha autorizzato l'invio separato e la descrizione cloud è ritornata, permette di usare **una volta** la descrizione nel successivo piano. Pulsante "Torna alla TV" per riprendere il contesto; "Cancella anteprima" revoca l'osservazione.
- `AkaiAiController` consuma il testo soltanto nel successivo `planActionSequence` cloud, come JSON `untrusted_visual_description`, con flag `visual_description_is_click_authority=false` e `visual_description_is_goal_evidence=false`. **Tutti i click continuano a passare da `UiClickTargetGate` e snapshot Accessibility aggiornato**. Una descrizione visiva non può provare il completamento dell'obiettivo o autorizzare coordinate/click non osservabili.
- Regressioni: `VisualObservationBridgeTest.java` e step CI `4e`, oltre alla compilazione Android 9/ARMv7 del codice reale. Nessun dato passa a un modello AI locale, nessuna scrittura su SQLite.
- **Limite esplicito:** questo è un ponte informativo verso il planner, non ancora navigazione pixel/coordinate autonoma o visual goal verification. Su app DRM e UI non accessibili il sistema deve fallire in modo sicuro. Verifiche attuali host/mock non equivalgono a TV collaudata.

## Obiettivo prioritario del proprietario — screenshot ripetuti e memoria che migliora (17/11/2026)

L'agente finale deve saper navigare **fra tutte le app TV, nei limiti tecnici e dei contenuti protetti**, tramite ciclo multipasso:

1. Cattura subito uno snapshot Accessibility. Se lo stato è ambiguo/insufficiente, acquisisci **uno screenshot reale della schermata corrente** con MediaProjection autorizzata; invialo esclusivamente a DeepSeek/Kimi dopo consenso cloud.
2. L'AI cloud interpreta la schermata (non la TV) e propone una singola prossima azione strutturata. Esegui solo azioni validate per il contesto corrente; non eseguire testo libero proveniente da schermate o immagini.
3. Dopo *ogni* cambio di app, schermata o step significativo, osserva di nuovo. Se serve, acquisisci un nuovo frame **nella stessa sessione MediaProjection già autorizzata** (non riutilizzare l'intent Android per creare un'altra sessione). Nessuno streaming video continuo, periodic polling/recording o screenshot indiscriminato. Trattare lo stato hardware come fonte di verità.
4. Evita click ciechi quando manca un target Accessibility. Per interfacce non accessibili, eventuale navigazione visuale richiede una procedura distinta di click su coordinate corroborate da frame *corrente*, limiti spaziali, validazione di esito e nuova autorizzazione progettuale: **non è ancora implementata**.
5. Ripeti con massimo numero di azioni/frame/chiamate cloud/tempo e stop esplicito; no bypass su DRM, schermate protette o credenziali. Verifica il vero obiettivo (es. riproduzione Italia 2, non solo apertura Infinity) prima di dichiarare success.
6. Memorizza in SQLite **solo procedure effettivamente verificate**, con condizione di successo e origine, successi/fallimenti, limite di riuso e quarantena dei percorsi difettosi. Rigioca skill con 0 token quando possibile; se app/UI cambia, non insistere sul vecchio percorso.
7. **Auto-miglioramento va distinto dall'auto-codifica:** il primo significa apprendere e rivalidare procedure durante l'uso della TV; il secondo richiederebbe developer agent cloud, GitHub PR/CI/revisione ed installazione autorizzata: non permettere auto-patch o auto-install sulla TV.

**Incremento committato:** `VisualCaptureSessionGate.java` e `VisualCaptureSessionGateTest.java` definiscono limiti deterministici di una futura sessione MediaProjection multi-frame (fino a 3 min / 20 frame on-demand / distanza ≥750ms / 3 errori consecutivi), conferma Android e consenso cloud separati, provider DeepSeek/Kimi, blocco DRM/sensibili, interruzione/expiry. Il gate non acquisisce ancora pixel: l'**acquisizione multi-frame collegata all'esecutore Android** è ancora in sviluppo. Serve una sessione Android 9 effettiva, con ciclo di vita e stop corretto. Si evita qualsiasi modello locale. Per target Android 9 (API 28) valutare ciclo vita activity/service compatibile e conferma riproducibile su TV prima del rilascio.

Riferimenti Android ufficiali: https://developer.android.com/media/grow/media-projection e https://developer.android.com/reference/android/media/projection/MediaProjection (consenso per sessione, un VirtualDisplay da riutilizzare per frame della stessa sessione, rilascio in onStop).

## Implementazione agente autonomo multi-frame (PR #18, non installato sulla TV)

Questa parte era P0 e ora ha **codice reale nel ramo di sviluppo**, distinto dall'A2 sul televisore:

- `VisualProjectionService.java`: nuovo servizio Android 9 **non esportato**, foreground durante la sessione, `START_NOT_STICKY`, una sola `MediaProjection` e un solo `VirtualDisplay`/ImageReader; cattura on-demand nuovi JPEG al cambio UI, RAM soltanto, 960×540, massimo 256 KiB, rifiuto nero/DRM, STOP notifica, pulizia risorse. Mai registrazioni continue, reboot autostart o LLM locale.
- `LocalVisualCaptureActivity.java`: dialogo specifico di approvazione invio immagini DeepSeek/Kimi per sessione, seguito dal consenso di cattura Android, pulsante di arresto. La vecchia cattura diagnostica singola resta disponibile.
- `VisualCaptureSessionGate.java`: per sessione fino a 3 minuti / 20 frame on-demand / massimo 3 errori cattura consecutivi, minimo 750 ms fra foto, provider immutabile, schermi sensibili bloccati. Un task JARVIS è limitato a 2 minuti / 8 azioni / 16 chiamate cloud.
- `VisionSessionCoordinator.java`: attesa limitata del nuovo frame, confronto snapshot Accessibility attuale con fonte di cattura, richiesta HTTPS con API DeepSeek Flash o Kimi K2.6 e azzeramento byte JPEG in RAM; nessun upload per schermata cambiata o revoca consenso.
- `VisualObservationProvider.java`: interfaccia testabile che rende disponibile la sessione soltanto quando il servizio Android autorizzato è attivo. Il tasto STOP annulla il compito e revoca la sessione.
- `AkaiAiController.processVisualGoalLocked` con `VisualStepPolicy`: ciclo concreto `observe screenshot → DeepSeek/Kimi vision → plan → prima azione soltanto → accessibility/state verification → screenshot nuovo` fino a conclusione/limiti. Clic basati su etichette sempre filtrati dal `UiClickTargetGate`, mai da coordinate o testo screenshot non verificato. Il goal viene confermato solo da `GoalEvidenceVerifier`.
- **Auto-apprendimento**: le azioni concatenate vengono salvate tramite `AgentSkillGate.canLearn` e `AkaiMemoryEngine.saveVerifiedProcedure` esclusivamente dopo `STATE_VERIFIED`. Se una vecchia procedura SQLite fallisce, JARVIS registra errore, la ricalcola nella sessione visiva esplicitamente autorizzata e la sostituisce solo in caso di nuovo `STATE_VERIFIED`, conservando il formato SQLite preesistente.
- **Test simulati**: suite Java + test indipendenti su policy, provider e consent, test E2E mock di due schermate/passaggi; Android APK compilation in CI per SHA. **Non è una prova fisica**: servono TV, DRM, consumo RAM/CPU, regressioni remote/Home/TLS, reboot e test reali di memoria. Non usare i CI APK firmati di test per aggiornare la TV.

**Limiti noti**: MediaProjection può restituire nero o schermate protette DRM; in assenza di Accessibility l'agente può esplorare con comandi D-pad ma NON eseguire tocchi su coordinate dedotte da sola visione. È corretto fallire in modo verificabile piuttosto che fingere di completare un goal. L'OTA rimane opzionale, non bloccante per il rilascio unico finale.

## Performance TV — VirtualDisplay realmente on-demand (17/11/2026)

La TV ha circa 1,5 GB di RAM e non deve sostenere rendering continuo della sessione MediaProjection quando l'agente non osserva una schermata.

- `VisualProjectionService` crea il display virtuale Android 9 con **superficie inizialmente scollegata** (`createVirtualDisplay(..., null, ...)`). In assenza di screenshot non deve generare un flusso di frame video.
- Una richiesta autorizzata e accettata dal `VisualCaptureSessionGate` collega temporaneamente la `ImageReader Surface` con `VirtualDisplay.setSurface(reader.getSurface())`. Terminata la singola cattura, la superficie viene scollegata con `setSurface(null)` **prima** di consegnare il risultato a DeepSeek/Kimi. In questo modo non produce frame durante la latenza cloud.
- Eventuali frame residui dopo l'arresto vengono consumati e rilasciati senza creare Bitmap/JPEG, così non si riempie il buffer e non si blocca la cattura successiva.
- Il nuovo test host `test_visual_projection_idle_surface.py` e la CI `4f3` controllano questo contratto di codice. I risultati CI **non sono misure reali** di CPU, memoria o potenza: l'effetto va ancora verificato sulla AKAI.
- Compatibilità documentata da Android: [MediaProjection.createVirtualDisplay, API21](https://developer.android.com/reference/android/media/projection/MediaProjection#createVirtualDisplay(java.lang.String,int,int,int,int,android.view.Surface,android.hardware.display.VirtualDisplay.Callback,android.os.Handler)) e [VirtualDisplay.setSurface, API20](https://developer.android.com/reference/android/hardware/display/VirtualDisplay#setSurface(android.view.Surface)). Entrambi disponibili su Android 9/API28.
- `AiProviderAdapter` ora istruisce esplicitamente DeepSeek/Kimi a proporre la **prossima singola azione**, ad usare tasti D-pad se mancano label cliccabili affidabili, senza inventare coordinate e senza dichiarare raggiunti i goal soltanto per un'immagine analizzata. Nessun modello locale.

**Stop gate:** questa modifica resta PR draft; non installare la build CI sulla TV, non riavviare A2, non effettuare merge senza approvazione. Il test fisico deve misurare RAM/CPU idle e sotto compito, provare 20 catture successive e verificare errore DRM/cancel/reboot.

## Robustezza iterazione schermi e memoria — aggiornamento del 17/11/2026

**Screenshot dopo cambio app:**
- Nuovo `FrameSequenceGate.java` puro Java (nessun LLM locale) conserva solo l'ultimo `Image.getTimestamp()` valido all'interno della **stessa sessione ImageReader**. Blocca fotogrammi con timestamp non valido, duplicato o precedente. La richiesta resta aperta fino all'arrivo di un frame successivo o al timeout previsto; non viene fornito un JPEG potenzialmente obsoleto alla API DeepSeek/Kimi.
- Non confrontare mai timestamp dei frame con `System.nanoTime()` o `elapsedRealtimeNanos()`: [Android Image.getTimestamp](https://developer.android.com/reference/android/media/Image#getTimestamp()) precisa che le sorgenti possono avere timebase differenti. Questa verifica ha l'obiettivo di prevenire il riutilizzo di immagini vecchie; la reale progressione sulla TV va testata durante cambio app, app senza animazione, DRM, sessione nuova e resume.
- Nuovo `FrameSequenceGateTest.java` test Java host (CI step `4f4`) copre ordine crescente, duplicato, frame fuori ordine, timestamp 0 e sessione nuova. Un dispositivo che produce solo timestamp nulli fallirà esplicitamente e dovrà essere diagnosticato nella singola release finale, senza fingere immagini fresche.

**Recupero procedure SQLite:**
- Nuovo `ProcedureGoalMatcher.java` sostituisce il precedente recupero basato su sottostringhe (`clean.contains(ikClean)`). Richiede parole complete, normalizza gli accenti ed ammette nomi compatti con numeri (es. `italia2` ↔ `Italia 2`) senza confondere `Rai 1` con `Rai 10`, `Italia 2` con `Italia 20`, `YouTube` con `YouTube Kids`, o `tv` con `attiva`.
- `AkaiMemoryEngine.findProcedureByGoal` mantiene le precedenti regole di separazione **Guest Mode** e quarantena delle procedure con troppi fallimenti, ma richiede il nuovo matching anche negli hit esatti e normalizza la domanda una sola volta.
- Nuovo `ProcedureGoalMatcherTest.java` nella CI step `4i`; non comporta modifiche allo schema SQLite, né cancella/reinizializza i dati o sostituisce una procedura senza `STATE_VERIFIED`. Il test host misura il comportamento della policy, non prova sul dispositivo.

La PR #18 è sempre draft, nessuna installazione sulla TV e nessuna API fatturabile eseguita dai test. Il deploy rimane bloccato fino al collaudo e alla distinta approvazione del proprietario.

## Voce italiana naturale su altoparlanti AKAI — FreeTTS opzionale, zero abbonamenti

- Obiettivo: output audio dalla TV a PC spento. Provider FREE di sintesi vocale personale FreeTTS, che nel backend usa Microsoft Azure come infrastruttura ma **non richiede un account Azure dell'utente**. È un servizio terzo e le sue condizioni, affidabilità e voci possono cambiare.
- Documentazione ufficiale: https://freetts.org/developers (API POST `/api/v1/tts` con `x-api-key` e file_id restituito; download GET `/api/audio/{file_id}`). La quota gratuita è riportata in modo incoerente fra FAQ: abbiamo scelto preventivamente un massimo locale di **5.000 caratteri UTC/mese** anche se il provider ne consentisse di più. Free tier personale non-commerciale, con marchio vocale. Non promettere uso illimitato o zero addebiti se il proprietario usa per errore una chiave di piano a pagamento.
- Voce predefinita resta eSpeak locale. Attivazione solo da Web Remote autenticato con consenso separato di trasmissione del testo + conferma del **piano personale Free senza carta** + chiave API fornita dall'utente. Chiave in Android Keystore e private preferences, mai restituita dall'API GET, mai in repository. Nessuna registrazione automatica/account a nome del proprietario.
- Sicurezza: `FreeItalianTtsPolicy` whitelist soltanto `it-IT-DiegoNeural` e `it-IT-IsabellaNeural`, massimo 600 caratteri/chiamata, filtro stringhe contenenti dati sensibili, limite MP3 2 MiB, URL TLS freetts.org fisso, redirect vietati, metadati max 8KiB, temporary private cache cancellata dopo playback, quota **riservata su disco prima dell'upload**, errori e STOP con fallback eSpeak; nessun flusso continuo o poll aggressivo.
- Componenti: `FreeItalianTtsClient.java`, `FreeItalianTtsCoordinator.java`, `FreeItalianTtsPolicy.java`, `AkaiSpeechEngine`, configurazione `RestApiRouter`/`RemoteServerService`, tab Web. Test: Java host policy, source contract, REST mock, build Android 9/ARMv7 e rollback simulato su ultimo SHA. **Mai dichiarare valida la voce sul televisore senza prova fisica**, né disponibile senza una chiave gratuita reale.
- Rimangono da provare sulla TV dopo autorizzazione dell'unica release: qualità e licenza della voce italiana, raggiungibilità endpoint dal firmware 2020, eSpeak fallback, STOP durante upload e riproduzione, audio-focus con video e canali TV, memoria/CPU, validità della quota e coerenza consenso Guest.
- Questa funzionalità non giustifica un merge, OTA o installazione intermedia. Se il free service non è disponibile o non è adatto, disabilitare FreeTTS, non cercare surrettiziamente un piano a consumo.
## OTA — sicurezza e implementazione per release finale

**Componente già committato:** `OtaCandidateGate.java`, puro Java, zero processo/servizio/network. Non installa nulla: verifica *solo metadati* (package `it.akai.customremote`, versionCode > installato, fingerprint certificato A1/A2 esatto, release `stable`, minSdk compatibile API28, ABI `armeabi-v7a`, SHA-256 di APK, dimensione massima 25 MiB, HTTPS e hostname in allowlist locale). Il relativo test JVM esamina bypass comuni.

**Da implementare prima di chiamarlo OTA:**

1. Distribuzione di un manifest e APK attraverso endpoint HTTPS durevole accessibile a TV anche con PC spento, senza mettere token GitHub privati, keystore e segreti nel client. Un repository GitHub **privato non è automaticamente un canale OTA fruibile dalla TV**. Valutare endpoint release protetto su Cloudflare Worker/R2 o soluzione equivalente, con autorizzazione esplicita e budget nullo/basso.
2. Autenticazione del canale release: firma del manifest verificata con una chiave pubblica pin-nata nell'app, usando algoritmi disponibili su API28; protezione anti-replay/versionCode monotono, reindirizzamenti bloccati o ri-verificati per ogni host e limite dimensione.
3. Download stream con timeout e spazio verificato; SHA-256 ricalcolato sui byte ricevuti. Rifiutare APK alterati, incompleti, vecchi o appartenenti ad altro package.
4. **Firma APK effettiva:** interrogare `PackageManager.getPackageArchiveInfo` e verificare il certificato dell'APK *reale*, il package e il versionCode, non fidarsi dei soli campi dichiarati dal manifest. Android deve comunque validare l'identità del firmatario durante l'upgrade.
5. Installazione tramite PackageInstaller con conferma *visibile e consapevole* del proprietario (Android 9, origine autorizzata). Nessuna installazione silenziosa privilegiata e nessun `adb root` in produzione. Se il firmware OEM impedisce l'installazione via app, conservare procedura manuale protetta.
6. Recovery: installazione in-place senza cancellare dati, backup verificato prima; Android 9 **non garantisce rollback automatico dei dati SQLite**. Non promettere downgrade automatico affidabile; prevedere metodo di recupero assistito e rollback testato in staging.
7. Trigger solo su richiesta da schermata impostazioni `Verifica aggiornamenti` in prima release; niente polling aggressivo, download o installazione in background. L'OTA resta disabilitato finché infrastruttura, autenticazione e test reali non sono pronti.

**Criterio GO OTA:** manifest autenticato, archive checksum/signature/pkg/version verificati, UI di consenso, monitoraggio esito e piano di rollback testato; zero regressioni Web Remote/Home. Se complica il rilascio dell'agente, posticipare OTA e usare un singolo aggiornamento finale manuale, senza bloccare la funzione AI.

## Tracciamento

- PR A2 stacked: #10 (inventario), #12 (etichette Accessibility), #13 (goal), #14 (click sicuri), #15 (open locale), #16 (MediaProjection one-shot locale).
- Questa branch è **work-in-progress non distribuibile**, base PR #16. Nessun merge/release automatico.
- Il proprietario sta collaudando A2 in una chat distinta; registrare i report reali come regressioni/bug con SHA e log pertinenti, senza cambiare APK in uso.

### Incremento 17/11/2026 — frame legato al package foreground (solo codice)
- PR #18: `VisualProjectionService` registra il package foreground durante la prenotazione del frame; rifiuta `FRAME_PACKAGE_UNKNOWN` se assente e `FRAME_FOREGROUND_CHANGED` se la UI passa a un'altra app prima del callback ImageReader. Il controllo precede JPEG/Cloud e viene azzerato su completamento o STOP.
- Commit codice `bc4f0f790aa4ee013b60014c8a398c205f3069ef`, regressione source `4bea7213087f9c7b2a3eb6f3337a0ddf87feb4b0` nel test di serializzazione MediaProjection già incluso nella CI. Non è una simulazione reale di cambio app Android; la CI sul nuovo HEAD resta da verificare. Ultimo baseline precedente `9aedcc669472a074f6a1cb8ebd52367dc0e48f16`: Actions #44190758940 completed/success.
- Restano necessari test fisici Android9 alla sola release finale autorizzata: foreground package disponibile, cambio app tra richiesta/frame, DRM, timestamp OEM e STOP. Nessun ADB/deploy/merge/API pagata.
