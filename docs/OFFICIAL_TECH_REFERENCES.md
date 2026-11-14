# AKAI TV BOOST / AKAI JARVIS — Fonti tecniche ufficiali

**Aggiornato 14 novembre 2026.** Indice pratico per ChatGPT, Antigravity, GitHub Actions e future chat. Prima di implementare un cambiamento verificare l'ultima versione delle fonti, le API minime, gli esempi e le limitazioni sull'**Android 9 / API 28** della AKAI. Il link a una documentazione moderna **non implica** che la relativa funzione esista su Android 9.

> La fonte della decisione progettuale è `AGENTS.md` e `docs/AKAI_JARVIS_SUPERVISION_MEMORY.md`; la fonte del **codice attuale** è la PR interessata. Questo è un catalogo di documentazione, non un'autorizzazione al deployment.

## A. Regole e orchestrazione agenti

| Fonte ufficiale | Utilizzo concreto |
|---|---|
| [Google Antigravity — Rules](https://antigravity.google/docs/rules/) | Caricamento automatico di `AGENTS.md`, `GEMINI.md` e `.agents/rules/*.md`; precedenza e ambiti workspace/global. Preferire il nostro `AGENTS.md` nella root. |
| [Google Antigravity — Learn](https://antigravity.google/docs/commands/learn/) | Quando una decisione diventa stabile, documentarla in file del progetto invece di affidarsi alla chat. |
| [GitHub — Monitor workflows](https://docs.github.com/en/actions/how-tos/monitor-workflows) | Verificare esiti Actions reali e separare build/CI da prove hardware. |
| [GitHub — Using workflow run logs](https://docs.github.com/en/actions/how-tos/monitor-workflows/use-workflow-run-logs) | Analisi delle righe di errore, job e artefatti; non fidarsi di riassunti non verificati. |
| [GitHub — About protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches) | Policy PR, stato dei check e gate merge; nessun merge automatico autorizzato. |

## B. Android 9, accessibilità e controllo televisore

| Fonte ufficiale | Utilizzo concreto |
|---|---|
| [Android 9 — Migration](https://developer.android.com/about/versions/pie/android-9.0-migration) | Compatibilità reale Android 9, servizi, permessi e vincoli della piattaforma. |
| [Android 9 — Behavior changes targeting API 28](https://developer.android.com/about/versions/pie/android-9.0-changes-28) | Foreground service, rete, restrizioni sistema. |
| [Android — AccessibilityService](https://developer.android.com/reference/android/accessibilityservice/AccessibilityService) | Osservazione/focus/interazioni UI in `ScreenPerceptionEngine`. `takeScreenshot()` solo **API 30+**, NON per questa TV. |
| [Android — AccessibilityNodeInfo](https://developer.android.com/reference/android/view/accessibility/AccessibilityNodeInfo) | Lettura albero accessibilità, testi/elementi cliccabili e riciclo oggetti. |
| [Android — MediaProjectionManager](https://developer.android.com/reference/android/media/projection/MediaProjectionManager) | Soltanto come eventuale fallback visivo on-demand, con consenso del dispositivo e test reali; non introdurre screenshot permanenti. |
| [Android TV — TV app quality](https://developer.android.com/docs/quality-guidelines/tv-app-quality) | Focus D-pad, telecomando, UX, prestazioni, test; adattare alle funzionalità disponibili nel firmware OEM. |
| [Android — WebView](https://developer.android.com/develop/ui/views/layout/webapps/webview) | Compatibilità browser/HTML remoto. Sulla AKAI il provider OEM rilevato è `com.android.webview` e non va scambiato per `com.google.android.webview`. |

## C. Sicurezza e dati locali

| Fonte ufficiale | Utilizzo concreto |
|---|---|
| [Android Keystore system](https://developer.android.com/privacy-and-security/keystore) | Proteggere le API key in `KeystoreSecurityHelper`; evitare fallback `b64:` non cifrato. |
| [Android KeyGenParameterSpec](https://developer.android.com/reference/android/security/keystore/KeyGenParameterSpec) | Parametri AES/GCM ed eccezioni per chiavi Keystore (API 23+). Verificare l'hardware invece di presumere un secure element. |
| [Android — SQLite](https://developer.android.com/training/data-storage/sqlite) | Persistenza `AkaiMemoryEngine`, transazioni e schema; salvataggio **solo dopo verifica**. |
| [Android — Network security configuration](https://developer.android.com/privacy-and-security/security-config) | Trust anchors, HTTPS, eccezioni soltanto motivate; niente trust-all o disattivazioni TLS. |

## D. Performance e diagnosi — priorità TV BOOST

| Fonte ufficiale | Utilizzo concreto |
|---|---|
| [Android — Memory quick assessment](https://developer.android.com/topic/performance/memory/guide/tools-overview) | PSS, swap, ZRAM, diagnostica RAM. Metriche TV misurabili solo **dopo consenso ADB/test fisici**. |
| [Android — dumpsys](https://developer.android.com/tools/dumpsys) | `meminfo`, `procstats` e processi; confronti prima/dopo riproducibili. |
| [Android — Memory overview](https://developer.android.com/topic/performance/memory) | Riduzione di overhead, leak, allocazioni, pressione RAM e processi pesanti. |

### Criteri quantitativi da riportare — senza inventare soglie universali
- Dimensione APK, DEX e librerie aggiunte
- PSS/USS/SwapPSS e RAM libera del processo TV; CPU idle e carico durante operazioni (solo dispositivo autorizzato)
- Tempo p50/p95 comando locale noto (0 token), Cold start, reattività tasti D-pad
- Tempo/numero di snapshot e passaggi per aprire una app e verificare il risultato
- Token/costi API stimati dal client vs utilizzo ufficiale fatturato del provider
- Crescita DB SQLite e numero di procedure effettivamente verificate

Ogni benchmark specifica: **SHA, dispositivo/ambiente, metodo, numero campioni, risultati prima/dopo**. Non comparare test mock con TV reale.

## E. DeepSeek API — provider cloud

| Fonte ufficiale | Utilizzo concreto |
|---|---|
| [DeepSeek — Chat Completions API](https://api-docs.deepseek.com/api/create-chat-completion/) | Endpoint `/chat/completions`, modelli correnti, formato messaggi, limiti e risposte. |
| [DeepSeek — Tool Calls](https://api-docs.deepseek.com/guides/tool_calls/) | Tool JSON/schema, gestione risultati e validazione server-side dei comandi generati. |
| [DeepSeek — Models & Pricing](https://api-docs.deepseek.com/quick_start/pricing) | Verifica prezzi/model ID prima di qualsiasi richiesta reale; NON affidarsi a tariffe hardcoded nel codice storico. |

**Gate:** sempre validare gli argomenti lato app; il modello non è un executor fidato. Risposte 401/402/429/offline, timeout, JSON invalido, test senza chiavi vere.

## F. Moonshot / Kimi API — provider cloud

| Fonte ufficiale | Utilizzo concreto |
|---|---|
| [Moonshot AI — Tool Calls](https://moonshot-ai.gitbook.io/moonshot-ai/getting-started-guide/use-kimi-api-for-tool-calls) | API base internazionale `https://api.moonshot.ai/v1`, strumenti, `tool_call_id`, ruoli `assistant` e `tool`. |
| [Moonshot AI — Documentazione completa](https://moonshot-ai.gitbook.io/moonshot-ai/llms.txt) | Indice aggiornato per modelli, API, autenticazione, errori e limiti; selezionare modelli esistenti per la specifica chiave. |

**Nota:** l'endpoint `api.moonshot.cn` e quello `.ai` sono riferiti a piattaforme/regioni diverse; una chiave **Kimi Coding** non è automaticamente una chiave Moonshot Open Platform. Non pubblicare chiavi e non eseguire richieste fatturabili senza consenso.

## G. Fonti open source candidate (NON specifiche ufficiali Android)

Non installare interi framework sulla TV. Consultare unicamente il codice/README/licenze upstream:
- [MobileAgent-Android](https://github.com/GiggleWang/MobileAgent-Android): pattern di esecuzione atomica, verifica, replanning
- [AgentPaw](https://github.com/YHLFurry/AgentPaw): checkpoint, skill, retry finiti
- [DeerFlow](https://github.com/bytedance/deer-flow): architettura server, NON dipendenza runtime AKAI

Il riuso di un'idea è diverso dalla copia di codice. Prima di copiare sorgenti verificare compatibilità, licenza e notice pertinenti; ogni importazione deve mostrare beneficio misurabile contro nuove dipendenze/RAM.

## Ordine obbligatorio per usare le fonti

1. Nuova richiesta → leggere `AGENTS.md`, memoria canonica, issue #4 e PR live.
2. Individuare **classe e livello API Android** coinvolti; consultare la documentazione **ufficiale** prima di proporre una patch.
3. Proporre la modifica più piccola con test positivi/negativi e confronto prestazionale, senza aprire un altro cantiere.
4. Antigravity implementa su PR; ChatGPT revisiona codice diff/CI; proprietario autorizza separatamente hardware/merge/real API.
