# JARVIS finale — audit codice pre-installazione (18 novembre 2026)

**Ambito:** sorgente PR #18 basata su `324c4f1a0d468f2bf0a48a744178a56bf95c6251`, revisione manuale dei componenti principali e delle procedure di build e recupero. L'audit non è un test Android reale. La CI #44252420128 sull'esatto SHA `324c4f1` era `completed/success`; la CI deve essere riverificata sul nuovo HEAD dopo gli aggiornamenti documentali.

**Decisione:** `GO` soltanto per continuare build, test simulati, audit e preflight **read-only con autorizzazione owner**. `NO-GO` per installazione della v4 sulla TV finché i punti P0 seguenti non sono chiusi e la firma proprietaria originale non è disponibile. Nessun bypass mediante reset, uninstall o nuovo debug signer.

## P0 — recupero Android9 non dimostrato

- Fonte: `akai-remote-tests/05_safe_install_and_rollback.ps1`, rollback automatico linea circa 2660 e manuale circa 2811: `adb install -r -d $backupApk`.
- Problema: ADB ufficiale documenta `-d` come *Allow version code downgrade (debuggable packages only)*: https://android.googlesource.com/platform/packages/modules/adb/+/HEAD/docs/user/adb.1.md . Il package finale `it.akai.customremote` ha `android:debuggable="false"` in `akai-remote-tv/app/src/main/AndroidManifest.xml`. Alcune OEM/debuggable platform build possono consentire eccezioni, NON verificate sulla AKAI. I 35 test mock simulano `adb install` restituendo Success, non riproducono il PackageManager della TV.
- Conseguenza: la procedura detta "rollback atomico" può non riuscire a reinstallare la versione più vecchia mantenendo SQLite e identità TLS. Non assumere rollback funzionante a partire da CI PASS.
- Prima dell'installazione: backup A2 vCode3 firmato + `akai_memory.db` con WAL/checkpoint + 5 file TLS, hash e integrità verificati; owner verifica in sola lettura `getprop ro.debuggable`, `getprop ro.build.type`, `dumpsys package it.akai.customremote`; provare soltanto una strategia di recupero che non richieda cancellare dati. Possibile soluzione: preparare A2 *rescue* compatibile, rifirmata **dalla chiave originale** con `versionCode > 4` e testata per conservazione DB/TLS; è una proposta di progetto, NON una capacità già implementata.
- Gate: se manca una strategia dimostrata e compatibile col pacchetto installato, `NO-GO`.

## P0 — verifica metadati candidata fail-open nell'installer legacy

- Fonte: `akai-remote-tests/05_safe_install_and_rollback.ps1`, `Test-PackageUpgradeGate` circa 1045–1112, invocato in install circa 2525.
- Il parser `aapt dump badging` è opzionale: se `aapt` è assente, il candidato non è ZIP valido o l'output non è interpretabile, `CandidatePackageName` e `CandidateVersionCode` possono restare nulli. La funzione rifiuta mismatch/downgrade **solo se i campi sono presenti**, quindi la sola mancanza di metadati non blocca l'esecuzione di `adb install -r`. Anche `InstalledVersionCode` può mancare.
- Gli attuali mock usano APK dummy che iniziano con `PK`, ADB simulato e nessun vero `aapt dump badging`, perciò non dimostrano il gate con artefatto autentico.
- Il *builder* finale `scripts/12_build_jarvis_final_candidate.ps1` controlla invece package, versionCode, firma, manifest e SHA-256: una misura indipendente positiva, **non una prova che l'installer rifiuti qualunque APK arbitrario**.
- Prima di installare: rendere obbligatoria la lettura degli esatti metadati del candidato e della versione presente, modificare i test mocked con artefatti/metadati realistici; o sostituire il legacy installer con una procedura finale che esegue questa verifica in modo fail-closed. `NO-GO` se i metadati non sono verificati. Non introdurre un bypass per CI che esisterebbe anche su hardware.

## P1 — abbinamento telecomando HTTP legacy

- Fonte: `RestApiRouter.java` circa 175–184; su porta HTTP 8088 permette `/api/auth/pair/request`, `/api/auth/pair/verify`, `/api/auth/pair`, `/api/auth/revoke`, `/api/command`, `/api/control/command`, `/api/control/text` per retrocompatibilità LAN. Non è corretto chiamare queste rotte TLS-only.
- AI, memoria, configurazione provider e diagnostica vengono invece bloccate in chiaro (HTTP 426). `TlsCertificateManager` gestisce Root CA locale e SAN; va confermata l'impronta Root CA fuori banda.
- Procedura di collaudo: usare HTTPS con CA verificata, mai inoltrare 8088/8443 su Internet, non trasmettere token o PIN via HTTP. L'eliminazione delle rotte HTTP legacy richiede una scelta di compatibilità con il client già installato.

## P1 — backup logico storico non raggiungibile su HTTP

- Fonte: `05_safe_install_and_rollback.ps1` intorno alla linea 49 imposta `$MemoryUrl=http://...:8088/api/ai/memory`, ma `RestApiRouter.java` obbliga HTTPS per questa API. Il tentativo di backup logico restituisce 426 (salvo divergenze OEM); il codice intercetta l'errore e prosegue con snapshot SQLite **binario obbligatorio**, fail-closed.
- Implicazione: non attribuire al backup logico REST un esito positivo. Verificare backup binario/WAL/TLS davvero recuperabili con owner, soprattutto su release non debuggable, dove `run-as` può essere negato.

## Rilievi positivi verificati direttamente nel sorgente

- Provider AI: `CloudProviderPolicy` ammette solo destinazioni HTTPS esatte DeepSeek/Kimi, no redirect Bearer e no LLM locale.
- Visione: `VisualProjectionService` owner consent separato, una sessione, superficie frame on-demand, limiti e STOP, verifica package foreground e contesto sensibile. `VisionSessionCoordinator` rifiuta frame revocati/stale e cancella JPEG dalla RAM dopo la richiesta.
- Esecuzione: `AkaiAiController` valida click via Accessibility, usa un'azione per iterazione e `GoalEvidenceVerifier` per evitare successi soltanto dichiarati. SQLite impara solamente procedure `STATE_VERIFIED`; `AkaiMemoryEngine` DB v6 implementa checkpoint WAL e `integrity_check`.
- Voce: FreeTTS opt-in con chiave cifrata e riserva quota conservativa, fallback eSpeak. Resta da verificare la reale disponibilità dell'account gratuito e l'audio sulla TV. Nessun costo cloud richiesto per l'audit.
- Compilazione: CI `#44252420128` esegue host tests + Android APK/JNI build + rollback simulato. Non produce un APK owner-signed distribuibile. Il builder Windows `12_build` confronta stessa firma certificato, SHA, manifest `debuggable=false`, versione 4+ e rifiuta asset TLS privati.

## Cose che questo audit NON prova

- MediaProjection OEM, race reali Android9, YouTube/Infinity e contenuti DRM, funzionamento telecomando iPhone/Safari, DNS/SAN TLS reali, uso memoria/CPU sulla AKAI, FreeTTS/DeepSeek/Kimi con chiavi dell'owner, recupero dell'APK sul dispositivo.
- Presenza/disponibilità della chiave **privata originale di firma** sul PC proprietario. La sola impronta pubblica SHA-256 del certificato non consente di firmare un APK.
- Backup completo dell'attuale A2 e la possibilità di ripristinarlo senza cancellare dati.

## Prima del primo install reale — checklist `NO-GO`/ `GO`

- [ ] Risolvere P0 recupero (Android9 build property + recovery APK/data path dimostrato, non downgrade presunto).
- [ ] Risolvere P0 parser metadati fail-open per procedura di installazione che verrà realmente usata.
- [ ] CI `completed/success` sul commit esatto usato per la build.
- [ ] APK owner-signed vCode4+ generato su PC privato, stesso certificato installato, hash SHA-256/manifest registrati.
- [ ] Backups attuali APK A2 + SQLite con WAL + TLS verificati ed effettivamente recuperabili, spazio disco verificato.
- [ ] HTTPS Root CA OOB e Home/launcher preservati; consenso owner specifico per la singola installazione.
- [ ] Solo allora collaudo reale dell'owner; mai dichiarare test hardware superati da mock.
