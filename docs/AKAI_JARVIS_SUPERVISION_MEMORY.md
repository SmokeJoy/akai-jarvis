# AKAI JARVIS — Memoria operativa e protocollo di supervisione

> Documento canonico di continuità per nuove chat ChatGPT, Antigravity e automazione «Revisione GitHub AKAI».
> Baseline verificata il **14 novembre 2026**. **Le SHA e gli stati qui riportati sono fotografie, non dati live.**
> Repository **privato**: https://github.com/SmokeJoy/akai-jarvis
> Leggere anche l'issue «AKAI JARVIS — Stato vivo della supervisione» (creata per aggiornamenti incrementali).
> Priorità delle fonti: **decisioni esplicite più recenti del proprietario > codice/PR/CI live > stato vivo dell'issue > questa baseline storica**. Non sostituire prove reali con affermazioni nei commenti.

## 0. Istruzioni di ripartenza (leggi PRIMA di agire)

1. Leggi integralmente questo file. Identifica cosa è **decisione invariabile** e cosa è **stato datato**.
2. Recupera l'issue «Stato vivo della supervisione» e le PR **#1, #2, #3** tramite connettore GitHub. Leggi HEAD SHA, file/diff, commenti recenti, review e GitHub Actions; **non usare la sola memoria** per dire «è pronto».
3. Confronta gli HEAD con i riferimenti datati in §6; fai analisi incrementale di **codice reale**, test positivi/negativi e log quando servono.
4. Se non è cambiato nulla di sostanziale, **non commentare** e non creare cicli tra ChatGPT e Antigravity.
5. Se c'è codice nuovo, revisiona l'incremento; se c'è un blocco `[BLOCKER → CHATGPT]`, risolvilo con analisi tecnica, patch mirata e test, oppure chiedi dati mirati **sulla PR**.
6. Non autorizzare implicitamente installazioni, ADB, backup fisici, API a pagamento o merge. Queste sono decisioni **separate**.
7. Chiudi il resoconto distinguendo **VERIFICATO SU GITHUB**, **MOCK/CI**, **TEST FISICO ATTESTATO**, **DA VERIFICARE**. Non inventare ETA certe o benchmark.

## 1. Missione e ruoli

**Obiettivo:** trasformare la **AKAI AKTV5037N** in una TV Android moderna e reattiva, con Home personalizzata, applicazioni streaming native e **un unico JARVIS residente sulla TV**. JARVIS interpreta voce/testo, controlla interfacce, canali e impostazioni, verifica l'effetto delle azioni e apprende procedure riutilizzabili. Deve funzionare con **PC spento**; per il ragionamento avanzato usa **API DeepSeek o Moonshot Kimi** (quindi Internet necessario per tale parte).

- **Proprietario:** decide architettura, spesa, credenziali, operazioni hardware, installazioni e merge.
- **ChatGPT:** architetto e supervisore tecnico indipendente; esamina repository, diff, CI, problemi riproducibili; impartisce direttive a Gemini/Antigravity tramite commenti GitHub, senza duplicazioni.
- **Gemini in Antigravity:** implementatore su branch PR, test mock/host/emulatore, report SHA/CI e correzioni secondo review.
- **GitHub:** fonte operativa di codice e cronologia; commenti non sostituiscono test.

**Metodo:** proprietario decide le scelte sostanziali → ChatGPT coordina → Antigravity implementa → ChatGPT verifica → collaudo fisico solo dopo consenso. Per dettagli marginali che non cambiano l'architettura, il supervisore può guidare direttamente l'implementazione nel perimetro già autorizzato.

## 2. Invarianti architetturali — decisione aggiornata 14/11/2026

**La decisione PIÙ RECENTE sostituisce tutte le precedenti proposte «STRICT_LOCAL_ONLY permanente», split-brain, mini-PC, Termux/llama.cpp, modelli pesanti on-device.**

- Backend JARVIS installato sulla **AKAI**, non su PC: riutilizzare `AkaiAiController.java`, `AiProviderAdapter.java`, `LocalIntentParser.java`, `ScreenPerceptionEngine.java`, `AkaiMemoryEngine.java`, `TvController.java`, `KeystoreSecurityHelper.java`.
- **DeepSeek/Kimi via API selezionabili**, solo previa configurazione e consenso delle chiavi/provider; NON assumere key già disponibile, non fare chiamate fatturabili nei test.
- **Fast-path locale + procedure SQLite a zero token** per compiti conosciuti; API solo per ragionamento, conversazione e procedure non note; fallback locale quando offline.
- Agente circoscritto: **osserva → pianifica → valida → esegui uno step/piccoli blocchi → osserva → verifica → ripianifica se necessario (max tentativi) → salva SOLO se verificato**. `COMMAND_SENT` non significa `STATE_VERIFIED`.
- **Prestazioni prima di tutto:** poche allocazioni, niente processi/sistemi aggiuntivi, screenshot solo on-demand se indispensabili; mai polling continuo/overlay pesante; misurare PSS, CPU, latenza, dimensioni APK e token **senza inventare numeri**.
- **Riutilizzo OSS selettivo** approvato per accelerare: studiare pattern di `GiggleWang/MobileAgent-Android` (step/reflect/replan) e `YHLFurry/AgentPaw` (checkpoint, retry bounded, skill). Non importare integralmente framework, dipendenze Kotlin/Python, servizi, launcher, modelli o server nella TV. Verificare licenze/notice per codice copiato; **idee ≠ codice integrato**. DeerFlow/ZeroFlow sono al massimo ispirazione/tool di sviluppo host.
- **Sicurezza domestica essenziale, non enterprise:** niente chiavi Base64/plaintext, usa Keystore con errore fail-closed se non disponibile, HTTPS/autenticazione per gestione remota, allowlist azioni, annulla/stop, dati sensibili schermati, budget e quote, conferma per azioni distruttive. Nessun PIN, IP privato, SSID, token o foto personali in issue/log/CI.

**Direttive autorevoli già pubblicate:**
- Decisione API definitiva: https://github.com/SmokeJoy/akai-jarvis/pull/1#issuecomment-6881433641
- Presa in carico Incremento 1: https://github.com/SmokeJoy/akai-jarvis/pull/1#issuecomment-6881643507
- Riuso OSS & prestazioni: https://github.com/SmokeJoy/akai-jarvis/pull/1#issuecomment-6881898084

## 3. Hardware e ambienti: fatti da rispettare

- Televisore: **AKAI AKTV5037N**, 50", Android **9 / API 28**, SoC/board famiglia **m7332_eu / CV9632H-A50**, Cortex-A53, distribuzione APK ARMv7 (`armeabi-v7a`), RAM fisica circa **1,5 GB**, eMMC **8 GB**, display 4K con GUI tipicamente a 1080p.
- Prestazioni modeste: non proporre Java/Kotlin/Python server pesanti sulla TV; non confondere il pannello 4K con decodifica effettiva 4K delle app.
- Launcher storico LTvLauncher; launcher custom v7 `it.akai.customhome` preservato; launcher v8 `it.akai.customhome.v8` installato/testato. Non sostituire o resettare Home se non autorizzato.
- JARVIS/telecomando `it.akai.customremote`: server HTTP locale porta 8088 e HTTPS 8443 nel progetto, servizi Accessibility, controller e JNI `uinput`, PIN e token sessione. **L'esistenza del codice non garantisce che ogni servizio sia collaudato sulla TV**. Safari iPhone e controllo PC spento sono gate separati.
- Android 9: `AccessibilityService.takeScreenshot()` richiede API 30: usare albero Accessibility esistente. MediaProjection è un'opzione on-demand da provare con consenso e prestazioni misurate, **non requisito per MVP**.
- `ScreenPerceptionEngine` già percorre l'albero Accessibility e costruisce snapshot; `AkaiMemoryEngine` usa SQLite; `LocalIntentParser` ha comandi hardware e lookup di procedure. Evitare di ricostruire quanto esiste.

## 4. Che cosa vogliamo vedere funzionare

Esempio target: l'utente parla dallo smartphone («Jarvis, metti Italia 2»); JARVIS trascrive la richiesta, trova una procedura verificata o chiede il piano a DeepSeek/Kimi, controlla Mediaset Infinity e la diretta, **verifica** la riproduzione e solo allora memorizza la procedura; risposta pronunciata dagli speaker TV. Deve gestire app diverse, impostazioni audio, ingressi HDMI, digitale terrestre, YouTube e conversazione.

- Smartphone iOS/Android = microfono + telecomando web/PWA, non computer necessario. Conversazione con contesto, stop, turn-taking e niente loop audio.
- Memoria SQLite locale con limiti, cronologia recente, guest mode senza esposizione dati personali; niente archivio audio permanente.
- App streaming: RaiPlay TV 4.2.11 aveva prove VOD/diretta riferite; Mediaset Infinity aveva prove playback dopo consenso cookie; Disney+ arrivava ad associazione; Prime Video e Netflix non risultavano convalidati completamente. Non promettere compatibilità DRM/Netflix senza prova.
- Requisiti prestazioni: comando locale rapido, nessuna regressione D-Pad e MENU, misurazioni comparabili prima/dopo su hardware **solo quando autorizzate**.

## 5. Prove e categorie (obbligatorio)

Non confondere:
1. diff compilabile;
2. test Java host/mock, PowerShell mock ADB, SQLite offline;
3. Android APK build/packaging in CI;
4. emulator Android TV;
5. prova fisica/ADB reale sulla TV;
6. test reale iPhone Safari con PC spento e HTTPS.

**CI verde da sola NON convalida runtime cloud né le app streaming.** Ogni resoconto deve specificare quale di queste categorie supporta il risultato.

## 6. Snapshot GitHub — verificato il 14/11/2026, aggiornare da live

| PR | HEAD storico | Stato e blocchi noti |
|---|---|---|
| [#1 — Backend JARVIS](https://github.com/SmokeJoy/akai-jarvis/pull/1) | `e151f0d45f3285b873d1ceda6e44031ca57d7df2` | Aperta; **istruzione ripristino DeepSeek/Kimi pubblicata, NON ancora implementata nell'HEAD verificato**. Precedenti CI su quella SHA successful, ma cloud disabilitato. |
| [#2 — Audit grafico](https://github.com/SmokeJoy/akai-jarvis/pull/2) | `f04b77f5e6e3fe0be817eeb97c3fd091bf706509` | Aperta; documento/mockup grafici, rilievi sostanziali sistemati; non è prova runtime. |
| [#3 — Home v8](https://github.com/SmokeJoy/akai-jarvis/pull/3) | `4a040eca9bb6ee0fcc62d048af198447e349522d` | Aperta; CI 225 test host dichiarati nei job, build v8; prova fisica **utente** YouTube → tasto MENU → Home v8 riferita e accettata; non estendere PASS a DTV/HDMI e ogni streaming. Freeze launcher versione 11, v7 preservata. |

**Evidenze tecniche PR #1 nella SHA sopra:**
- `AkaiAiController.java`: `STRICT_LOCAL_ONLY_POLICY = true` e setter che rifiuta cloud; percorso con `AiProviderAdapter` già esistente ma inibito.
- `AiProviderAdapter.java`: HTTP DeepSeek/Kimi, testConnection, planning, preferenze provider e cost control già in codice; `ENDPOINT_KIMI` punta a `api.moonshot.cn`, verificare endpoint internazionale ufficiale `.ai` e disponibilità del modello. Chiave Kimi Coding ≠ necessariamente Moonshot Open Platform.
- `KeystoreSecurityHelper.java`: fallback `b64:` della chiave in chiaro: **P0 da correggere prima di abilitare il cloud**.
- `AkaiAiController` usa attese fisse `Thread.sleep(800/1200/1500)`: valutare bounded wait su stato per ridurre ritardi inutili. Gli snapshot `toContextPrompt()` possono essere ridotti per token/privacy.
- `AiProviderAdapter.parseLlmOutput`: il JSON deve essere validato a schema/allowlist prima delle azioni; bloccare azioni arbitrarie e loop ripetitivi.
- Nella SHA citata, workflow PR #1 `43620041718` **completed/success** (Java host 34 test, PowerShell mock 29, SQLite offline); non è un test API reale.
- Home v8 PR #3: workflow `43530522379` successful con 225 Java host unit test e controlli statici; prova fisica MENU circoscritta.
- Una revisione precedente richiedeva un wrapper backup con `try/finally` e ripristino servizio dopo errori; non confondere piano backup con backup già effettuato.

## 7. Priorità attuali (non aprire altri cantieri)

**P0 / Incremento A — prima consegna:** PR #1, chiavi sicure (nessun Base64 non cifrato), profilo `CLOUD_OPTIONAL` / `LOCAL_ONLY`, selezione DeepSeek/Kimi, fast-path locale intatto, mock HTTP errori 200/401/402/429/timeout/offline/JSON malformato, build API28/ARMv7, CI. **Zero chiamate fatturabili e zero installazioni TV.**

**P1 / Incremento B — agente:** esecuzione stepwise e osservazione/verifica fra gli step, output JSON validato, massimo 1–2 replanning innocui, persistenza solo esito verificato, checkpoint piccoli se utili, tempi d'attesa bounded; reuse mirato MobileAgent-Android + AgentPaw senza librerie pesanti.

**P1 / Performance & beta:** confronto con baseline (dimensione APK, RAM/CPU e PSS TV quando autorizzata, latenza comandi, numero screenshot e chiamate API/token, memoria SQLite); preservare launcher v8 vc11 e v7. Safari HTTPS, TTS, prova PC spento e streaming sono test fisici separati e autorizzati.

**Non rallentare la beta per una nuova piattaforma agente.** Se il riuso OSS non fa risparmiare tempo, scartarlo.

## 8. Protocollo di revisione ChatGPT / automazione

- Automazione esistente: **«Revisione GitHub AKAI»**, controllo **orario** (non ogni 10 minuti), soggetta alle funzionalità disponibili quando gira.
- Controlla sempre tutte le tre PR, ma **priorità PR #1**, e valuta nuovo HEAD rispetto all'ultimo revisionato (non rispetto a commenti auto-generati).
- Un solo commento `[Revisione ChatGPT automatica]` per PR **soltanto se** emerge cambiamento rilevante non revisionato o nuovo difetto documentato; riferisci SHA, file/righe, prova, severità P0/P1/P2, test positivi/negativi e acceptance gate. Se non cambia nulla, **silenzio**.
- Gestione nuovi `[BLOCKER → CHATGPT]`: verifica codice/log, cerca documentazione/fonti OSS se serve, pubblica `[SOLUZIONE CHATGPT → BLOCKER]` o `[RICHIESTA DATI CHATGPT → BLOCKER]` con prove e test; niente bot che risponde ai propri commenti o ripete review. Dopo 3 tentativi falliti per stesso problema chiedi diagnostica, non patch speculative.
- Non riaprire problemi corretti: PR #2 è documentazione; per PR #3 MENU/YouTube è già attestato, evitare refactor gratuiti; PR #1 è il percorso critico.
- Se c'è **un avanzamento sostanziale verificabile** (nuova SHA e CI, accettazione hardware, cambio decisione owner, blocker irrisolto/risolto), aggiornare l'issue «Stato vivo della supervisione» con fatto, data, SHA, URL prova, stato. NON modificare ogni ora per attività nulla, né riscrivere la storia. La memoria statica va aggiornata per nuove decisioni permanenti con modifica documentale tracciabile.
- Divieti in automazione: **non** effettuare commit di codice, merge, ADB, test fisici, installazioni/disinstallazioni, reset, modifiche Home, provisioning TLS, uso chiavi/provider/costi reali. Il permesso al supervisore di creare/aggiornare la memoria è limitato a **documentazione e issue di stato**, non al software.

## 9. HARDWARE FREEZE e permessi

**Fino ad autorizzazione operativa specifica:** niente installazione APK, ADB/adb root, backup reale, force-stop, cambio Home, decompilazione/estrazione dati privati, reset, alterazioni firmware, certificati o merge su main; niente API key vere né chiamate a pagamento. Sono consentite: lettura GitHub, audit/CI, direttive e review, sviluppo offline di Antigravity sul branch PR autorizzato. *Questo file documentale non è un'autorizzazione hardware.*

Non esporre credenziali, PIN, SSID, IP privati o dati familiari in repo/commenti. Le procedure di backup/rollback v5→v6 devono proteggere il servizio funzionante e richiedere consensi distinti.

## 10. Prompt pronto per una nuova chat

> «Riprendi come supervisore tecnico AKAI JARVIS. Apri il repo privato SmokeJoy/akai-jarvis e **leggi prima** `docs/AKAI_JARVIS_SUPERVISION_MEMORY.md` sul branch `main`, poi l'issue "AKAI JARVIS — Stato vivo della supervisione". Verifica PR #1/#2/#3, i rispettivi HEAD SHA, ultimi diff/commenti e GitHub Actions. Mantieni la decisione definitiva: DeepSeek/Kimi via API e JARVIS leggero residente su AKAI Android9, fast-path locale/SQLite e riuso OSS **solo mirato** senza appesantire la TV. ChatGPT supervisiona, Antigravity implementa, io autorizzo merge/TV/costi. Non ripetere review né riaprire decisioni vecchie. Riferisci fatti verificati vs da testare, coordina Antigravity sulla PR #1 senza toccare l'hardware.»

## 11. Documentazione ufficiale e sincronizzazione del progetto ChatGPT

- **[Indice ufficiale tecnico](OFFICIAL_TECH_REFERENCES.md):** Android 9 e API28, Accessibility/MediaProjection, Keystore, SQLite, rete, prestazioni e metriche RAM, D-pad/TV, WebView, DeepSeek/Moonshot, GitHub Actions e regole Google Antigravity. Consultare documenti ufficiali **prima** di proposte di codice/API e verificare minSdk/target reali.
- **[Regole progetto ChatGPT AKAI TV BOOST](CHATGPT_PROJECT_AKAI_TV_BOOST.md):** testo operativo pronto per le *Istruzioni del progetto* nella UI ChatGPT. La UI del progetto è indipendente da GitHub: non dichiarare sincronizzate impostazioni non modificate.
- Il file root **[AGENTS.md](../AGENTS.md)** è la regola workspace generale letta da Antigravity secondo la sua documentazione ufficiale; nessun bisogno di duplicare le stesse regole in numerosi file tecnici.
- Registro vivo dei progressi: [issue #4](https://github.com/SmokeJoy/akai-jarvis/issues/4). Non trasformare l'issue in altra documentazione statica.

## 12. Decisione del 14/11/2026: autoevoluzione POST-BETA e valutazione tecnica dei collaudi

Il proprietario ha APPROVATO la roadmap in **[AKAI_JARVIS_AUTONOMY_ROADMAP.md](AKAI_JARVIS_AUTONOMY_ROADMAP.md)**: Skill Engine Java/JSON/SQLite con validazione e apprendimento zero-token; Cloud Developer esterno con DeepSeek/Kimi + agente orchestratore effettivo + GitHub Actions, patch in branch/PR con CI; Update Manager con versione/firma, backup e rollback. **Non installare Termux/shell/LLM/compilatori residenti sulla TV**, né abilitare auto-merge o update forzati. La roadmap parte **dopo** la prima beta fisica stabile; adesso nessun refactor per funzioni autoevolutive.

Il proprietario delega al **supervisore ChatGPT** la firma del *GO/NO-GO tecnico* del primo test quando i requisiti siano verificati. Al 14/11/2026: PR #1 HEAD `fd258556c28b42c56cc8dd52282d1b5cb5bfd0a5`, Actions push `43633499134` e PR `43633507069` successful **host/mock**. GO preliminare per `preflight` read-only, NO-GO temporaneo per installazione finché non esistono prove di backup fisico coerente SQLite+WAL/APK, compatibilità firma/versione e recupero. Questo documento non attesta un backup/install già svolti, né autorizza firmware/merge/costi AI.

## 13. Blocco storico HTTP/HTTPS e perimetro di collaudo (14 novembre 2026)

Il proprietario ha corretto un equivoco importante: **JARVIS è l'app TELECOMANDO `it.akai.customremote`, non un nuovo firmware o un nuovo launcher**. Il vecchio telecomando e i tasti base erano già funzionanti; la prima versione evoluta era bloccata soprattutto sul controllo avanzato/web/voce perché l'origine HTTP LAN non era un secure context per il microfono web. Solo quel package e i suoi dati possono essere oggetto di backup/upgrade/rollback; Home v8 `it.akai.customhome.v8`, v7 `it.akai.customhome` e tutte le altre app sono **intoccabili**.

Codice PR #1 HEAD verificato `fd258556c28b42c56cc8dd52282d1b5cb5bfd0a5`: `RemoteServerService` espone HTTP 8088 e HTTPS 8443; `RestApiRouter` permette HTTP soltanto per bootstrap/status/CA/TLS info, mentre i comandi autenticati HTTP ricevono `426 HTTPS_REQUIRED`; `akai-remote-web/app.js` richiede HTTPS/secure context per la parte microfono. **Se HTTPS/PIN/CA/Safari non vanno, il vecchio telecomando HTTP NON rimane automaticamente funzionante nella nuova app**: test funzionali reali obbligatori e rollback pronto, non reintroduzione di token/comandi in HTTP chiaro.

Condizioni distinte: (1) baseline v5 funzionante e tasti; (2) backup verificato APK+SQLite/WAL + firma stessa chiave/versione corretta e rollback; (3) HTTPS 8443 SAN/trust, certificato CA con impronta confrontata **sullo schermo TV fuori banda**, PIN, pairing autenticato e tasti iPhone; (4) Safari microfono/conversazione con `SpeechRecognition || webkitSpeechRecognition` *effettivamente disponibile* (HTTPS necessario ma non sufficiente); (5) test PC spento. Se un gate critico per il telecomando fallisce, rollback dell'unico package; nessun intervento sui launcher.

**Direttiva effettiva ad Antigravity:** [PR #1 commento #6883385053](https://github.com/SmokeJoy/akai-jarvis/pull/1#issuecomment-6883385053). GO/NO-GO tecnico delegato a ChatGPT, installazione non implicitamente autorizzata; preflight read-only approvato e operazioni che fermano v5 richiedono comunicazione specifica degli effetti.

## 14. CONTRORDINE DEL PROPRIETARIO — P0 TELECOMANDO PRIMA, POI AGENTE REALE (14 novembre 2026)

**ATTUALE; prevale sui capitoli storici 11–13 e sui vecchi commenti che impongono solo HTTPS per i tasti del telecomando.** Il proprietario segnala insoddisfazione e regressione di prodotto: il telecomando preesistente era già funzionante e non deve perdere PIN, D-pad, OK, HOME, BACK, volume, tastiera, URL e comportamento. **Tutte le modifiche devono essere circoscritte a `it.akai.customremote`**; launcher v8/v7 e firmware sono intoccabili. L'app attualmente installata sulla TV NON è stata verificata da questa revisione: il **bug confermato è nel branch PR**, non asserire cambiamento sul dispositivo fisico.

**Finding P0 nel codice (PR #1 HEAD verificato `74477d6a967a7a7f6ffa88397945f0810b155245`):**
- `main` `RemoteServerService.java` esponeva su HTTP 8088 gli endpoint di pairing PIN e telecomando funzionanti.
- Nel branch della PR `RestApiRouter.routeRequest` respinge con HTTP 426 richieste HTTP di pairing, command, text e asset statici; il blocco parallelo `RemoteServerService.routeRequest` impedisce anche gli asset web. `app.js` impone l'accettazione della CA nell'associazione, perfino per il telecomando classico. Quindi una installazione della PR rischia di interrompere il telecomando.
- **Decisione owner**: ripristinare i percorsi HTTP **solo legacy su LAN RFC1918** (pairing, token, command, text, revoke e static assets, con guardie di auth preesistenti), e lasciare cloud AI/config/memoria/voce sensibile su HTTPS 8443. Non aprire endpoint AI/credential su HTTP e non consentire reti WAN; segnalare al proprietario che PIN/token via HTTP LAN restano intercettabili e raccomandare HTTPS quando pronto, ma **non impedire l'uso del telecomando v5**. Le vecchie prescrizioni di non offrire un percorso HTTP di compatibilità sono **superate in questo solo ambito**.
- **P0 test obbligatori**: suite di parità contro main sull'HTTP LAN e su HTTPS con PIN, i tasti e la UI; verifica 401/403/rate-limit e AI/admin HTTP 426. La CI esistente non copre ancora questa regressione. Non installare su TV prima di una release candidata che superi questi test e sia ripristinabile.

**Agente richiesto e non più da rinviare con sola documentazione:**
1. **JARVIS MVP su TV** usando le classi Java già sviluppate: testo → LocalIntentParser o cloud DeepSeek/Kimi → piano JSON validato → TvController → verifica dello schermo → salva Skill SQLite verificata, 0 token in riuso. UI/REST opzionale indipendente dal telecomando. Su host, test E2E da endpoint e frontend, non solo unit test.
2. **Agente developer autoevolutivo** su **branch separato dal telecomando**, usando reale orchestrazione DeepSeek/Kimi + GitHub Actions, code/test/PR; solo dopo aver rimesso in sicurezza la compatibilità. Non Termux, shell root, LLM o toolchain pesanti sulla TV, niente auto-update/install/merge senza verifica e consenso.
3. Ogni asserzione «completato» richiede commit verificabile, CI, tabella scenari testati e demarcazione tra mock e TV reale. Nessuna API cloud fatturabile prima di un'autorizzazione del proprietario.

**Istruzione esecutiva pubblicata a Antigravity:** [PR #1 #6883455180](https://github.com/SmokeJoy/akai-jarvis/pull/1#issuecomment-6883455180). Il supervisore non deve continuare a produrre nuove richieste di analisi teoriche senza far avanzare il codice.

