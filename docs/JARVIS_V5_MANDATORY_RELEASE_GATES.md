# JARVIS v5 — Requisiti vincolanti di rilascio (decisione owner 18/11/2026)

## Decisione non negoziabile

La v5 Release NON è semplicemente una v4 Diagnostic senza debug. Il proprietario richiede che, PRIMA della dichiarazione READY e del rilascio v5, siano completati e provati tutti e quattro i gruppi seguenti: navigazione avanzata tra le app, OTA realmente operativo, prestazioni reali sulla AKAI, APK originale firmato con recupero verificato.

La v4 Diagnostic è solo fase di collaudo e raccolta evidenze, non soddisfa automaticamente i gate v5. PR #18 resta Draft; nessuna installazione o aggiornamento sulla TV è autorizzato implicitamente da questa decisione. Approvazione specifica del proprietario per ogni prova o installazione reale. Due passaggi di revisione obbligatori come in `docs/JARVIS_MANDATORY_SECOND_PASS_REVIEW.md`.

## GATE V5-1: Navigazione completa nei limiti consentiti da Android e DRM

**Funzione richiesta:** JARVIS deve poter operare nell'intera UI delle app Android TV installate e accessibili, non soltanto aprirle. Inventario reale app, D-pad/Accessibility, stato UI, sessione MediaProjection autorizzata, visione cloud esclusiva DeepSeek/Kimi, un'azione valida alla volta, fresh observation, STOP immediato e verifica reale dell'obiettivo (STATE_VERIFIED). Nuove sequenze riusabili solo se convalidate e salvate nel DB.

**Prove minime su dispositivo:** apertura app installata/non installata, app con controlli Accessibility, UI ambigua o mutata, cambio app nel corso della cattura, stop/cancellazione, assenza rete e API, un flusso di riproduzione (ad es. canale richiesto, non solo app aperta), reboot e memoria di una procedura riuscita. Distinguere PASS, FAIL, non osservabile e contenuti DRM.

**Limite tecnico:** non promettere che si possa leggere o automatizzare ogni schermata protetta. Vietati bypass DRM, accesso a contenuti protetti, click ciechi o false conferme. Se un'app non è controllabile tramite interfacce consentite, segnalare precisamente quale obiettivo è impedito; registrarlo nella matrice di copertura, non chiamarlo PASS. Valutare fallback D-pad verificati e controlli ufficiali dell'app ove disponibili.

**Gate:** matrice per ciascuna app/scenario del collaudo reale, comportamento stabile sui casi supportati e fallimenti gestiti correttamente. Nessuna affermazione di "navigazione universale senza limiti" o di supporto DRM non dimostrato.

## GATE V5-2: OTA completo, utilizzabile a PC spento

**Funzione richiesta:** menu "Verifica aggiornamenti" dalla TV, endpoint di distribuzione HTTPS indipendente dal PC, manifest di release autenticato, protezione antireplay e downgrade, verifica su *byte reali* di SHA-256, package, versionCode, signer originale, API28/ARMv7 e size; download limitato e riprendibile o rigettato in caso di corruzione; conferma esplicita nell'UI di Android PackageInstaller; verifica post-installazione e gestione errori. Nessuna chiave privata/API nel client/repository.

**Prove minime:** aggiornamento da versione idonea a versione successiva nello staging del dispositivo con consenso owner; nessun aggiornamento disponibile; APK corrotto/firmato diversamente/downgrade/manifest manipolato; assenza rete; spazio insufficiente; annullamento utente; fallimento installazione e recovery documentato. TV capace di verificare la release con PC spento. Non effettuare OTA silenziosa e non pubblicare APK diagnostiche private come release.

**Gate:** OTA reale funzionante e verificato, oppure v5 NON approvata. Se Android OEM non consente PackageInstaller via app, serve percorso alternativo guidato dal menu TV e collaudato su dispositivo: l'obiettivo è aggiornare con PC spento e consenso, non bypassare la piattaforma.

## GATE V5-3: Misure prestazioni sulla AKAI AKTV5037N

**Dispositivo:** Android 9/API28, ARMv7, ~1.5 GB RAM, eMMC 8 GB. Modelli LLM AI soltanto API DeepSeek/Kimi: zero inferenza locale.

**Rilevazioni obbligatorie:** memoria PSS/RSS e MemAvailable a riposo e durante JARVIS, CPU e load, latenza dei comandi D-pad e avvio applicazioni, tempo e memoria della cattura on-demand, consumo/dimensione APK e storage disponibile, stabilità su sessioni ripetute, crash/ANR, servizi e worker attivi in idle. Confrontare con A2 e launcher LTvLauncher dove possibile; riportare valori reali e modalità di misura, senza inventare percentuali di miglioramento.

**Regressioni da escludere:** Home v8, tuner/antenna/HDMI, volume, canali, Web Remote Safari/iPhone/Android senza PC, TLS e pairing, standby/riavvio, STOP immediato, memoria SQLite e servizi TV. Qualsiasi regressione grave P0/P1 è NO-GO; impatti minori richiedono accettazione esplicita owner. Non aggiungere processi residenti superflui.

**Gate:** report test hardware con benchmark prima/dopo e risultati ripetibili; mock o Actions CI non equivalgono a misure reali.

## GATE V5-4: APK owner-signed e recupero reale

- CI completa `completed/success` sulla esatta HEAD v5, revisione A+B, Android9/ARMv7, manifest `versionCode` superiore a quello installato e `android:debuggable=false`, package `it.akai.customremote`, chiave originale stessa di A2/v4.
- Build su PC privato con certificato originale; verifiche `apksigner`, `aapt`, zipalign, SHA-256, librerie JNI e assenza di materiale TLS privato; registrare manifest provenienza senza segreti. Mai usare `app-ci-test-nondistributable.apk` per aggiornare la TV.
- Backup verificato APK attuale, database SQLite con WAL/checkpoint, identità TLS, preferenze e capacità reale di recupero; preservare launcher, dati, pairing e Root CA; nessun uninstall, reset o `pm clear` per forzare l'upgrade.
- Verificare su TV i prerequisiti di recoverability in sola lettura e, con distinto consenso del proprietario, una prova conservativa del percorso recupero prima di dichiarare GO. Android 9 non garantisce downgrade non-debuggable o rollback DB: un semplice mock `adb install -d` non è una prova.
- v4 Diagnostic owner-signed solo per collaudo; v5 Release soltanto dopo rapporto completo e conferma specifica dell'owner.

## Regola di decisione

`GO_FOR_V5_RELEASE` = TUTTI e quattro i gate PASS con evidenza hardware dove richiesta + CI PASS sull'HEAD precisa + audit indipendente per quanto disponibile + consenso owner.

Qualsiasi gate FAIL/BLOCKED/NOT_RUN => `NO_GO_V5_RELEASE`; continuare sviluppo, simulazioni e collaudo v4 senza rappresentare la v5 come pronta. Le limitazioni intrinseche DRM/Android vanno documentate esplicitamente, non occultate. Non confondere un problema tecnico non aggirabile con una implementazione da dichiarare completata.

Questo documento supera le precedenti indicazioni che consideravano OTA "opzionale/non bloccante" per la v5. Non abroga il divieto di installazioni automatiche, l'inferenza DeepSeek/Kimi-only o i requisiti di backup e sicurezza.
