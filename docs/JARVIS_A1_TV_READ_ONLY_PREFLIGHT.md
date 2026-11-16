# JARVIS A1 — Preflight sulla AKAI reale (solo lettura)

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
- **Non eseguire** `-Action install`, `rollback`, `backup`, `-AllowHardwareExecution` o `-GreenfieldStart` finché il proprietario non autorizza un piano di aggiornamento distinto e la firma del candidato non è stata confrontata con la firma già installata.
- Per un aggiornamento **in-place** conservativo servono: firma del medesimo signer APK di produzione, versione compatibile, controllo DB/CA non distruttivo, possibilità di rollback sicuro. Se non si dispone della chiave del vecchio APK, **stop**: niente disinstallazione o reset per aggirare mismatch.
- Il software installato è funzionante secondo il proprietario; non cambiare Home v8, configurazione Safari, certificati, porte 8088/8443 o servizi per il solo preflight.

## 4. Verifiche già automatizzate nel repository

`AKAI JARVIS CI` esegue Java host, SQLite reale host, JNI ARMv7, build Android 9, ispezione APK e PowerShell mock-ADB/rollback. `JARVIS Cloud Developer — Safe CI` verifica il worker Python, il blocco di chiamate senza approvazione e i limiti ai file modificabili. **Non sostituiscono** il preflight e i test Android reali.

**Decisione successiva:** se firma TV verificata, individuare la keystore di rilascio già usata **sul PC privato** senza copiarla nel repo, firmare un candidato in un ambiente controllato, confrontare digest e proporre un collaudo solo dopo autorizzazione. Se firma TV non disponibile, mantenere la beta attuale senza modifiche.
