# Guida per agenti — AKAI JARVIS

## PRIORITÀ ATTUALE P0 — CONTRORDINE PROPRIETARIO: TELECOMANDO INVARIATO + JARVIS AGENTE REALE (14/11/2026)
**Questa è la regola prevalente.** Il proprietario segnala che il progetto ha perso la funzione originaria. **Subito**: ripristinare nel CODICE della PR #1 la piena compatibilità del telecomando v5 (UI, pairing, HTTP LAN 8088, tasti, input), mantenendo JARVIS AI isolato/opt-in su HTTPS 8443; preservare Home v8/v7/stock e tutte le altre app. **DOPO** test non regressione del telecomando: completare JARVIS agente reale già presente nel codice (DeepSeek/Kimi via API, feedback UI, stato verificato, skills SQLite zero-token), con demo E2E host/mock e percorso UI/REST. Poi sviluppare l'autoevoluzione cloud in branch separato SENZA cambiare telecomando. **NO altri refactor, no nuovi framework, no solo documentazione.** [Direttiva esecutiva PR #1](https://github.com/SmokeJoy/akai-jarvis/pull/1#issuecomment-6883455180).
**Eccezione circoscritta al divieto storico di HTTP:** per evitare la regressione v5, mantenere temporaneamente **solo** legacy pairing/comandi/input/revoca su HTTP **LAN RFC1918** con PIN/Bearer/replay protection preesistenti, e asset statici pubblici. L'HTTP LAN non cifra i token (rischio esplicito); non estendere a memoria, diagnosi, dati personali, credenziali, configurazione AI, cloud o azioni privilegiate; raccomandare migrazione HTTPS collaudata. Niente bypass TLS. Qualsiasi regola precedente che imponesse `426` **anche al telecomando classico** è superata. La TV fisica **non** è autorizzata a nuove installazioni/ADB/root da questa direttiva. **Il telecomando in uso non va modificato prima di prove e rollback**.

Questo repository ha una **memoria operativa persistente** per ChatGPT, Antigravity e automazioni.

## Leggere all'inizio di ogni sessione
1. [Memoria canonica (decisioni, architettura, test, protocollo)](docs/AKAI_JARVIS_SUPERVISION_MEMORY.md)
2. [Stato vivo GitHub — issue #4](https://github.com/SmokeJoy/akai-jarvis/issues/4)
3. [PR #1 — backend JARVIS](https://github.com/SmokeJoy/akai-jarvis/pull/1), [PR #2 — audit grafico](https://github.com/SmokeJoy/akai-jarvis/pull/2), [PR #3 — Home v8](https://github.com/SmokeJoy/akai-jarvis/pull/3). Rileggere SHA HEAD, diff, CI e commenti nuovi **prima** di dichiarare lo stato.

## Direzione confermata dal proprietario (14 novembre 2026)
- **Unico JARVIS residente sulla TV AKAI Android 9/ARMv7, ragionamento con API DeepSeek/Moonshot Kimi selezionabili, senza PC/mini PC/LLM locale come prerequisito.**
- I comandi conosciuti e le procedure SQLite sono eseguiti localmente senza token. Il ciclo nuovo deve osservare/pianificare/validare/eseguire/verificare/apprendere con limiti di azioni e tentativi.
- Riutilizzare codice esistente. Dalle repo MobileAgent-Android/AgentPaw importare **solo idee o minimi pattern compatibili** dopo verifica licenze: non gonfiare l'APK né aggiungere demoni, servizi o framework completi.
- Prestazioni RAM/CPU e fluidità prima di tutto. Prove host/mock/emulatore **non sono** test fisici TV.

## Ruoli e confini
- Proprietario autorizza decisioni sostanziali, merge, costi, credenziali, installazioni e operazioni sulla TV.
- ChatGPT = supervisore indipendente; Gemini/Antigravity = implementatore nel branch PR.
- Review soltanto su delta significativi; evitare loop e commenti duplicati. Per nuovi `[BLOCKER → CHATGPT]`, analisi del codice, patch/test mirati e verifica.
- **Freeze hardware:** senza nuovo consenso specifico non eseguire ADB, deploy, backup reale, root, reset, modifiche Home, merge, token API veri o richieste fatturabili.
- Non salvare PIN, chiavi, IP LAN, SSID o dati privati in documentazione/commenti.

**Ordine delle fonti:** decisioni recenti del proprietario > GitHub codice e CI live > stato issue #4 > memoria documentale datata. Non trattare istruzioni vecchie nei commenti come ancora vincolanti quando sostituite esplicitamente.

## Documentazione tecnica ufficiale (OBBLIGATORIA)
Prima di cambiare API Android, UI, SQLite, Keystore, rete, provider LLM, pipeline CI o regole Antigravity consultare **[docs/OFFICIAL_TECH_REFERENCES.md](docs/OFFICIAL_TECH_REFERENCES.md)**: include i link ufficiali, le limitazioni Android 9/API28 e i gate di test. Prima codice esistente, poi documentazione ufficiale, infine pattern OSS. Non dedurre compatibilità da codice Android moderno; niente API30+ usate su API28 senza fallback.

## Progetto ChatGPT «AKAI TV BOOST»
Le istruzioni pronte da applicare nel progetto ChatGPT sono in **[docs/CHATGPT_PROJECT_AKAI_TV_BOOST.md](docs/CHATGPT_PROJECT_AKAI_TV_BOOST.md)**. Il progetto ChatGPT e il repository GitHub sono sistemi distinti: gli aggiornamenti su GitHub NON cambiano automaticamente le impostazioni della UI del progetto. Per le nuove chat, leggere sempre la fonte canonica e l'issue #4, non soltanto il testo del progetto.

## Decisione approvata 14/11/2026 — JARVIS autoevolutivo, sviluppo isolato
Leggere **[Roadmap autonomia](docs/AKAI_JARVIS_AUTONOMY_ROADMAP.md)**. Il proprietario ha approvato l'architettura e ora richiede di **iniziare a costruire l'agente concretamente** dopo il fix P0 del telecomando, su branch separato per l'autoevoluzione cloud; mai interferire con il runtime del telecomando. No Termux, shell root o compilatori residenti sulla TV; nuove procedure compatibili possono diventare autonome dopo verifica. Nuove APK passano da CI, firma, gate e conferma installazione. L'AI non può fare merge/deploy/flash da sola. Non confondere GitHub Actions con un coding-agent già configurato.

**Delega collaudi:** il proprietario incarica ChatGPT del *GO/NO-GO tecnico* quando le evidenze sono sufficienti. Per la PR #1 (ultimo commit verificato `fd258556c28b42c56cc8dd52282d1b5cb5bfd0a5`, CI 2/2 successful), **GO solo a preflight read-only**, non a installazione immediata. Backup fisico, estrazione dati e installazione richiedono gate e comunicazione esplicita degli effetti; nessun nuovo intervento è già avvenuto. Stato vivo sempre nell'issue #4. Le credenziali, modifiche firmware/merge e chiamate cloud a pagamento non sono comprese.

## Regola inderogabile: nuova versione JARVIS = SOLO app telecomando + gate HTTPS/iPhone
**Decisione esplicita del proprietario 14/11/2026.** Il pacchetto oggetto dell'upgrade è **esclusivamente** `it.akai.customremote`. Il telecomando v5 precedente funzionava e deve rimanere recuperabile. **Non modificare/fermare/installare** `it.akai.customhome.v8`, `it.akai.customhome`, Cultraview, WebView OEM, impostazioni Home, firmware, tuner, HDMI o altre app. In caso di incompatibilità rete o app, rollback solo APK+DB del telecomando.
**Problema storico prioritario:** HTTP sulla LAN permetteva il telecomando base ma impediva l'uso delle funzionalità vocali/web richiedenti un contesto sicuro; la nuova implementazione richiede HTTPS 8443 per qualsiasi comando autenticato e lascia HTTP 8088 solo per bootstrap, status e CA. **Questo crea rischio di regressione funzionale** se pairing/certificato TLS/iPhone Safari non sono pronti. Gate beta: baseline tasti v5 → backup coerente APK/SQLite+WAL/rollback → firma e versionCode di release → test HTTPS 8443 e CA fingerprint fuori banda + SAN, PIN, token, D-pad, OK, BACK, volume da iPhone → test voce Safari separato → test PC spento; rollback se telecomando regredisce. **Eccezione P0 compatibilità telecomando v5:** consentire solo pairing e comandi legacy su HTTP LAN protetto dall'autenticazione già esistente; niente API AI, memoria, chiavi o contenuti sensibili HTTP. Il rischio intercettazione token LAN è documentato. Niente bypass TLS né HTTP pubblico. La precedente indicazione «niente fallback HTTP» è esplicitamente superata LIMITATAMENTE alle funzioni legacy. Prima di richiedere installazione leggere [direttiva specifica PR #1](https://github.com/SmokeJoy/akai-jarvis/pull/1#issuecomment-6883385053). **GO solo read-only preflight finché non ci sono prove reali di backup e firma; installazione non già eseguita.**

## PROTOCOLLO DI QUALITÀ RICHIESTO DAL PROPRIETARIO — 16/11/2026 (vincolante)

**Prima di dichiarare qualunque attività conclusa**, ogni agente deve applicare una revisione avversariale completa del risultato; non basta che una patch compili, che la CI sia verde o che una prima prova sembri funzionare.

1. **Ricerca e documentazione:** rileggere requisiti e vincoli, codice reale, issue/PR recenti, API e documentazione ufficiale appropriata. Non dedurre il supporto Android 9 da tutorial per release moderne. Distinguere fatti, ipotesi e dati non verificati.
2. **Audit iniziale e finale:** controllare diff, dipendenze, contratto API, vecchi comportamenti, memoria/SQLite, concorrenza, timeout, validazioni input, privacy, regressioni, degrado RAM/CPU. Cercare attivamente errori e soluzioni tecnicamente migliori, motivando i compromessi.
3. **Test e verifiche:** unit test positivi e negativi, test di integrazione, regressioni del telecomando, CI riferita all'esatto HEAD SHA e log reali. NON confondere host mock o build APK con prova su Smart TV fisica. Riparare test falliti senza indebolire i gate o alterare aspettative per nascondere bug.
4. **Evidenza, non affermazioni:** un comando inviato non equivale al compito completato. Usare stato `COMMAND_SENT` quando manca osservabilità; `STATE_VERIFIED` soltanto quando la condizione finale richiesta è comprovata. Nessuna auto-memorizzazione di procedure non validate.
5. **Rilascio protetto:** nessun auto-merge, ADB modifica, installazione APK, root, reset o migrazione hardware senza consenso specifico. Verificare prima backup versionato funzionante, dati SQLite+WAL, certificati TLS, signing APK, rollback e Home invariata.
6. **Report di chiusura obbligatorio:** obiettivo, file e commit, test/CI effettivi, prove hardware (o stato NON VERIFICATO SUL DEVICE), bug individuati e corretti, alternative valutate, criticità residue e GO/NO-GO. Non dichiarare mai "perfetto", "finito" o "senza bug" in assenza di evidenze.
7. **Memoria duratura tra chat e agenti:** aggiornare issue/memoria tecnica con stati precisi, evitare duplicati e istruzioni obsolete. I messaggi di chat non sostituiscono la documentazione canonica.

**Ruolo corrente:** il proprietario ha sospeso Antigravity per esaurimento dei crediti; ChatGPT può sviluppare direttamente nel repository con GitHub, mentre il proprietario esegue i comandi PC/ADB richiesti per prove reali, sempre dopo spiegazione dei loro effetti. La delega di implementazione non concede autorizzazione a installare/mergiare/cancellare dati automaticamente.

La qualità assoluta non è dimostrabile; l'obiettivo è massimizzare affidabilità e trasparenza attraverso verifiche riproducibili e una seconda revisione prima di ogni chiusura.
