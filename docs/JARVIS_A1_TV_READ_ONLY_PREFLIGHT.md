# JARVIS A1 — Preflight sulla AKAI reale (solo lettura)

## Risultato reale del proprietario — 16/11/2026

**TV fisica inventariata con successo; nessun file TV modificato.** PowerShell `05_safe_install_and_rollback.ps1 -Action preflight -TargetTv 192.168.1.108` ha riportato:

- `it.akai.customremote` INSTALLATO e attivo, `versionCode=1`, `versionName=1.0.0`.
- Certificato **di firma APK installato**: `21C2C41DC4C34576CCA14AD5404E87D1C5A07ACE961C0FAB96D128C2164A51ED` (SHA-256).
- Sul PC del laboratorio, `keytool -list -v -keystore .\\tools\\debug.keystore -storepass android` ha restituito **lo stesso fingerprint SHA-256**. Quindi il materiale di firma locale **sembra compatibile** con l'app già installata, **ma non è stato ancora compilato/firmato/verificato un nuovo candidato**.
- Home v8 presente, HTTP 8088 e HTTPS 8443 in ascolto, dispositivo `SmartTV m7332`, Android 9, circa 3.0 GB liberi su `/data`.
- `run-as` per la app release **non accessibile**; ADB shell uid 2000, `su` non attivo; SELinux riportato `Permissive`. **Non è stata dimostrata la possibilità di effettuare un backup consistente del DB privato e dell'identità TLS.**
- L'indirizzo IP effettivamente raggiungibile al momento del preflight era `192.168.1.108`, non il vecchio `192.168.1.8`. Confermare prenotazione router separatamente; il DHCP visualizzato in TV è compatibile anche con prenotazione DHCP.

**Decisione attuale:** firma locale identificata, ma **NO-GO per installazione** finché backup DB+identità HTTPS e rollback non sono verificati sul dispositivo reale. Non dare istruzioni di `-Action backup` come operazione soltanto di lettura: il ramo `backup` dello script arresta l'app temporaneamente (`am force-stop`), prova avvio service e può tentare `adb root`; richiede piano/consenso operativo distinti. Non eseguire nessuna di queste azioni per un semplice preflight.

**Prossimo passo privo di modifiche alla TV:** fare una copia privata di `tools/debug.keystore` (fuori repository e cartella Git), controllare integrità con `Get-FileHash SHA256`, conservare il file e la password in modo riservato; non inviare/pubblicare la keystore. Lo SHA-256 del **file keystore** non è lo SHA-256 del **certificato APK**: è soltanto per verificare che la copia sia identica.



**Scopo:** conoscere modello, APK attualmente installato, versione, SHA-256 del **certificato di firma dell'APK**, Home e porte prima di prendere una decisione sul nuovo rilascio. Questa pagina **non autorizza** installazione o reset.

**Stato verificato via GitHub:** PR #8 (stacked su #7/#1) CI Android e Cloud Developer **completed/success** al commit `ea157be8e07549717841c3c9e74382add79cbc90` — run Android `43841215166`, run Python `43841215086`. Sono test host/CI, non prove dirette sulla TV.

## 1. Dal PC del laboratorio — PowerShell 5.1

Aprire PowerShell nella **radice della propria copia** del repository, per esempio:

```powershell
Set-Location "C:\Users\danie\OneDrive\Documenti\Antygravity\Akay"
Test-Path .\akai-remote-tests\05_safe_install_and_rollback.ps1
Test-Path .\tools\android-sdk\platform-tools\adb.exe
```

Entrambi devono restituire `True`. Se la radice locale è diversa, adattare soltanto il primo percorso; **non** spostare file sull'AKAI. Se manca lo script, recuperarlo dal branch GitHub `feat/jarvis-a1-integration-candidate` dopo aver controllato `git status --short` e senza cancellare modifiche locali.

```powershell
$env:ADB_EXECUTABLE = (Resolve-Path ".\tools\android-sdk\platform-tools\adb.exe").Path
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\akai-remote-tests\05_safe_install_and_rollback.ps1" -Action preflight -TargetTv 192.168.1.8
```

Questo esegue soltanto il blocco `preflight`: `adb connect`, `pm list`, `pm path`, `pidof`, `dumpsys package`, `adb pull` di copia temporanea dell'APK (cancellata dallo script), `apksigner` per firma, `run-as ... ls`, `df`, `getprop`, `id`, `getenforce`, ispezione permessi `/dev/uinput` e `netstat`. Non esegue `adb install`, `am force-stop`, `pm clear`, `uninstall` o modifiche di Home/TLS.

Il digest **firma SHA-256** dell'APK installato deve essere di 64 cifre esadecimali; può risultare `INACCESSIBILE` se `adb pull` o `apksigner` sono negati/non disponibili. Non convertire una mancata verifica in approvazione.

## 2. Cosa riportare a ChatGPT / revisione

Riportare soltanto questi risultati:
- `Stato pacchetto`, `versionCode`, `versionName`, `Firma SHA-256`.
- `Home v8`, `Accesso run-as`, `Spazio /data`, porte 8088/8443 e eventuali errori.

**Non condividere** PIN di pairing, segreti API, keystore privati o database SQLite personali. Non confondere impronta del certificato *APK* con impronta Root CA *HTTPS* (sono due chiavi completamente diverse).

## 3. Condizioni di stop

- **Non installare** `build_ci/app-ci-test-nondistributable.apk`: è firmato con una chiave test casuale generata dalla CI. La CI non produce né pubblica un artefatto di release installabile.
- **Attenzione anche a `scripts/08_compile_akai_remote_apk.ps1`:** il file chiamato `app-release.apk` viene firmato con `tools/debug.keystore` e password di sviluppo `android` nello script attuale. Il nome `release` e il flag `non-debuggable` **non attestano la corrispondenza di firma** con l'APK installato. Non avviare una nuova compilazione/aggiornamento prima di aver confrontato le impronte; lo script cancella inoltre la cartella locale `akai-remote-tv/app/build` quando riparte. Non cancellare o rigenerare `tools/debug.keystore` esistente: potrebbe essere proprio la chiave di firma usata per la beta.
- **Non eseguire** `-Action install`, `rollback`, `backup`, `-AllowHardwareExecution` o `-GreenfieldStart` finché il proprietario non autorizza un piano di aggiornamento distinto e la firma del candidato non è stata confrontata con la firma già installata.
- Per un aggiornamento **in-place** conservativo servono: firma del medesimo signer APK di produzione, versione compatibile, controllo DB/CA non distruttivo, possibilità di rollback sicuro. Se non si dispone della chiave del vecchio APK, **stop**: niente disinstallazione o reset per aggirare mismatch.
- Il software installato è funzionante secondo il proprietario; non cambiare Home v8, configurazione Safari, certificati, porte 8088/8443 o servizi per il solo preflight.

## 4. Verifiche già automatizzate nel repository

`AKAI JARVIS CI` esegue Java host, SQLite reale host, JNI ARMv7, build Android 9, ispezione APK e PowerShell mock-ADB/rollback. `JARVIS Cloud Developer — Safe CI` verifica il worker Python, il blocco di chiamate senza approvazione e i limiti ai file modificabili. **Non sostituiscono** il preflight e i test Android reali.

**Decisione successiva:** se firma TV verificata, individuare la keystore di rilascio già usata **sul PC privato** senza copiarla nel repo, firmare un candidato in un ambiente controllato, confrontare digest e proporre un collaudo solo dopo autorizzazione. Se firma TV non disponibile, mantenere la beta attuale senza modifiche.
