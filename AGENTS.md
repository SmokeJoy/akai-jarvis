# Guida per agenti — AKAI JARVIS

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
