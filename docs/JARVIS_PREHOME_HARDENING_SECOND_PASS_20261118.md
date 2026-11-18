# JARVIS — Audit avversariale di hardening pre-collaudo (18 novembre 2026)

**Tipo:** SECOND-PASS SELF-REVIEW, non revisione indipendente di un secondo agente. **Ambito:** solo packaging/compilazione ARMv7, backup REST, inventario ADB. PR #18 Draft. Sorgenti controllati sul branch fino alla versione `629cbc94ff346913d1d2b3be1e9dbde437394ffd`. A ogni successivo HEAD ripetere i gate.

## 1. Prima revisione — modifiche tracciate

- `165a85db`: la CI rifiuta cross-GCC `arm-linux-gnueabihf`/glibc, che prima poteva produrre ELF ARM non compatibile con Android. Richiede **Android NDK Clang ARMv7 API 21**, `ELF32`, `Machine: ARM`, `liblog.so`, e scarta dipendenze glibc. Non ripiega su Android SDK diverso da **android-28**. Senza toolchain reale il job deve fermarsi in NO-GO.
- `940bc451`: corregge l'ordine di link del driver JNI anche nel builder Windows: file sorgente C **prima** di `-llog`, importante con linker `--as-needed`. Il sorgente `uinput_jni.c` usa effettivamente `__android_log_print`.
- `61f6943c`: elimina la generazione del keystore TLS privato, anche temporaneo, dall'APK CI e verifica che il pacchetto non contenga `.p12/.jks/.key` ecc. L'identità TLS dell'app è creata in storage privato da `TlsCertificateManager`, non deve entrare negli assets.
- `5689aee0`, `b48c2db`, `8f2235e`: test Python con casi negativi per bloccare regressioni su toolchain Android, link order, TLS privato, collegati anche al gate host offline.
- `efe95b9d`, `af18c69d`: inventario `-Action preflight` mostra `ro.build.type`, `ro.debuggable`, avvisa se `run-as` nega accesso al DB e specifica **non equivale ad autorizzazione all'installazione**. Test mock aggiornato per verificare le segnalazioni.
- `51e39390`: elimina la richiesta REST di memoria con possibile token Bearer su HTTP/8088; ora solamente HTTPS/8443 con trust standard del sistema. In caso di CA self-signed non fidata, snapshot REST **facoltativo** viene saltato; snapshot SQLite/WAL binario resta obbligatorio e fail-closed. **Nessun TLS bypass.**
- `d9f1cc9c`, `9d47a23`, `338ea794`: test regressione negativi per HTTP e disattivazione certificato, inclusi CI e host offline.
- `629cbc94`: aggiorna handoff owner con **un solo comando read-only** al rientro a casa; nessuna installazione o dati privati richiesti in chat.

## 2. Secondo passaggio — attacchi alla nostra stessa soluzione

**Valutazione dei falsi successi:**
- CI può dichiarare `ARM ABI confirmed` per un ELF Linux/glibc: ora impedito da toolchain e dipendenze controllate; non equivale ancora a prova runtime su AKAI.
- Un certificato di test incluso in CI poteva essere normalizzato come asset obbligatorio, creando divergenza rispetto al builder privato: rimosso.
- Backup REST con Bearer in HTTP poteva trasmettere token in chiaro anche se il server risponde `426 Upgrade Required`: URI HTTPS imposto, senza fallback insecure.
- Inventario `run-as` negato non può significare backup recuperabile o rollback garantito: warning NO-GO esplicito, e ancora richiesta prova owner.
- La presenza testuale di `--debug-mode` non basta: mantenere `test_compiled_build_profiles.py` che controlla i manifest v4 e v5 reali compilati da AAPT2; CI è attualmente indisponibile.

**Controprova sul codice GitHub effettivamente letto dopo commit:** controllati 14 invarianti statici direttamente su file salvati (toolchain, linker, API28, TLS, HTTP, preflight, mock e collegamento alle due suite). **14/14 verifiche di presenza/coerenza statiche positive**; NON chiamarle esecuzione delle suite Python/PowerShell o build APK.

**Ulteriori limiti/possibili miglioramenti (non mascherati):** lo snapshot REST opzionale su HTTPS potrebbe non funzionare se il PC non si fida della Root CA generata dalla TV: comportamento sicuro ma di funzionalità limitata, non va “riparato” con `-SkipCertificateCheck`. In futuro si può fare pinning OOB del certificato via percorso verificato, solo se necessario e dopo revisione separata. La linea di installazione legacy usa ancora `adb install -r -d` per rollback A2 v3, non garantito su app non-debuggable: resta P0. Anche il mock AAPT simula metadati e non dimostra la validità di un APK proprietario autentico. Tutte le prove da svolgere con toolchain/hardware rimangono NOT_RUN.

## 3. Documentazione ufficiale consultata (18/11/2026)

- Android NDK, target compiler `armv7a-linux-androideabi21-clang`: https://developer.android.com/ndk/guides/other_build_systems
- Android NDK, ABI `armeabi-v7a` e percorso APK `lib/<abi>/lib*.so`: https://developer.android.com/ndk/guides/abis
- Android AAPT2, `--debug-mode` e `dump xmltree`: https://developer.android.com/tools/aapt2
- GitHub Docs, troubleshooting runner e billing: https://docs.github.com/en/actions/how-tos/troubleshoot-workflows
- Android Developers, firma necessaria per aggiornamenti in-place: https://developer.android.com/studio/publish/app-signing

## 4. Evidence matrix e verdetto

| Area | Stato | Commento |
|---|---|---|
| Source review su commit reale | PASS per l'ambito limitato | 14 condizioni statiche controllate; nessun secondo reviewer indipendente |
| Suite Python/PowerShell/Node/Java completa | NOT_RUN | runner GitHub non assegnato; host alternativo non eseguito su checkout verificato |
| JNI NDK ARMv7 e packaging Android9 reali | NOT_RUN | nuove regole inserite; da provare con NDK/SDK |
| APK v4 firmato originale | NOT_RUN | keystore privato non disponibile |
| Backup/restauro APK+SQLite/WAL+TLS AKAI | NOT_RUN | richiede proprietario e preflight, downgrade A2 non garantito |
| Test su TV AKAI | NOT_RUN | nessuna installazione autorizzata/eseguita |

**Decisione:** `GO_FOR_HOST_WORK` e `GO_FOR_OWNER_PREFLIGHT_READ_ONLY` dopo autorizzazione. **`NO_GO`** a rilascio APK, installazione, root/reset e claim che la v4 sia pronta. P0: runner/CI non funzionante, firma privata originale, backup/recupero Android reale. P1: UX/visione/DRM/voce/HTTPS da verificare su AKAI. Non spendere crediti o rimuovere requisiti per forzare green.

## 5. Revisione aggiuntiva del 18/11 — bug P0 versionCode v4 e firma incompleta

**Evidenza di partenza:** il manifest sorgente `akai-remote-tv/app/src/main/AndroidManifest.xml` contiene esplicitamente `android:versionCode="3"` e `android:versionName="1.2.0-a2-preview"`. La documentazione **ufficiale** AAPT2 (https://developer.android.com/tools/aapt2, opzioni `--version-code`, `--version-name`, `--replace-version`) dice che i primi due inseriscono i valori **solo quando gli attributi non sono già presenti**, mentre `--replace-version` ne forza la sostituzione. Di conseguenza il builder v4 e il test v5 avrebbero conservato la versione A2 v3, invalidando il normale aggiornamento. Non inferire un override dal solo passaggio degli argomenti a CLI.

**Correzioni applicate:** `scripts/12_build_jarvis_final_candidate.ps1` ora aggiunge `--replace-version` all'array AAPT2 link e `akai-remote-tests/test_compiled_build_profiles.py` lo aggiunge al build reale di **entrambi i profili**. CI e gate host richiedono la presenza della flag. Due test negativi e uno positivo di contratto tra manifest reale/argomenti builder+CI sono stati aggiunti; il file di test è stato **ripristinato e riscritto** dopo che un primo tentativo ne aveva accidentalmente duplicato parte del contenuto (commit correttivo `9e60c933`). Lettura diretta dopo commit: una sola classe ParserNegativeTests, una funzione build_and_check, un entrypoint main e flag presente in tutti e quattro i file. Test della regex in Python locale con fixture sintetica positivo + due regressioni negative; non equivale a esecuzione dell'intera suite salvata su GitHub.

**Hardening firma e provenienza:** al fallimento di apksigner il builder cancella anche l'eventuale file APK parzialmente scritto, anziché lasciare un artefatto che sembri installabile. Un profilo Release non equivale all'approvazione del proprietario: `productionReady=false`, `ownerTvApproved=false`, `recoveryVerified=false` rimangono espliciti. Test sorgente negativi `test_android_jni_ci_contract.py` proteggono da regressioni su queste proprietà.

**Secondo passaggio critico:** la correzione conserva la stessa identità `it.akai.customremote` e il manifest sorgente v3: `--replace-version` altera **soltanto l'APK generato**, senza riscrivere il manifest di riferimento o l'A2 già installato. Il test CI usa AAPT2 reale e fallisce se il dump del candidato non restituisce vCode 4/5. Nessuna garanzia che tutti i componenti funzionino su TV. Il file Python, il builder PowerShell e la CI **non sono stati eseguiti in questa revisione da un checkout integrale con Android SDK28/NDK e runner**. Il blocco GitHub Actions pre-run permane e non va scambiato con un PASS.

**Decisione:** `GO_FOR_HOST_WORK`, `NO_GO` per installazione v4, OTA, merge o dichiarazione “pronto”. Restano P0: CI completa su SHA finale, APK originale firmato con stessa chiave della A2, backup SQLite/WAL/TLS e percorso recupero reale su AKAI. Nessuna operazione di scrittura sulla TV autorizzata da questa revisione.
