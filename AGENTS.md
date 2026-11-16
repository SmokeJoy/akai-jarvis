# Regole di lavoro per AKAI JARVIS — permanenti nel repository

Queste istruzioni valgono per chiunque sviluppi, revisioni, automatizzi o pubblichi codice in questo repository (ChatGPT/Codex, GitHub Actions, collaboratori e futuri agenti). Rappresentano il protocollo di controllo qualità richiesto dal proprietario il **16 novembre 2026**. Non dichiarare mai una modifica "finita", "perfetta", "pronta da installare" o "verificata sulla TV" senza prove corrispondenti.

## Protocollo obbligatorio di chiusura: progettare → verificare → cercare bug → migliorare → riverificare

1. **Comprendi il comportamento atteso**, la configurazione hardware reale, i vincoli Android 9/ARMv7/1,5 GB, gli effetti sulle API e le dipendenze. Leggi codice e documentazione ufficiale pertinente; non supporre che versioni, API, prezzi o firmware siano quelli ricordati. Se manca la prova, indicare il dato come sconosciuto.
2. **Audit prima della modifica:** controlla codice attuale, precedenti regressioni, issue/PR/CI, rischi su privacy, compatibilità e rollback. Elenca i requisiti osservabili (goal, pre/post-condizioni, limiti).
3. **Implementazione minima, isolata e revisionabile** in branch/PR dedicato. Evita refactor gratuiti e dipendenze pesanti sulla TV. API DeepSeek/Kimi solo se configurate e approvate dal proprietario; PC non deve essere necessario nell'uso quotidiano.
4. **Test negativi e positivi** per ogni modifica sostanziale: input malformato, timeout, mancanza di connessione, permessi, concorrenza/cancel, hardware vecchio, condizioni non verificabili, perdita UI, limiti di costo. Niente dati o segreti reali nei test. Controlla regressioni sui comandi di telecomando.
5. **Seconda revisione avversariale prima della chiusura:** rileggi diff completo e parti interagenti; cerca falsi positivi, race, indici errati, branch di errore saltati, conseguenze dopo reboot, asimmetrie versione/firma/DB, leakage credenziali, problemi di UI/UX. Valuta una soluzione più semplice/robusta e motiva i compromessi.
6. **Prove reali distinte da mock:** CI verde non significa prova sulla TV. Controlla HEAD SHA e run, riferisci esattamente test passati e falliti. Se manca hardware/test, stato=**NON VERIFICATO SUL DEVICE**. Non affermare assoluta assenza di bug.
7. **Verdetto evidence-based**: `STATE_VERIFIED` per un compito TV soltanto se il risultato finale osservabile coincide con l'obiettivo; comando inviato = `COMMAND_SENT`, non successo. Non inventare verifiche o capacità di osservazione.
8. **Rilascio protetto:** nessun auto-merge e nessun deploy sulla TV senza consenso del proprietario; controlla firma APK, versionCode, backup dati SQLite+WAL, identità TLS e rollback effettivo verso una versione funzionante prima di `adb install -r`. Non usare uninstall/pm clear/factory reset/Greenfield per aggiornare. Preserva Home v8 e web remote.
9. **Report finale obbligatorio**: obiettivo, codice e commit SHA, test CI (run id), esito test Android reale, bug identificati e risolti, limiti/criticità ancora aperti, criteri di go/no-go e prossimo passo preciso. Se ci sono test rossi o rischi irrisolti, NON dichiarare il lavoro concluso.
10. **Memoria operativa**: documenta progressi e anomalie nel repository per il passaggio tra chat/agenti; non basarti sulla memoria implicita del modello. Deduplica commenti e mantieni la cronologia delle verifiche.

### Specifico per il progetto attuale

- TV: AKAI AKTV5037N, Android 9, architettura ARMv7; JARVIS app `it.akai.customremote`, Home `it.akai.customhome.v8`.
- Controllo su TV via API 8088/8443 e ADB solamente quando necessario, con istruzioni esatte che il proprietario può eseguire sul proprio PC.
- Backup **baseline v1 funzionante**: `C:\Users\danie\JARVIS-backup-TV\backup_20261116_120946` + vault DPAPI abbinato; un nuovo install salverebbe v2 come rollback se non progettato esplicitamente, quindi fermarsi prima.
- PR #8 A1 e PR #9 A2 sono in sviluppo: nessuna funzionalità nuova è installata automaticamente sulla TV.
- La perfezione assoluta non è dimostrabile: massimizzare qualità e affidabilità, dichiarando con precisione ogni limite verificabile.
