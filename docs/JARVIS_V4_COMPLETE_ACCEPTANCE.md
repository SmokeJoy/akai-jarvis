# JARVIS v4 completa — contratto di accettazione vincolante (owner, 18 novembre 2026)

## Ultima decisione del proprietario (sostituisce precedenti requisiti v5)

**Tutte le funzioni devono essere già sviluppate e incluse nella v4 Diagnostic**, anche se la TV reale dovrà necessariamente usarla per la verifica finale. **La v5 NON deve introdurre nuove funzionalità**: sarà la stessa base sorgente già collaudata nella v4, ricompilata con `android:debuggable=false` e gli inevitabili metadati di versione maggiorati per consentire l'aggiornamento Android. Stessa firma originale, stessi dati/servizi/API, nessun refactoring o feature aggiunta alla v5. Nuove modifiche sostanziali dopo il collaudo richiedono una nuova v4 diagnostica e ripetizione delle prove.

Tutti e quattro i gate sono obbligatori **nella v4**. Questi obblighi si aggiungono alle regole permanenti di `AGENTS.md` e alla doppia revisione `docs/JARVIS_MANDATORY_SECOND_PASS_REVIEW.md`. PR #18 resta Draft durante sviluppo, nessun merge/deploy/ADB write/OTA senza consenso separato per la singola operazione.

## V4-1 — Navigazione multipasso fra app, con apprendimento reale

- Inventario effettivo dei package avviabili, D-pad e Accessibility, raccolta fresh UI, cattura MediaProjection su consenso Android e consenso separato all'invio cloud, DeepSeek/Kimi soltanto, stepwise loop e STOP immediato.
- Il planner non può produrre clic ciechi; ogni azione deve essere validata sul contesto attuale, il risultato confermato da evidenza indipendente (`STATE_VERIFIED`), non da testo AI o da `COMMAND_SENT`.
- Una procedura SQLite può essere salvata o aggiornata **solo** dopo successo verificato; percorsi non funzionanti vengono messi in quarantena, mai riprodotti all'infinito.
- Prove reali su app differenti: avvio, ricerca e navigazione, riproduzione di una diretta con verifica, app non installata, UI ambigua, UI cambiata, DRM, mancanza API/rete, consenso negato e STOP.
- **Limite non aggirabile:** Android e DRM possono rendere alcune UI non osservabili o incontrollabili; vietato bypass. Documentare copertura e fallimenti gestiti correttamente. Non chiamare universale ciò che non può essere verificato.

## V4-2 — OTA già funzionante nella v4 (PC spento)

- Menu "Verifica aggiornamenti" realmente utilizzabile dalla TV; endpoint release HTTPS durevole senza PC, manifest autenticato con chiave pubblica pinned, controllo canale/versionCode monotono, SHA-256 dei byte scaricati, metadati APK e certificato originale letti davvero da Android, API28/ARMv7, limiti spazio/dimensione/timeout, impossibilità di download di segreti.
- Download e installazione soltanto con conferma proprietario e PackageInstaller di Android 9; nessuna installazione silenziosa. Se l'OEM non permette il flusso diretto, soluzione manuale assistita *dalla TV* con PC spento, verificata e autorizzata.
- Prove su v4: ricerca aggiornamento reale di staging più recente e correttamente firmato, **solo su test dispositivo autorizzato**, con esito post-install; nessuna release, APK corrotto, URL/manifest malevoli, signer diverso, versionCode inferiore, mancanza rete, spazio insufficiente, annullamento, interruzione. Pianificare versionCode dei candidati di staging e successiva v5 > massimo installato. Non pubblicare APK diagnostiche.
- La v4 include tutto il percorso OTA attivo/operativo; la v5 non aggiunge tale funzione, cambia solo profilo debug e metadati versione.

## V4-3 — Prestazioni reali dell'AKAI

- Baseline e misure dopo l'installazione owner-approved su AKAI AKTV5037N (Android 9/API28 ARMv7, ~1.5 GB RAM): PSS/RSS, MemAvailable, CPU/ANR/crash, latenza comandi e apertura app, carico screenshot e trasferimenti cloud, footprint disco, sessioni ripetute, impatto al riavvio e in idle.
- Conservare funzionamento del tuner/antenna, HDMI, Home v8/LTvLauncher, telecomando originale, Web Remote Safari/iPhone/Android a PC spento, TLS/Root CA, Pairing, memoria SQLite, volume, standby e STOP.
- I risultati devono essere numerici e ripetibili con scenario e log sanitizzati. Test host e CI non sostituiscono benchmark hardware. Regressioni gravi P0/P1: NO-GO.

## V4-4 — APK diagnostico con firma originale e recupero reale

- Build **v4 Diagnostic**: `versionCode=4`, `android:debuggable=true` verificato nel manifest compilato, package `it.akai.customremote`, Android 9 ARMv7, firma dello stesso certificato A2, SHA-256 e metadati reali verificati, zero keystore TLS nel pacchetto.
- APK generato sul PC privato dell'owner, mai dalla firma temporanea CI; CI completa PASS sull'HEAD reale e doppia revisione. Proteggere chiave privata e credenziali; nessun upload su GitHub pubblico.
- Inventario A2 e backup APK+SQLite/WAL+TLS, prove concrete di recuperabilità con dati esistenti preservati, e strategia funzionante con Android 9 che **non assuma** il downgrade automatico a vCode 3 non-debuggable. Nessun reset, `pm clear`, uninstall o alterazione CA per fare passare il test.
- Preparare il collaudo con consent owner per una installazione v4 diagnostica **solo dopo gate preflight/backup**; una volta installata, raccogliere le prove hardware e OTA sopra. Distinguere `GO_FOR_OWNER_V4_DIAGNOSTIC_TEST` da `V4_COMPLETE_ACCEPTED`. La CI verde da sola non certifica v4 completa.

## Decisione di rilascio e transizione v4 -> v5

- `V4_COMPLETE_ACCEPTED` solo quando V4-1..V4-4 PASS, inclusi hardware/OTA e recuperabilità, con approvazione esplicita owner.
- Qualsiasi gate `FAIL / BLOCKED / NOT_RUN`: `V4_INCOMPLETE`; proseguire lo sviluppo e i test senza presentarla come finita.
- Solo **dopo** `V4_COMPLETE_ACCEPTED`, creare la **v5 Release** dalla stessa base sorgente validata, cambiando esclusivamente build profile `Diagnostic -> Release`, `android:debuggable true -> false`, versione/nome/metadata obbligatori per installare `versionCode > installed`, e firma originale invariata.
- Nessuna nuova funzionalità o differenza di comportamento prevista nella v5; verificare per diff/artefatti che non entrino modifiche funzionali, poi ripetere CI completa, firma, preflight installazione e minimo smoke test TV con approvazione owner.
- Non considerare l'espressione "solo debug" come richiesta di APK byte-identico: il manifest Android deve cambiare flag/versionCode e la firma APK cambia necessariamente hash. **Il codice applicativo funzionale rimane identico.**
- I requisiti v4 sostituiscono il precedente documento `docs/JARVIS_V5_MANDATORY_RELEASE_GATES.md`, preservato come riferimento storico/deprecato.
