# JARVIS finale — consegna per il collaudo del proprietario

**Stato:** procedura di HANDOFF, non autorizzazione all'installazione.  
**Hardware:** AKAI AKTV5037N, Android 9/API28, ARMv7; installato A2 Preview `it.akai.customremote` vCode 3.  
**Sorgente finale:** PR #18, branch `feat/jarvis-final-agent-ota-foundation-20261117`, stacked su PR #16.  
**Obiettivo:** un solo APK finale vCode >=4, dati conservati, possibilità di recupero. Niente update intermedi o OTA automatico.

## 1. Verifiche da completare in GitHub PRIMA di costruire l'APK destinato alla TV

- [ ] HEAD della PR #18 esatto e **tutta** la CI GitHub Actions `completed/success`: Java, SQLite, policy DeepSeek/Kimi, visione, privacy, Web Remote, TTS FreeTTS, JNI ARMv7, APK Android 9, mock rollback.
- [ ] Verificare che PR #16 e tutti i cambiamenti richiesti da PR #18 siano compresi nel checkout finale. Non compilare da un branch o un worktree parziale.
- [ ] Assenza di segreti nel repository; non utilizzare il pacchetto CI `app-ci-test-nondistributable.apk` per aggiornare la TV: è firmato solo per test.
- [ ] Confermare che l'APK originale A2 vCode3 e il suo certificato di firma siano preservati in un backup privato esterno al repository, insieme a procedura di recupero/test dei dati SQLite. Nessun reset e nessun `pm clear`.
- [ ] Conservare anche LTvLauncher come HOME predefinita. La nuova app JARVIS non deve rimuoverlo né sostituirlo implicitamente.

## Nuova decisione owner (18/11/2026): doppio passaggio v4 diagnostic -> v5 finale

Il proprietario desidera **provare JARVIS sulla TV con un APK debuggable** prima di una sola release conclusiva con debug disabilitato.

- **Prima fase, v4 Diagnostic (solo collaudo):** builder `scripts/12_build_jarvis_final_candidate.ps1 -BuildProfile Diagnostic -VersionCode 4 -VersionName '1.3.0-diagnostic-rc1'`. La sorgente `AndroidManifest.xml` rimane `debuggable=false`, ma **AAPT2 `--debug-mode` imposta `android:debuggable=true` nel manifest effettivamente incorporato nell'APK**; il builder controlla il flag tramite `aapt dump xmltree` e rifiuta esiti ambigui. Non firmare con debug.keystore: usare il certificato A2 originale e verificare SHA-256. Output con nome esplicito `jarvis-v4-owner-signed-diagnostic.apk`.
- **Seconda fase, v5 Release dopo test utente:** build `-BuildProfile Release -VersionCode 5 -VersionName '1.3.0-final'`, con `android:debuggable=false` verificato nel manifest compilato; stessa firma. Se la versione installata supera v4 per altri collaudi, assegnare a v5 un versionCode *superiore a quello realmente installato*; non ridurre versionCode.
- Un APK debuggable può consentire `run-as` e il debugger Android, ma **non prova la possibilità di effettuare downgrade alla vecchia A2 v3 non debuggable**, né bypassa le restrizioni su dati e firma Android. La strategia di backup/recupero va verificata a parte. La fase v4 deve rimanere su rete domestica fidata con ADB autorizzato solo dal proprietario e non deve essere distribuita.
- Entrambi i profili compilano senza eseguire ADB, installazioni o accesso a chiavi remote. Il debug è consentito *solo* al profilo Diagnostic; il profilo Release rifiuta vCode inferiore a 5 e qualsiasi output debuggable.
- **Non autorizzare ancora l'installazione v4** fino a chiusura del gate `Test-PackageUpgradeGate` e dei test con metadati APK reali, controllo della disponibilità della firma originale e backup APK/SQLite/TLS verificato. Vedi `docs/JARVIS_FINAL_PREINSTALL_AUDIT_20261118.md`.
- La PR #18 rimane Draft e il team non modifica la TV: il proprietario farà installazione e test dopo esplicita autorizzazione per la singola operazione.

## 2. Creazione APK finale sul PC dell'owner — compilazione SENZA installazione

Il builder **non** modifica la TV e rifiuta una firma diversa da quella attesa dell'APK installato. Richiede inoltre `-ExpectedCiHeadSha`: il commit completo (40 caratteri) della **stessa HEAD** con CI GitHub Actions `completed/success`, controllata manualmente dall’owner. Se nel frattempo il branch avanza o il checkout non corrisponde, la compilazione viene bloccata. Il confronto locale dello SHA non certifica da solo lo stato della CI. Va usata **la stessa chiave di firma originaria**, conservata privatamente fuori dal repository, non un nuovo debug keystore.

Prerequisiti: Git pulito sul branch finale, JDK 17, Android SDK 28, Build Tools 28.0.3, NDK per ARMv7 (oppure fallback JNI verificato come nello script), firma originale e alias. Le password devono essere disponibili solo in variabili d'ambiente private `JARVIS_SIGNING_STOREPASS` e `JARVIS_SIGNING_KEYPASS`, **mai** in chat, repo o log.

Esempio di avvio dopo che le credenziali private sono state predisposte in modo sicuro:

```powershell
git checkout feat/jarvis-final-agent-ota-foundation-20261117
git pull --ff-only
.\scripts\12_build_jarvis_final_candidate.ps1 `
  -ExpectedCiHeadSha "<SHA_COMPLETO_40_CARATTERI_DELLA_CI_PASS>" `
  -BuildProfile Diagnostic `
  -VersionCode 4 `
  -VersionName "1.3.0-diagnostic-rc1" `
  -SigningKeystorePath "C:\PercorsoPrivato\firma-originale.jks" `
  -SigningAlias "alias-originale"
```

L'output Diagnostic v4 è nella cartella privata `%LOCALAPPDATA%\AkaiJarvisBuilds\FINAL-v4-*\outputs\apk\release\jarvis-v4-owner-signed-diagnostic.apk` (la successiva Release v5 genera `app-release.apk`), con `JARVIS_FINAL_BUILD_MANIFEST.json` (Git SHA, SHA-256, certificato SHA-256, versione e `installed=false`); **non** nel repository. La compilazione verifica in modo fail-closed impronta firmatario attesa, SHA-256, nome pacchetto `it.akai.customremote`, vCode >3, minSdk 21, targetSdk 28, risorse, flag `android:debuggable` del manifest compilato coerente con il profilo (`true` per Diagnostic v4, `false` per Release v5+), componenti ARMv7 e assenza di certificati TLS privati nell'APK. Non generare o distribuire alcun APK che fallisce uno dei gate.

**Limite:** né GitHub né questa procedura possiedono la chiave di firma dell'owner. Se manca la chiave originale, il rilascio come aggiornamento in-place è BLOCCATO; non creare una nuova firma e non disinstallare A2 per aggirare l'errore.

## 3. Preparazione backup e consenso sul televisore (solo quando il proprietario decide di procedere)

- [ ] Backup originale A2 e dati verificati su un supporto privato. Mai cancellare SQLite. Accertarsi che il backup sia leggibile e recuperabile.
- [ ] Confermare indirizzo LAN, certificato HTTPS Web Remote e accessibilità; prendere nota dello stato prima dell'aggiornamento. Nessuna modifica a Home LTvLauncher.
- [ ] Usare HTTPS e fingerprint Root CA confermato fuori banda per pairing e credenziali. Il codice mantiene endpoint legacy PIN/comandi su HTTP 8088 per compatibilità: la LAN privata da sola **non cifra** questi dati. Non utilizzare le rotte legacy HTTP quando è richiesto un pairing riservato; nessun inoltro porte WAN.
- [ ] Verificare stessa firma APK, versione superiore e spazio eMMC libero. Se la firma non coincide, STOP.
- [ ] Autorizzazione **esplicita e visibile** all'installazione di questo singolo APK. Non eseguire installazioni automatiche o da automazioni.
- [ ] **Gate recupero reale (BLOCCANTE):** lo script storico `akai-remote-tests/05_safe_install_and_rollback.ps1` usa `adb install -r -d` per tornare alla versione precedente. Android documenta `-d` come consentito per app debuggable; su build Android `userdebug` può esserci eccezione, ma va verificata sulla AKAI e non può essere inferita dalla CI mock. Prima di installare acquisire *solo in lettura e con autorizzazione owner* `adb shell getprop ro.debuggable`, `adb shell getprop ro.build.type` e stato del pacchetto, più hash dell'APK A2 originale. Se non è dimostrata una strada di recupero conservativa per APK+SQLite+TLS, **NO-GO**: niente install, niente disinstallazione, niente `pm clear`. L'alternativa è un APK di ripristino A2 firmato con la stessa chiave e `versionCode` maggiore del candidato (da costruire e validare separatamente), non un downgrade dato per certo.
- [ ] In caso di regressione, interrompere il test e applicare soltanto una procedura di recupero già dimostrata e approvata. Lo script non rende il rollback atomico per magia: la simulazione non prova Android9 OEM, permessi `run-as/su/root`, né la disponibilità delle chiavi/private backup.

## 4. Test sul televisore affidati al proprietario

| Test | Risultato atteso | Esito |
| --- | --- | --- |
| Avvio + riavvio | TV e LTvLauncher funzionano come prima, telecomando fisico normale | DA TESTARE |
| Web Remote iPhone/Android | Connessione HTTPS sulla LAN, abbinamento PIN, comandi Home/Back/D-pad/volume | DA TESTARE |
| App TV | Aprire YouTube e tornare alla Home senza errori Web generici | DA TESTARE |
| Task Italia 2 | Aprire Infinity, navigare verso la diretta **e verificare la riproduzione reale** | DA TESTARE |
| Visione | Consenso cloud separato, prompt Android MediaProjection, screenshot freschi entro limiti e stop sicuro | DA TESTARE |
| DRM | Schermata nera/protetta non causa successo inventato, né upload illimitato | DA TESTARE |
| STOP concorrente | Annullare durante richiesta cloud/cattura/TTS; nessuna azione successiva tardiva | DA TESTARE |
| SQLite | Procedure già salvate presenti, nessuna perdita di memoria, nessun apprendimento da falso successo | DA TESTARE |
| DeepSeek/Kimi | Solo provider approvati, chiave cifrata, consenso e budget corretti | DA TESTARE |
| Voce eSpeak | Risposta italiana da altoparlanti TV; cancellazione rapida senza blocchi audio | DA TESTARE |
| Voce FreeTTS personale | Solo con consenso e chiave di account gratuito personale; audio sulla TV, soglia 5.000 caratteri/mese e fallback eSpeak | DA TESTARE |
| Stabilità | Nessun rallentamento grave, perdita della Home, blocco del telecomando o consumo anomalo RAM | DA TESTARE |

I test cloud e TTS possono consumare le quote personali dei provider: non attivarli prima della scelta dell'owner. Le risposte FreeTTS passano da un servizio di sintesi esterno; l'account gratuito è personale/non commerciale, con possibile watermark. In caso di assenza chiave, nessun tentativo di creare un account automaticamente.

## 5. Evidenze necessarie per dichiarare GO reale

Annotare: HEAD SHA, run CI `completed/success`, SHA-256 APK finale, signer SHA-256, nome pacchetto/versionCode, screenshot della schermata informativa TV, log sanitizzati dei test con errori, conferma funzionalità HOME/Web/voice/vision, conferma del piano di ripristino e decisione finale owner.

Mai incollare API key, token di pairing, credenziali FreeTTS, certificati privati, copie del database personale o audio privato nei commenti pubblici.

**Stato attuale:** firmware TV invariato; il codice e i mock non dimostrano ancora il funzionamento reale. Il proprietario effettuerà i test; ChatGPT/automazione deve arrivare al handoff con codice finale, CI e build firmabile, senza anticipare risultati dei test.
