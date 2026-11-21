# JARVIS v4 — Revisione tecnica critica, 19 novembre 2026

**Stato release: NO_GO.** Il proprietario vuole TUTTE le funzioni nella v4; la v5 disabilita soltanto il debug e cambia i metadati/versionCode obbligatori. Il progetto resta nella PR #18 Draft: nessuna installazione, nessun merge/release e nessuna operazione sulla AKAI sono autorizzati da questa revisione.

## Ambito effettivo della verifica

Lettura diretta dell'HEAD della PR #18, esiti Actions, contratto AGENTS.md, file OTA più critici, script builder e memoria SQLite. La PR modifica circa 92 file: **non** significa che ogni singola linea sia stata verificata indipendentemente o collaudata sull'Android reale. Esiste una sola revisione tecnica assistita di più passaggi; la revisione **indipendente** richiesta dal progetto è ancora NOT_RUN. Non sostituire la CI con prove hardware.

## Difetti concreti trovati e correzioni pubblicate

1. **P0 — Manifesto OTA firmabile sulla base di un JSON non attendibile.** Lo script `scripts/14_sign_ota_release_manifest.mjs` si fidava di `signedWithOwnerOriginalCert:true`, `debuggable:false` e versione presenti in un handoff modificabile. Correzione: `scripts/lib/ota_release_apk_proof.mjs` usa gli strumenti Android ufficiali sul **vero APK**, verifica firma v2, esattamente un certificato owner atteso, package, versione/name, Android9/ARMv7 e manifest non-debug; rifiuta tools mancanti e voci false. Unit test avversariali `akai-remote-tests/test_ota_release_apk_proof.mjs`. La prima CI ha individuato un errore **del fixture di test**, poi corretto: il test alterava il resource ID anziché il boolean `debuggable`. Le prove su un vero APK owner-signed Windows sono ancora NOT_RUN.
2. **P1 — Impossibile provare l'OTA della v4 prima della v5.** Un'OTA su v4 installata vCode4 richiede APK di **staging diagnostico più recente**, non la v5 production prima dell'approvazione. Builder `scripts/12_build_jarvis_final_candidate.ps1`: aggiunto `-OtaStagingTest` esplicito con vCode 5..99, profilo ancora Diagnostic e nome APK che indica test, senza installazioni automatiche. Il tool stabile di firma `scripts/14_...` **non** accetta diagnostiche. Manca il test E2E OTA su canale staging isolato e autorizzato, inclusa firma del manifesto staging: **V4-2 INCOMPLETE**. La successiva v5 deve avere vCode maggiore di **tutti** quelli installati.
3. **P1 — Copia SQLite potenzialmente troncata e recupero fragile.** `AkaiMemoryEngine.copyFile` usava un solo `FileChannel.transferTo`, che non garantisce il trasferimento completo. Ora `VerifiedAtomicFileCopy` effettua copia su file temporaneo, fsync, verifica SHA256/byte-count e sostituzione atomica oppure fallimento senza fallback rischioso; test sul filesystem reale `VerifiedAtomicFileCopyTest`. Il metodo di ripristino richiede ora prima uno snapshot consistente del DB originale verificato con `PRAGMA integrity_check`. **Non è provata la recuperabilità completa Android9/WAL/TLS dopo un problema o durante crash/power-loss.** Un backup file non equivale a una prova di restore.
4. **P1 — Source drift fra v4 e v5.** `scripts/14_sign_ota_release_manifest.mjs` ora richiede `--approved-v4-source-sha`, uguale al `sourceCommit` della build candidata v5. Permette soltanto stessa base funzionale approvata e build profile release; nessuna modifica applicativa nascosta. La corrispondenza da sola **non prova** che la v4 sia stata collaudata: il valore deve provenire da evidenza di approvazione owner indipendente.

## Elementi precedenti ispezionati (non dichiarati hardware-PASS)

- `OtaSignedReleaseManifest`: firma RSA su bytes esatti, parser canonico, checksum e HTTPS allowlist.
- `OtaHttpsTransport` e `OtaStagingCommit`: download limitato e staging immutabile, con recupero file precedenti e test negativi host.
- `OtaAndroidArchiveInspector` e `OtaAndroidInstallPreflight`: certificato/codice versione reali da Android, APK riletto e SHA256.
- `OtaOwnerPackageInstaller`: codice di sessione e callback OS presente, con verifica dei bytes nel `PackageInstaller.Session`; **non è chiamato da MainActivity**, intenzionalmente, perché mancano consenso con prove recovery verificate. L'azione D-pad attuale può soltanto controllare/stagiare quando il canale pubblico è provisionato.
- `AkaiAiController`, `VisionSessionCoordinator`, `VisualStepPolicy`, `GoalEvidenceVerifier`: sono presenti controllo stepwise, cloud DeepSeek/Kimi, consenso visuale e protezioni contro false verifiche; non si deduce supporto a tutte le app o contenuti DRM.
- `RestApiRouter`, `RemoteServerService`: l'app conserva LAN Web Remote/HTTPS e endpoint protetti, ma non esiste prova Safari/riavvio/antenna su device per questa HEAD.

## Gate critici ANCORA APERTI

| Gate | Risultato |
|---|---|
| CI completed/success sull'HEAD attuale | **Da verificare dopo l'ultimo commit**, senza confondere CI su SHA vecchi |
| Revisione tecnica indipendente (secondo revisore) | NOT_RUN |
| Build v4 diagnostica con certificato Android originale sul PC owner | BLOCKED: chiave private owner non accessibile qui |
| Provisioning offline chiave PUBBLICA OTA e endpoint HTTPS reale a PC spento | BLOCKED: necessita owner PC/infrastruttura e collaudo |
| Canale staging per test OTA v4 diagnostica e release > installed | INCOMPLETE |
| Pulsante TV per conferma installazione Android, con evidenza recupero realmente verificata | INCOMPLETE |
| Backup/ripristino effettivo di APK + SQLite/WAL + TLS/certificato/pairing | NOT_RUN su AKAI; nessun downgrade Android implicito |
| Navigazione multipasso reale con obiettivi STATE_VERIFIED in app differenti | NOT_RUN |
| Misure RAM/PSS/CPU/load, ANR, latenza, tuner, HDMI, Home, Safari e riavvio sulla AKAI | NOT_RUN |
| Solo dopo V4_COMPLETE_ACCEPTED: v5 stessa sorgente e debug=false | BLOCCATO fino all'accettazione v4 |

## Regole operative

1. Implementare soltanto cambiamenti difendibili con codice e casi di test; evitare falsi progressi via documentazione o commit no-op.
2. Non trasferire chiavi private di firma APK/OTA, DB, credenziali, materiali TLS o screenshot personali al repository **pubblico**.
3. Non accettare valori booleani di backup/restore dichiarati senza prove. Nessun deploy/ADB write/merge/reset/installazione senza un nuovo consenso proprietario, separato.
4. `V4_COMPLETE_ACCEPTED` richiede tutti i gate hardware e il consenso dell'owner, non la sola Actions CI verde.
