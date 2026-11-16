# JARVIS A1 — Integrazione candidata e gate di rilascio (16 novembre 2026)

## Sorgenti e tracciabilità

- Baseline **PR #1** `fix/pr01-endpoints-remote-activity`, SHA `875f7f10a3be69847366ed744be25a36c2f633b8`: beta confermata funzionante dal proprietario sulla AKAI AKTV5037N.
- Memoria/apprendimento **PR #7** `feat/jarvis-agent-a0-memory-learning`, SHA `b45497d347d070f62b108abc44f06482482169db`: memoria SQLite locale, skill verificate, retrieval e quarantena.
- Developer offline-test **PR #5** `feat/jarvis-cloud-developer-mvp`: worker e workflow GitHub con invocazione manuale, nessuna chiamata reale a DeepSeek/Kimi, limitata a generare una PR draft.
- Questo ramo A1 copia **soltanto** i file del developer dentro la baseline A0 e mantiene il codice TV di PR #7 invariato.

## Definizione corretta delle capacità

1. **Agente TV A0** (nel codice candidato): `ricorda che` / `cosa ricordi` / `dimentica che` salvano/leggono/eliminano fatti su SQLite, senza richiedere API né screenshot. Skill apprese solo quando il risultato è verificato. Retrieval lessicale max 3 fatti/550 caratteri, non memoria semantica illimitata.
2. **Agente di sviluppo A1** (off-TV, in codice candidato): il proprietario avvia volontariamente un workflow GitHub, seleziona provider, task e file consentito, conferma singola richiesta potenzialmente a pagamento, worker genera una **proposta non eseguita** su PR draft. Nessun auto-merge, auto-deploy o auto-esecuzione.
3. **Non ancora disponibili:** pianificazione completamente autonoma degli aggiornamenti software senza coinvolgimento proprietario, memoria semantica avanzata con provenance/expiry/confidenza, sincronizzazione diretta sicura tra TV e GitHub, test strumentati Android con cursor SQLite reale, deployment con signer verificato. Non presentare A1 come AGI.

## Gate CI prima di QUALSIASI proposta di rilascio

- `AKAI JARVIS CI`: Android 9 API 28, ARMv7 JNI, Java host, SQLite reale host, Web Remote JS, APK D8/AAPT2 e prove d'installazione/rollback **mock ADB** verdi sullo stesso HEAD.
- `JARVIS Cloud Developer — Safe CI`: unit test Python, mock provider senza rete, protezione file core, repository owner gate, consenso esplicito alle chiamate API, target filename/package check.
- Un `SUCCESS` CI non è prova dell'installazione su AKTV5037N, dell'audio iOS, della persistency Android SQLite oppure di una chiamata effettiva al provider.
- Verificare il diff esatto e l'ordine merge **PR #1 → PR #7 → PR #8**, sempre con review e consenso esplicito. Non integrare PR #5 separatamente sullo stesso `main` senza prima riconciliare i due rami, altrimenti si rischiano duplicati/conflitti.

## Gate dispositivo reale (bloccante, richiede nuovo consenso proprietario)

- **Nessun `adb install -r`, reset o modifica TLS, CA, Home v8 o porte 8088/8443 durante sviluppo.**
- Prima di un eventuale aggiornamento confrontare la **firma dell'APK già installato** con la candidata tramite `apksigner verify --print-certs` su copie APK attendibili; la chiave test della CI non dimostra compatibilità con quella installata sulla TV.
- Usare un nuovo artefatto firmato soltanto con la chiave di aggiornamento originale (non pubblicarla in GitHub o nei log). Se signer mismatch, interrompere: **non disinstallare** l'app per aggirare l'errore.
- Predisporre rollback installabile di versione precedente con dati e CA preservati; nessuna migrazione distruttiva.
- In collaudo autorizzato sulla TV: Home v8 D-pad, telecomando HTTP/HTTPS, pairing Safari, apertura app, voce, spegnimento PC, memoria `ricorda→ricorda?→dimentica` dopo riavvio processo, Guest Mode, procedure verificate vs fallite/quarantena, RAM PSS/latency.
- Non dichiarare pronto il rilascio fino a risultati hardware distinti da test host.

## Spese e sicurezza

- L'agente TV resta leggero; DeepSeek/Kimi sono API esterne **potenzialmente a pagamento**, non gratuite garantite.
- Workflow sviluppatore solo su `workflow_dispatch`; attivabile operativamente su GitHub dal branch predefinito dopo revisione/merge autorizzati.
- Solo l'owner del repository può avviare la job con provider; `approve_paid_api` è `false` per impostazione predefinita e richiede conferma su ogni nuova esecuzione.
- Il modello non può modificare da solo file del telecomando, launcher, server, memoria AI core o test. La proposta rimane codice non attendibile fino a revisione, build e consenso.

## Criterio GO / NO-GO

**GO solo per sviluppo/CI** quando entrambi i workflow sullo stesso HEAD sono `completed/success`. **NO-GO deploy sulla TV** finché non c'è nuova autorizzazione del proprietario, signer verificato e collaudo manuale della versione candidata.
