# JARVIS A2 — contratto di esecuzione e verifica dei compiti
Data: 2026-11-16
Stato: SPECIFICA / DA IMPLEMENTARE. NON equivale a funzionalità già presente sulla TV.

## Feedback reale del proprietario
- JARVIS A1 `versionCode=2` su AKAI AKTV5037N è online dopo BOOT_COMPLETED: HTTP 8088, HTTPS 8443, REST status=ok, uinput_ready=true.
- Android: comando vocale funziona; iPhone Web Speech è meno affidabile (traccia separata).
- Problema P0: l'agente può inviare un'azione o una sequenza, poi dire che non può verificare il risultato. Le istruzioni complesse non sono seguite in modo sufficientemente completo. Obiettivo: non rivendicare successo senza prova e, quando possibile, completare la verifica.
- **Il PC deve restare spento** durante l'uso quotidiano. Elaborazione tramite API DeepSeek/Kimi soltanto se configurate dal proprietario e con budget/consenso; niente LLM pesante residente sulla TV.
- Non modificare launcher Home v8; preservare dati SQLite, TLS e backup baseline v1 `C:\Users\danie\JARVIS-backup-TV\backup_20261116_120946` (TLS nel vault DPAPI associato), e nessuna installazione automatica.

## Stato tecnico di A1 osservato nel codice (non sovrastimare le capacità)
- `AkaiAiController` già contiene planner cloud opzionale, fast-path, esecuzione stepwise, polling screenshot/accessibility semantico e massimo **un** replan cloud.
- `ScreenPerceptionEngine` legge foreground package, accessibility text/nodes, focus, stima player, music activity. Non vede necessariamente contenuti video dentro SurfaceView/DRM, canale reale o volume corrente.
- `success_condition` attuale può attestare `pkg_is`, `contains_text`, `any_of_texts`, `player_active`, `focused_is`; non sempre coincide con l'obiettivo specifico espresso dall'utente.
- Precedente difetto P0 trovato in fast-path: con `successCondition=null` si assegnava `verified=true` dopo comando inviato. Corretto in commit `b392948` + regressione test `c1a83b6`: zero prove ⇒ `COMMAND_SENT` / `COMPLETED_UNVERIFIED`, non `STATE_VERIFIED`.
- Non confondere il superamento della CI host/mock con test su TV reale.

## Contratto A2 da implementare (priorità in ordine)

### P0 — goal contract & evidence
1. Parser intent converte il compito in `goal`, `scope`, `preconditions`, `observable_success_condition`, `stop_conditions`, `max_actions`, `max_cloud_calls`, `max_elapsed_ms`. Impedire che `success_condition` controlli soltanto una schermata intermedia (es. “Cerca” visibile mentre l'utente chiedeva un video in riproduzione).
2. Predisporre un **verifier distinto dal planner** (deterministico per obiettivi controllabili). Ogni step rilevante produce `before`, `action_response`, `after`, `verification_evidence`, con redazione dei dati sensibili. Il planner non può dichiarare da solo `STATE_VERIFIED`.
3. Il verdetto è vincolato: `STATE_VERIFIED` soltanto con evidenza sufficiente riferita al **goal finale**; `COMMAND_SENT` se si è inviato l'input ma non si può osservare l'effetto; `FAILED` se azione/gate fallisce; `NOT_TESTED` per sole risposte.
4. In assenza di segnale affidabile (es. film effettivamente partito dietro surface video), riportare esplicitamente **non verificabile** e il dettaglio della verifica mancante. Non inventare successo.
5. Distinguere stati intermedi e finali: “aperto YouTube”, “entrato in ricerca”, “trovato risultato”, “avviata riproduzione” non sono equivalenti. Dove non disponibile un segnale idoneo, richiedere conferma del proprietario invece di registrare una skill falsa.

### P1 — ciclo di correzione delimitato
6. Per compiti multi-step, `observe→plan→act→observe→verify` dopo ogni transizione UI. In caso di mismatch, usare log/evidence per `replan` al massimo **2** volte, senza ripetere la medesima sequenza e senza loop autonomo infinito.
7. Bounded delays diversi per `launch_app`, `page_load`, `player_ready`, non soltanto 1,2–1,5 secondi indiscriminati. Budget CPU/RAM e tempo minimi per AKTV5037N (Android 9, ARMv7, ~1.5GB RAM), callback non bloccanti, cancella operazione immediato.
8. Interrompere anziché tentare ripetutamente con contenuti a pagamento, acquisti, cancellazioni o campi sensibili; operazioni di rischio richiedono consenso esplicito. Limiti costo API visibili e rispettati.
9. Memorizzare in SQLite **solo** procedure con goal finale verificato; quarantine su fallimenti e revalidazione a software/UI aggiornati.

### P2 — affidabilità UX e osservabilità
10. Nella risposta parlata/UI mostrare: `goal`, `steps_executed`, `last_observation`, `verified`, `failed_stage`, `reason`, `replan_count`, `provider_cost`. Risposte oneste: “Ho aperto l'app ma non posso confermare che il video stia riproducendo”; mai “Fatto” senza prova.
11. Separare la diagnostica iOS Safari STT dal ciclo agente: Android STT già funziona. Progettare fallback WebKit STT senza gravare sul televisore e senza introdurre API a consumo non approvate.

## Quality gates e prove
- Mock verificatore: comando con no `success_condition` non può diventare `STATE_VERIFIED` né skill salvata; condizione falsa ⇒ `COMMAND_SENT` e risposta prudente; condizione finale vera ⇒ `STATE_VERIFIED`.
- Test end-to-end con bridge di percezione che simula UI lenta, selezione nodo sbagliato, app non disponibile, schermo con segreti e `surface` video priva di testo; deve fare correzione bounded o dichiarare limite senza successo fittizio.
- Test query multi-goal “Apri YouTube, cerca un titolo, avvia un video”: fermarsi se si verifica solo apertura o ricerca; contare cloud calls e osservazioni; zero apprendimento se mancante evidenza playback.
- Test preflight hardware *read-only* e prova su TV vera soltanto dopo CI verde, backup v1 conservato e procedura rollback verso **v1** verificata: un successivo nuovo `-Action install` farebbe altrimenti backup di v2 difettosa.
- NESSUN merge/deploy autonomo sulla TV. Report su PR con HEAD SHA, CI, mock/Android reali distinti, prove concrete, limiti residui.

## Assegnazione implementazione
- Antigravity/Gemini: implementare in un ramo/PR isolata con test e doc, evitando refactor massicci.
- ChatGPT/Codex supervisione: riesaminare diff, test effettivi, sicurezza/firme/migrazioni, correggere falsi successi.
- Prima dell'installazione: mostrare piano e richiedere approvazione del proprietario per il nuovo APK.
