# PR #18 — GitHub Actions runner not starting (18 novembre 2026)

## Evidenza dal provider — NON confondere con errore nei test

Il 18/11/2026 il run `#44254576801` sul commit `16a649bf1f2d` è `completed/success`, con job e step effettivamente eseguiti. Dal commit `16322bc70f7f` alle build diagnostiche v4 si registrano numerosi run `completed/failure` dopo 3–7 secondi **prima di qualunque step**, ad esempio:

- `#44256709238` su `16322bc70f7f`: FAIL pre-run.
- `#44261816387` su `0e0d1df97cb1`: FAIL pre-run.
- `#44265203005` su `1c0fad0fd9a5`: FAIL pre-run; il job `134667898627` indica `runner_name=""`, `steps=[]`, `annotations_count=2`. Il retry job #134693898292 (`run_attempt=2`) fallisce altrettanto prima degli step.

**Questi FAIL NON dimostrano che il codice JARVIS abbia superato o fallito i nuovi test.** L'ultimo PASS riguarda un commit precedente alle modifiche al builder diagnostico e ai mock strict installer.

La causa precisa non è dimostrata dal connettore GitHub: il testo delle due annotazioni non è accessibile tramite il relativo endpoint collegato e i job senza step non forniscono log eseguibili. **Non effettuare commit di prova o continui rerun per forzare il verde.**

### Ipotesi plausibile da verificare nel pannello GitHub

Nel repository privato un job che fallisce *prima* di ricevere un runner può dipendere da limiti di utilizzo, credito/budget Actions, account billing, policy del repository o servizio GitHub. Il connettore corrente non può leggere i dati di fatturazione dell'account. GitHub documenta esplicitamente blocchi per uso/budget e fornisce i controlli in Settings → Billing and licensing → Usage / Budgets. Solo il proprietario può confermare gli indicatori di quota; **nessuna spesa, aggiunta di carta o ampliamento budget è autorizzata da questo audit**.

Documentazione ufficiale GitHub:
- https://docs.github.com/en/actions/how-tos/troubleshoot-workflows
- https://docs.github.com/en/actions/concepts/billing-and-usage
- https://docs.github.com/en/billing/concepts/product-billing/github-actions

## Percorso di diagnosi alternativo, SENZA TV

`python scripts/13_jarvis_offline_host_gate.py` lancia in locale una serie di verifiche **indipendenti e senza credenziali**:

- Source contracts di profilo Diagnostic v4 / Release v5 e installatore (fail-closed).
- 8 test Python host, tra cui SQLite reale, rollback simulato, privacy/voce e MediaProjection source rules.
- 4 controlli Node (syntax Web Remote e simulazioni Web AI/voce).
- Compilazione Java degli stessi mock Android e dei test principali del job CI, quindi `UnitTests`, `AgentSkillGateTest`, `AgentFactMemoryTest`. Output Java in directory temporanea, NON nel repository.
- Richiede Python, Node, `java` e `javac`; ogni comando fallito o tool assente produce exit non-zero. Non fornisce un flag per saltare i Java test in modalità severa.
- Non invoca `adb`, nessun telefono/TV, nessun modello AI, nessun account cloud o signing key; non produce APK. Deve essere eseguito su un checkout attendibile della HEAD e riportato con SHA esatto e output conservato privatamente.

**LIMITI:** il gate locale non compila l'APK Android 9, non testa il native JNI ARMv7, non esegue l'intera suite PowerShell mocked ADB, non verifica una firma APK e non prova recovery OEM o hardware. Anche con exit 0 si deve riportare come `HOST_OFFLINE_PARTIAL_PASS`, mai come `CI_PASS` o `TV_GO`.

## Gate che restano obbligatori per la v4 diagnostica

1. Determinare perché GitHub non assegna il runner; non mascherare il FAIL. Ripristinare `completed/success` della suite completa **sull'esatto HEAD**, oppure raccogliere evidenza equivalente dell'intera suite su macchina isolata con revisione indipendente, distinguendo le parti non eseguite.
2. Produrre APK vCode4 `BuildProfile Diagnostic`, controllare `aapt dump xmltree` del pacchetto *compilato* con `android:debuggable=true`, firma proprietaria originale, SHA e integrità degli asset.
3. Verificare in modo non distruttivo che backup A2 v3, dati SQLite/WAL, identità TLS, launcher e percorso di recupero siano disponibili; un apk debug v4 non autorizza a cancellare A2 e NON garantisce downgrade alla vecchia A2 non-debug.
4. Soltanto con consenso esplicito installare v4 sulla AKAI e iniziare i test condotti dal proprietario. Dopo risultati positivi e approvazione distinta creare v5+ `BuildProfile Release`, `android:debuggable=false` compilato, stessa firma, `versionCode` superiore a quello in uso.

**Nessun intervento sulla TV o aumento di spesa è autorizzato da questo documento.**
