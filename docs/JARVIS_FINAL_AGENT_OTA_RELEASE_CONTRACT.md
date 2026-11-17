# AKAI JARVIS — Contratto di rilascio dell'agente autonomo e OTA (17/11/2026)

## Decisione del proprietario

- **Televisore attuale:** AKAI AKTV5037N, Android 9/API 28, ARMv7, RAM circa 1,5 GB. App `it.akai.customremote` A2 Preview `versionCode=3`, installata il 17/11/2026 e collaudata **solo per bootstrap**: `/api/status=ok`, `uinput_ready=true`, HTTP 200 e TLS operativo con fiducia CA OOB ancora da verificare.
- **Freeze hardware:** nessun altro aggiornamento/intervento sulla TV durante lo sviluppo, salvo necessità reale approvata esplicitamente. Niente auto-install, auto-deploy, merge automatico, uninstall, reset, root o mutazioni SQLite via CI/automazioni.
- **Priorità:** completare un agente autonomo realmente utile; OTA solo se non introduce un rischio maggiore e non aumenta sensibilmente memoria/processi.
- **REGOLA PERMANENTE E NON NEGOZIABILE (OWNER 17/11/2026): L'INFERENZA AI DI JARVIS USA ESCLUSIVAMENTE MODELLI CLOUD DEEPSEEK O KIMI (MOONSHOT), TRAMITE LE RISPETTIVE API. NESSUN ALTRO PROVIDER; NESSUN MODELLO AI LOCALE, NEMMENO COME FALLBACK, SU TV O PC.** La TV non ha hardware per eseguire LLM locali. Nessun Ollama, LM Studio, ONNX LLM, Termux ML, mini-LLM o stack AI terzo. Le API cloud richiedono consenso, credenziali e budget configurati dall'owner.
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
