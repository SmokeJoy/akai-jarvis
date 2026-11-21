# JARVIS — Protocollo obbligatorio di revisione finale indipendente (owner, 18/11/2026)

**Stato:** regola permanente e vincolante per ogni attività JARVIS: PR, bugfix, automazione, APK diagnostico v4, release v5+, configurazione Web Remote e documentazione. Si applica PRIMA di usare le parole **finito, risolto, pronto, approvato, PASS, sicuro, installabile** riferite a una modifica. Il criterio richiede evidenze, non affermazioni. Non implica la promessa impossibile di assenza assoluta di bug.

## 1. Doppia revisione obbligatoria prima della consegna

**Passaggio A — controllo di correttezza:** verificare l'esatta richiesta e gli invarianti owner in `AGENTS.md`; leggere il codice sorgente **salvato realmente nel repository** sullo SHA che sarà rilasciato; esaminare diff, interazioni e dipendenze; eseguire test, lint, build e verifiche appropriate senza eludere controlli. Registrare chi ha verificato cosa e con quali risultati. Verificare i file *dopo* il commit, non soltanto la bozza prima della scrittura.

**Passaggio B — revisione critica avversariale:** rimettere in discussione la soluzione anche se tutti i test passano. Cercare attivamente:
- logica errata, assunzioni implicite e casi limite non previsti, output AI che inventano successi;
- race/timeout/STOP tardivo, error handling silenzioso, retry, idempotenza e stato dopo crash/riavvio;
- regressioni, retrocompatibilità con A2 v3, firma, dati SQLite v5/v6, WAL, TLS e rollback effettivamente recuperabile;
- Android 9/API28 ARMv7, D-pad/Accessibility, MediaProjection/DRM, Web Remote Safari/iPhone/Android, RAM/CPU/eMMC della AKAI e PC spento;
- privacy, protezione di chiavi API e log, consenso per immagini/voce, uso unicamente DeepSeek/Kimi per inference, quote e rischi economici;
- attacchi da input non fidato, token/PIN, HTTP vs HTTPS e accesso limitato alla LAN;
- **se esiste una soluzione più semplice, più leggera, più robusta o meno costosa**, confrontarla concretamente con l'implementazione (trade-off, compatibilità e prove, non estetica o cambi gratuiti).
- errori nuovi introdotti dalla revisione stessa. Ogni fix riavvia A e B sulla nuova HEAD.

Se disponibile, affidare il secondo passaggio a un revisore/strumento indipendente dal primo; in mancanza, eseguire una nuova lettura critica separata con checklist e scenari di confutazione. Non chiamarla “indipendente” se è lo stesso agente.

## 2. Documentazione e verifica esterna, non supposizioni

- Prima di cambiare comportamento Android/SDK, sicurezza, firma APK, aggiornamenti, rete, API DeepSeek/Kimi, GitHub Actions, strumenti PowerShell o JNI, **consultare le istruzioni ufficiali attuali del componente interessato**, confrontando versione, ambiente supportato, data e implicazioni per Android 9. Usare ricerche esterne solo quando utili; citare URL/documenti e data della verifica nel rapporto. Se non accessibili, dire esplicitamente “documentazione non verificata”.
- Distinguerne i fatti documentati dalle deduzioni; verificare direttamente una supposizione importante o lasciare un gate aperto. **Non trattare mock come hardware**, compilazione APK come installazione, runner CI non assegnato come test di codice fallito, HTTP 200 come azione TV verificata o output LLM come successo.
- Riferimenti di base, da approfondire dove pertinente:
  - Android Developers — firma APK e certificato identico per aggiornamenti: https://developer.android.com/studio/publish/app-signing
  - Android / SDK — verificare documentazione della specifica API usata, targetSdk 28 e supporto hardware OEM.
  - GitHub Docs — diagnosi workflow, job logs, uso e fatturazione: https://docs.github.com/en/actions/how-tos/troubleshoot-workflows
  - OWASP MASTG/MASVS — controllo privacy, log, dati e sicurezza delle app mobili: https://mas.owasp.org/MASTG/0x04b-Mobile-App-Security-Testing/
  - OWASP MASWE-0005 — evitare dati sensibili nei log diagnostici: https://mas.owasp.org/MASWE/MASVS-STORAGE/MASWE-0005/

## 3. Matrice di prova per rischi reali

- Ogni fix deve avere almeno un test di regressione sul comportamento corretto e, dove appropriato, un test negativo/di errore che sarebbe fallito prima della correzione; valutare comportamenti con dati assenti, permessi negati, rete interrotta e risultati asincroni.
- Verificare il codice con la **HEAD esatta**: commit Git SHA, suite/step eseguiti, stato PASS/FAIL/NOT_RUN, hash e profilo dell'APK, certificato firmatario, codice versione, versione Android/ABI, ambiente di esecuzione.
- **Valutazione multilivello separata:** `SOURCE_REVIEW` (analisi manuale), `HOST_TESTS` (Python/Node/Java), `CI_ANDROID_BUILD` (APK/ARMv7/manifest/integrazione), `SIGNER_BACKUP_RECOVERY` (owner PC + TV read-only), `TV_REAL_TESTS` (solo dopo installazione owner-approved). Ogni livello si registra `PASS`, `FAIL`, `BLOCKED`, `NOT_RUN`; non si propagano gli esiti da uno all'altro.
- Se GitHub non assegna il runner, registrare `CI_BLOCKED_NOT_EXECUTED` con prove; il gate host parziale `scripts/13_jarvis_offline_host_gate.py` NON lo trasforma in PASS. Non saltare test, modificare aspettative per farle passare, disabilitare workflow, usare chiavi provvisorie o dichiarare pronto l'APK.
- I test mock non dimostrano ripristino Android9 di un APK precedente non debuggable. Non installare o modificare la TV per “scoprire” se il recupero funziona senza backup e consenso.

## 4. Standard obbligatorio del rapporto PR / handoff

Ogni intervento sostanziale chiuso deve includere:

1. **Oggetto e vincoli:** richiesta owner, invariant coinvolti, cosa è stato cambiato e cosa no.
2. **Evidenze riproducibili:** HEAD SHA e link PR, diff esaminati, test realmente eseguiti, ambiente, risultati e build/signature checks.
3. **Seconda revisione:** quali failure mode alternativi, bug possibili e opportunità di semplificazione sono stati controllati; test negativi; conclusioni e limiti.
4. **Documentazione verificata:** fonti ufficiali rilevanti e incompatibilità riscontrate; distinguere ipotesi da risultati verificati.
5. **Rischi residui:** severity P0/P1/P2, contromisure e owner degli eventuali blocchi; dire esplicitamente cosa NON è verificabile senza hardware/account/chiave privata.
6. **Decisione inequivocabile:** `GO_FOR_HOST_WORK`, `GO_FOR_OWNER_PREFLIGHT_READ_ONLY`, `GO_FOR_OWNER_TV_TEST` oppure `NO_GO`. Nessuna decisione per semplice impressione di completezza.

Per dichiarare un lavoro **finito per la fase dichiarata**, ripetere controlli e revisione sulla HEAD successiva a ogni fix. Se manca una prova, riportare **parziale/bloccato** e identificare il dato mancante. Mai dichiarare `GO_FOR_OWNER_TV_TEST` senza full CI o equivalente completo tracciato, APK v4 compilato e firmato dalla chiave originale, backup APK+DB/WAL+TLS effettivamente verificato e percorso conservativo di recupero, più approvazione owner per l'installazione.

## 5. Ambito della modifica e autorizzazioni

- Non modificare fisicamente TV, firmware, HOME, bootloader o preferenze, né consumare API/crediti, senza il consenso esplicito previsto dagli invarianti owner.
- APK **v4 Diagnostic**: `android:debuggable=true` nel manifest compilato e firma originale, collaudo guidato dall'owner. APK **v5+ Release**: `android:debuggable=false` nel manifest compilato, soltanto dopo validazione owner, firma originale e versionCode superiore.
- Correggere in autonomia difetti del codice e dei test **all'interno della PR Draft**; non introdurre complessità o nuove dipendenze senza evidenza di beneficio, necessità e compatibilità.
- Una revisione critica deve ridurre il rischio, non trasformarsi in refactoring continuo: motivare ogni modifica, valutare costi e non spostare la linea di arrivo senza un problema concreto.
