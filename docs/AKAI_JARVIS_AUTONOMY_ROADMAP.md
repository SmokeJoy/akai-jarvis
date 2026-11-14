# JARVIS AUTOEVOLUTIVO — Decisione approvata e piano POST-BETA

> **Aggiornamento owner P0 (14/11/2026):** la roadmap sotto resta la visione di lungo periodo, ma la priorità è stata anticipata: **prima ripristinare in codice e test la compatibilità del telecomando HTTP LAN v5, poi consegnare JARVIS MVP realmente integrato, quindi avviare il Cloud Developer in un branch isolato**, senza attendere la distribuzione sulla TV per scrivere/testare l'agente cloud. Questa istruzione prevale sui riferimenti storici «solo dopo beta» relativamente allo **sviluppo su GitHub**, non autorizza auto-deploy o chiamate cloud fatturabili. [Direttiva P0](https://github.com/SmokeJoy/akai-jarvis/pull/1#issuecomment-6883455180).

**Decisione del proprietario confermata il 14/11/2026**. Approvata la direzione progettuale **autonomia progressiva senza ChatGPT/Antigravity come dipendenza operativa**. **Non** è un'affermazione che il codice esista o una richiesta di iniziare nuovi refactor oggi. Priorità non modificabile: **PR #1 stabilizzazione + prima beta TV**, poi l'autonomia software.

## 1. Invarianti di progetto

- JARVIS resta **unico backend Java leggero residente sulla AKAI Android 9/API 28, ARMv7**, memoria ~1,5 GB, eMMC 8 GB. Non installare un ambiente di sviluppo, Termux completo, agenti Python, compilatori o daemon nuovi sulla TV.
- **DeepSeek oppure Kimi via API**, uso dinamico solo quando serve. Comandi conosciuti / procedure SQLite: **zero token**; cloud non richiesto per task noti. PC personale spento durante l'uso normale.
- Riutilizzare **AkaiAiController, AiProviderAdapter, ScreenPerceptionEngine, AkaiMemoryEngine, TvController** e il backend esistente. Non degradare Home v8/v7 o streaming; osserva→pianifica→valida→agisci→verifica→memorizza solo l'esito verificato.
- Sicurezza proporzionata: chiavi in Keystore, budget cloud e workflow, operazioni in allowlist, accesso autenticato, log senza credenziali; il sistema non esegue comandi generici di shell su input LLM.
- Misurare prima/dopo PSS/RAM, CPU, latenza comandi, D-Pad, dimensione APK, token/costi, storage e affidabilità; nessun benchmark di host presentato come risultato fisico.

## 2. Livelli di autonomia

| Livello | Capacità | Può agire autonomamente? | Da implementare |
|---|---|---|---|
| **A0 — Procedural Skills** | Combinare azioni già approvate in skill JSON versionate, testare stato iniziale, verifica finale, salvataggio SQLite, retry bounded, rollback logico. | **Sì**, solo azioni innocue e reversibili nell'allowlist, con limiti. Le regole persistenti che impattano terze persone/costi o azioni irreversibili richiedono conferma. | **Primo modulo post-beta**, in app Java esistente |
| **A1 — Cloud Developer** | Da richiesta/pattern di errore: apre proposta, usa DeepSeek/Kimi in job isolato, legge repo e documentazione, genera patch/test, apre PR, ri-esegue CI in modo limitato. | Può **proporre e iterare nei branch isolati** dopo autorizzazione iniziale del workflow. Nessun merge/deploy autonomo. | GitHub Actions + orchestratore agente realmente configurato, **non GitHub Actions da solo** |
| **A2 — Update Manager** | Mostra changelog, firma SHA-256/certificato identico, versione, backup e rollback; offre APK compilato e verificato da pipeline. | **No installazione autonoma per impostazione predefinita**. Richiede approvazione esplicita dell'aggiornamento e intervento Android se PackageInstaller lo richiede. | Solo dopo prove di rollback TV |
| **A3 — Firmware/root** | Android/bootloader/driver/kernel. | **Mai auto-evoluzione** in questo perimetro. | Fuori progetto |

**GitHub Actions** esegue runner/compilazione, ma per scrivere codice serve un **agente developer/orchestratore esplicito** con API LLM, contesto repo, accesso con privilegi minimi e ciclo di test. Non supporre che Actions generi codice da solo o che le API cloud siano gratuite. Le PR create con `GITHUB_TOKEN` possono non innescare altre pipeline automaticamente; usare flussi verificati e non aggirare review. No permessi write globali se non necessari.

## 3. Architettura target minimale

```
Telecomando/voce smartphone
           ↓
JARVIS TV Java: Skill Engine + Executor + SQLite + limite azioni
      ↙                           ↘
Procedura nota 0 token      DeepSeek / Kimi API
      ↓                           ↓
Esegui + verifica            Piano validato JSON
                                  ↓
                          Esegui + verifica + salva
                                  |
                  Nuova funzione non gestibile dalla DSL
                                  ↓
                 Richiesta sviluppo a Cloud Developer
                 (job GitHub, non processo residente TV)
                                  ↓
                  Branch isolato → patch → mock/CI
                                  ↓
                  PR + changelog + rapporto prestazioni
                                  ↓
                  Revisione/gate → update firmato
                                  ↓
                 Conferma aggiornamento, backup, rollback
```

- La TV NON conserva credenziali con permessi di scrittura sul repository: se in futuro avrà un canale di richiesta sviluppo, usare API intermediaria a permessi minimi con autorizzazione e quota. Non esporre `GITHUB_TOKEN` o chiavi di firma.
- Niente download/esecuzione di script casuali o shell root conferiti all'LLM. I nuovi comandi sono *skill dichiarative* che invocano solo metodi Java consentiti; funzioni Java native passano da una nuova build APK e dal gate approvativo.
- Versionare il formato Skill (schema JSON con `skill_id`, intent, prerequisiti, sequenza, condizione esito, max tentativi, rollback); memoria migrazioni e tracciato verifiche. Rispettare licenze OSS.

## 4. Gates di sviluppo autonoma

**G1 — Beta reale stabile:** la PR #1 supera CI, backup/rollback controllato e test hardware minimi. Nessun avvio di A1/A2 prima di G1.
**G2 — Skill Engine:** test su 3 task senza LLM per procedure note, riavvio TV, fallimento nodo/accessibilità, cancellazione in corso; misure RAM/CPU, DB e tempi.
**G3 — Cloud Developer:** sandbox GitHub con workflow_dispatch, quote max richieste e max iterazioni, credenziali ridotte, timeout e test host, branch PR isolato; impedirgli accesso a firmatari/seg reti TV.
**G4 — Update Manager:** sha256 e firma dell'APK, pacchetto/versionCode compatibili, backup e rollback controllato, manifest/pacchetto Android 9, release nota; conferma per ciascuna release.
**G5 — Uso autonomo:** una skill non crea una nuova abilità di sistema, ma una nuova procedura verificata. Il software propone PR autonomamente, non è ancora un autoaggiornamento sicuro provato fino a G4.

## 5. Collaudo TV — nuova delega decisionale del proprietario

Il proprietario conferma che **ChatGPT deve dare il GO/NO-GO tecnico dei test se tutti i requisiti sono soddisfatti**. Questo delega il *giudizio tecnico*, NON costituisce prova che il backup sia già stato effettuato, né approva spese API o modifiche firmware.

**Stato tecnico al 14/11/2026:** PR #1 `fd258556c28b42c56cc8dd52282d1b5cb5bfd0a5`; GitHub Actions [push 43633499134](https://github.com/SmokeJoy/akai-jarvis/actions/runs/43633499134) e [PR 43633507069](https://github.com/SmokeJoy/akai-jarvis/actions/runs/43633507069) successful; test 37 Java/29 PS mock, build Android/JNI. **Non è collaudo fisico TV**.

**GO tecnico adesso:** verifiche **read-only/preflight** del device e del pacchetto, della firma/identità, dello stato v5 e di Home v8/v7 (nessuna installazione o force-stop). Antigravity deve restituire prove minime senza credenziali/IP pubblicati.

**NO-GO temporaneo per installazione:** prima serve riscontro verificato del **backup coerente APK + SQLite + WAL**, prova integrità/ripristino offline, firma candidabile identica a quella installata, APK di release non artefatto CI effimero, preflight e recovery script pronti. L'azione di backup fisico può richiedere **arresto temporaneo di JARVIS v5** ed eventuale `adb root`; non va confusa con un semplice preflight. Pubblicare prova dei gate nella PR e richiedere a ChatGPT il GO tecnico sul report, senza chiedere al proprietario di fare revisioni del codice.

Quando il gate backup è verificato, ChatGPT può rilasciare un **GO tecnico circoscritto** per collaudo JARVIS, con ritorno immediato al vecchio APK+DB se il watchdog fallisce. L'esecuzione di azioni effettive sulla TV va annunciata e circoscritta alla sessione, senza nascondere rischi o interrompere altri utenti. Non includere mai reset/flash/root persistente, merge GitHub, acquisti o API a pagamento.

**Importante:** il primo collaudo non garantisce Safari iPhone, Web Speech API, ingressi HDMI/DRM né la futura autonomia cloud; test separati e riportati come tali.

## 6. Fonti ufficiali da consultare prima dell'implementazione

- [GitHub Actions: workflow syntax, permissions](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
- [GitHub GITHUB_TOKEN: limiti e trigger](https://docs.github.com/en/actions/concepts/security/github_token)
- [GitHub: Settings per Actions e PR automatiche](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository)
- [Android PackageManager: canRequestPackageInstalls, API 26+](https://developer.android.com/reference/android/content/pm/PackageManager#canRequestPackageInstalls())
- [Android PackageInstaller.Session](https://developer.android.com/reference/android/content/pm/PackageInstaller.Session)
- [Documentazione principale progetto](OFFICIAL_TECH_REFERENCES.md)

## 7. Ordine per Antigravity/ChatGPT

1. **Adesso** chiudere il gate di preflight/backup & beta della PR #1; niente nuovi moduli di autonomia in questa PR.
2. Dopo beta, progettare e implementare *solo A0* con test e benchmark.
3. Dopo A0 validato, abilitare A1 cloud in job isolato, con workflow, trigger e responsabilità chiaramente distinti.
4. A2 solo dopo backup/rollback e firma verificati.
5. Loggare gli avanzamenti importanti in issue #4; aggiornare AGENTS.md solo su nuove decisioni stabili.

**Nota di trasparenza:** questo documento descrive una decisione e una roadmap approvate, non certifica che A0/A1/A2 siano già implementati.

## 8. Vincolo pre-esistente a qualsiasi autonomia futura
L'autoevoluzione non può alterare il sistema Android né i launcher e rimane confinata al telecomando `it.akai.customremote` e alle skill consentite. **Regressione del telecomando funzionante o perdita di HTTPS/Safari blocca ogni rollout**: gestire backup, firma, CA, pairing e prova reale prima della beta. Leggere [direttiva specifica](https://github.com/SmokeJoy/akai-jarvis/pull/1#issuecomment-6883385053). Le skill non devono usare terminale/root per bypassare permessi, e un agente cloud non può approvare da solo una nuova APK.
