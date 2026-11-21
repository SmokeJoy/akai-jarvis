# JARVIS — secondo passaggio critico sui profili APK v4/v5 (18/11/2026)

**Decisione:** `GO_FOR_HOST_WORK` soltanto. `NO_GO` a installazione/OTA/merge e alla dicitura "APK v4 pronto". Review eseguita sul codice GitHub PR #18 aggiornato sino al commit `dc80be616475dd2fcbbdaf2bd2d5ee9a4253fd23`, con rilettura post-write. A ogni ulteriore modifica della HEAD, ricontrollare il contenuto.

## Passaggio A — modifica reale e correttezza

- `akai-remote-tests/test_compiled_build_profiles.py` (`6742b37`) contiene 5 test negativi/parsing e invoca lo strumento Android **AAPT2 reale** due volte, per creare APK **solo risorse, non firmati** con la stessa sorgente del manifest: Diagnostic vCode4 `--debug-mode` e Release vCode5 senza `--debug-mode`. Successivamente legge `aapt2 dump xmltree` del **manifest compilato** e `dump badging` e verifica booleano, package, versionCode, versionName, minSdk 21, targetSdk 28. Niente credenziali, firma o contatto TV.
- `.github/workflows/ci.yml` (`f4e854b`) collega il test **dopo** compilazione risorse Android9 ARMv7, prima della dichiarazione di build CI verificata. Richiede esplicitamente `platforms/android-28/android.jar`, non considera equivalente una SDK più recente. Lo step deve fallire in caso di parametro/file/metadato mancante.
- `scripts/12_build_jarvis_final_candidate.ps1` (`54280e8`) rifiuta una Release v5+ con `VersionName` rimasto `diagnostic` o `debug` e un Diagnostic v4 senza etichetta `diagnostic`. Evita il falso "APK finale" con nome predefinito del test.
- Ulteriori contratti di sorgente aggiunti a `scripts/13_jarvis_offline_host_gate.py` (`7138c37`) e al job CI PowerShell `1c` (`dc80be6`). Restano attivi controlli della firma proprietaria, chiave fuori dal repository e versione corrente maggiore, senza deploy.

## Passaggio B — ricerca attiva di difetti, regressioni e alternativa migliore

**Difetto individuato:** la CI preesistente generava un APK vCode3 A2 con firma effimera e verificava la presenza testuale di `--debug-mode` nel builder; non esercitava i due manifest effettivi Diagnostic/Release. Il nuovo test copre il comportamento binario di AAPT2 e blocca errori che la verifica del solo sorgente non poteva trovare.

**Difetto ulteriore:** il builder, usando `-BuildProfile Release -VersionCode 5` senza `-VersionName`, avrebbe accettato il nome predefinito `1.3.0-diagnostic-rc1`. La protezione aggiunta lo rifiuta e obbliga a scegliere un nome finale.

**Alternativa esaminata:** cambiare il manifest sorgente a true e ripristinarlo a false dopo i test è più semplice solo in apparenza, perché può lasciare il debug attivo accidentalmente nel branch di produzione. Conservare manifest sorgente false + iniezione AAPT2 esplicita + verifica del pacchetto compilato limita questo rischio senza introdurre modelli, APK nuovi installati o dipendenze a runtime.

**Evidenza host locale effettivamente eseguita:** su una copia locale ricostruita del test Python, `python -m py_compile` PASS; `python ... --self-test-only` PASS (5 test, comprendenti duplicazioni, valori invalidi, metadati divergenti). Eseguito mock di comando AAPT2 in shell locale: percorso positivo Diagnostic/Release PASS, poi inversione forzata dell'attributo causa exit 1 come richiesto. **La copia locale non è stata validata byte-per-byte contro il blob GitHub; questi non sono test dell'APK Android reale né della CI GitHub.** Test reali AAPT2 compilati restano `NOT_RUN` fino al ripristino runner/ambiente Android SDK 28 completo.

**Seconda revisione sulle limitazioni:** nessuna firma APK proprietaria usata, nessun build Windows PowerShell eseguito, nessun test `adb run-as` o di downgrade Android9, nessuna prova del vecchio A2 backup vCode3. Non chiamare la copia del test con mock "CI Android PASS".

## Consultazione documentazione ufficiale

- Android Developers, AAPT2 Link `--debug-mode`: https://developer.android.com/tools/aapt2 — documenta l'inserimento di `android:debuggable="true"` nel manifest compilato. Consultato 18/11/2026.
- Android Developers, AAPT2 Dump `xmltree`, `badging` e `--file`: https://developer.android.com/tools/aapt2 — verifica del pacchetto compilato, consultato 18/11/2026.
- GitHub Docs, runner privati e quote: https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job — i runner standard dei repository privati consumano quote Actions; **non dimostra** che questo account sia senza credito. Consultato 18/11/2026.

## Matrice attuale e blocchi residui

| Gate | Esito | Evidenza |
| --- | --- | --- |
| Revisione di codice sul repository GitHub | PASS (ambito profili v4/v5) | commit e file sopra |
| Unit test Python e mock CLI locali | PASS **parziale** | 5 test + positivo/negativo mock; copia ricostruita |
| Compilazione reale AAPT2 v4 e v5 | NOT_RUN | aggiunta CI 6b; runner non parte |
| CI integrale esatta HEAD | BLOCKED | GitHub Actions run `completed/failure` con `steps=[]`, nessun runner assegnato; vedere `docs/JARVIS_CI_RUNNER_BLOCKER_20261118.md` |
| Build owner-signed APK v4 | NOT_RUN | keystore originale non disponibile nell'ambiente di test |
| Backup/rollback APK/SQLite/WAL/TLS fisico | NOT_RUN | richiede preflight owner su AKAI |
| Test reale TV | NOT_RUN | nessun APK installato |

**Rischi residui:** P0 runner CI e test AAPT2 reali non eseguiti; P0 firma originale e conservazione/recupero dati reali non dimostrati; P1 Web HTTPS e comportamento DRM/OEM ancora da collaudare. PR #18 resta Draft. Non consentire TV install finché i gate owner non siano soddisfatti.

La revisione non garantisce assenza assoluta di bug; distingue soltanto ciò che è provato da ciò che rimane da verificare.
