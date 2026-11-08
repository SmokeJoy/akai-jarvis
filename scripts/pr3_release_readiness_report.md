# AKAI Custom Home v8 Leanback — Release-Readiness & Safe Operational Plan (PR #3)

**Data**: 08 Novembre 2026  
**PR Riferimento**: [#3 — AKAI Custom Home v8 Leanback UI](https://github.com/SmokeJoy/akai-jarvis/pull/3) (ramo `feature/launcher-ui-v8-leanback`)  
**Stato Revisione**: Riscontro completo ai **4 rilievi P1 della Review 11** (`#issuecomment-6721919170`)  
**Stato Codice Java/UI**: **FROZEN** al codice verificato su emulatore (`e193008` — nessuna modifica a `MainActivity.java`, XML UI o test Java). Aggiornati esclusivamente lo script di packaging ([`scripts/09_compile_akai_home_apk.ps1`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/scripts/09_compile_akai_home_apk.ps1)) e la pipeline CI ([`.github/workflows/ci-launcher.yml`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/.github/workflows/ci-launcher.yml)) per tracciabilità versione (`versionCode=9`, `8.1.0`), distinzione firma debug/release e verifica statica build parallela.  
**Stato Hardware TV (`192.168.1.8`)**: 🔒 **HARDWARE FREEZE ASSOLUTO** — zero comandi ADB, nessuna installazione/disinstallazione, nessun deploy autorizzato, nessun merge su `main`. [PR #1](https://github.com/SmokeJoy/akai-jarvis/pull/1) e [PR #2](https://github.com/SmokeJoy/akai-jarvis/pull/2) restano rigorosamente separate e aperte.

### Distinzione Esplicita delle Fonti di Verifica
| Ambito | Evidenza Verificata Indipendentemente | Limite / Stato Attuale |
| :--- | :--- | :--- |
| **CI GitHub Actions (`ubuntu-latest`)** | Compilazione Android **API 28**, `113/113` test unitari Java mockati, `7/7` scenari isolamento ADB fail-closed, verifica build parallela (`it.akai.customhome.v8`, `versionCode=9`, senza `CATEGORY_HOME`, 0 provider) | **Non è un collaudo sulla TV reale**; firma CI effimera (`/tmp/ci_launcher.keystore`), **non distribuibile** |
| **Toolchain Locale Offline** | `apksigner verify --print-certs`, `keytool`, `aapt`/`aapt2` su `tools/debug.keystore` e build `v8` (`vc=9`), scan statico sorgenti Java/XML, `113/113` + `7/7` | Verifiche su build locali (`debug` e test keystore effimera release), **non leggono la TV fisica** |
| **Hardware TV AKAI (`192.168.1.8`)** | Unico backup salvato risalente al `05/11/2026` (`backups/audit_20261105_225521/`, anteriore a `v7`) | 🔒 **Gate aperti (non letti)**: firma reale e `versionCode` della `v7` residente, resolver `HOME` attuale, presenza menu `App Home` OEM, consumo RAM runtime |

> **Nota metodologica (Review 10)**: il precedente collaudo su emulatore Android TV API 28 dimostra che `KEYCODE_HOME` riporta la finestra a `it.akai.customhome/.MainActivity` con focus attivo sul launcher (`btn_src_dtv`), non il ripristino garantito dell'identico ID card focalizzato prima dell'uscita. Gli 8 pacchetti `test.tv.*` sono stub di laboratorio assenti sulla TV reale.

---

## 1. Versionamento, Artefatti Distribuibili e Gestione Firma (P1 #4)

Poiché la baseline `v7` (`ea2f35e`) compilava già con `--version-code 8 --version-name "8.0.0"`, il versionamento candidato è stato incrementato a **`versionCode=9`** / **`versionName="8.1.0"`** sia in [`scripts/09_compile_akai_home_apk.ps1`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/scripts/09_compile_akai_home_apk.ps1) sia in [`.github/workflows/ci-launcher.yml`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/.github/workflows/ci-launcher.yml).

Le build non vengono più confuse sotto un unico nome `debug`:

| Tipo Artefatto | Package / Versione | Chiave / Certificato | Uso Ammesso & Stato |
| :--- | :--- | :--- | :--- |
| **`akai-custom-home-*-ci-test-nondistributable.apk`** (GitHub Actions) | `it.akai.customhome` / `it.akai.customhome.v8` (`vc=9`, `8.1.0`) | `/tmp/ci_launcher.keystore` effimera CI | Solo verifica compile/manifest/test in CI — **NON distribuibile / MAI su TV** |
| **`akai-custom-home-vc9-debug*.apk`** (`-SigningMode debug`, default script 09) | `it.akai.customhome` o `it.akai.customhome.v8` (`vc=9`, `8.1.0`) | `tools/debug.keystore` (`06/11/2026`, `CN=Android Debug`, SHA-256 `21c2c41d...164a51ed`) | **Solo sviluppo / emulatore locale**, **NON trattata come release definitiva**. Ammissibile su TV *esclusivamente* in Opzione B temporanea se l'audit read-only provasse identità SHA-256 con la `v7` residente e il proprietario lo autorizzasse |
| **`akai-custom-home-vc9-release-parallel[-nohome].apk`** (`-SigningMode release -PackageId it.akai.customhome.v8`) | `it.akai.customhome.v8` (`vc=9`, `8.1.0`) | Keystore **release dedicata** esterna al repo git (`-KeystorePath` fuori repo; script 09 **blocca** `debug.keystore` in mode `release`) | **Candidata tracciabile consigliata per Opzione A** (collaudo parallelo su TV indipendente dalla firma `v7`) |
| **`akai-custom-home-vc9-release.apk`** (`-SigningMode release -PackageId it.akai.customhome`) | `it.akai.customhome` (`vc=9`, `8.1.0`) | Keystore **release dedicata** esterna al repo git | **Eventuale release definitiva**: installabile in-place *solo* con firma identica all'app già presente; se diversa dalla `v7`, richiede disinstallazione esplicita di `v7` (perdendo preferenze locali) |

**Comandi offline tracciabili di generazione candidata (senza alcun segreto in git)**:
```powershell
# 1. Generazione keystore release dedicata FUORI dal repo git (eseguire una sola volta dal proprietario)
& tools\jdk-17\bin\keytool.exe -genkeypair -v -keystore "$env:USERPROFILE\.akai-keys\akai_home_release.jks" `
  -alias akai_home_release -keyalg RSA -keysize 2048 -validity 3650 `
  -dname "CN=AKAI Custom Home Release, O=AKAI Custom, C=IT"

# 2A. Candidata Opzione A (parallela isolata per test via am start, senza alterare resolver HOME)
powershell -ExecutionPolicy Bypass -File scripts\09_compile_akai_home_apk.ps1 `
  -PackageId "it.akai.customhome.v8" -VersionCode 9 -VersionName "8.1.0" `
  -SigningMode release -KeystorePath "$env:USERPROFILE\.akai-keys\akai_home_release.jks" `
  -KeyAlias "akai_home_release" -ExcludeHomeIntent -AppLabel "AKAI Home v8 Preview"

# 2B. Candidata standard v8 (eventuale sostituzione/test HOME completo post-validazione)
powershell -ExecutionPolicy Bypass -File scripts\09_compile_akai_home_apk.ps1 `
  -PackageId "it.akai.customhome" -VersionCode 9 -VersionName "8.1.0" `
  -SigningMode release -KeystorePath "$env:USERPROFILE\.akai-keys\akai_home_release.jks" `
  -KeyAlias "akai_home_release"
```
**Gate 1 aperto**: la firma effettiva e il `versionCode` della `v7` residente su `192.168.1.8` **non risultano in alcun backup offline** e restano **non verificati** finché non verrà autorizzato l'audit ADB read-only.

---

## 2. Modalità di Prova / Installazione e Checklist Statica Build Parallela (P1 #1)

Entrambi i percorsi sono attualmente **bloccati dall'hardware freeze**.

### Opzione A — Prova Parallela a Rischio Ridotto (Subordinata a Preflight Read-Only e Validazione Statica)
La coesistenza di un secondo package (`it.akai.customhome.v8`) **non** sovrascrive la sandbox dati della `v7`, ma **non è priva di rischi operativi**.

**Rischi operativi espliciti da controllare**:
1. **RAM molto stretta (`1.331 MB` totali)**: nell'audit `05/11/2026` (`backups/audit_20261105_225521/free_ram.txt`), la TV dispone di `1.331 MB` RAM visibili + `499 MB` zRAM (`~41 MB` liberi non-cached, `~390–547 MB` recuperabili a riposo). Avviare una seconda app launcher in parallelo aumenta l'impronta memoria (PSS processo grafico + cache icone/banner) con possibile intervento LMKD su servizi in background (incluso `it.akai.customremote`) o rallentamenti finché il pacchetto di prova resta residente in memoria.
2. **Interferenza `CATEGORY_HOME` sul resolver**: su Android 9, l'installazione di un secondo package che espone `<category android:name="android.intent.category.HOME" />` può invalidare la `preferredActivity` attiva o far comparire il selettore di scelta launcher al successivo tasto `HOME`. Per il primo test visivo/D-Pad isolato va quindi preferita la variante `-ExcludeHomeIntent`, pur sapendo che senza filtro `HOME` quel pacchetto **non** consente di collaudare il tasto fisico `HOME` su se stesso.

#### Checklist di Validazione Statica Eseguita sui Sorgenti (`akai-custom-home/app/src/main/**`)
| Verifica Statica | Risultato su Sorgenti Reali | Impatto su Build Parallela (`it.akai.customhome.v8`) |
| :--- | :--- | :--- |
| **`applicationId` / `package`** | `AndroidManifest.xml:3` definisce `package="it.akai.customhome"` (build diretta via `aapt2` + `javac` + `d8`). Con `--rename-manifest-package it.akai.customhome.v8 --custom-package it.akai.customhome`, `aapt` conferma `package="it.akai.customhome.v8"` e `R.java` generato sotto `it.akai.customhome`. | **Componente esatto da avviare**: **`it.akai.customhome.v8/it.akai.customhome.MainActivity`** (la forma abbreviata `/.MainActivity` fallirebbe con `ClassNotFoundException` perché `MainActivity.java` resta nel package `it.akai.customhome`). Verificato offline con `aapt dump xmltree` e integrato in CI step 8. |
| **Componenti `Manifest`** | `AndroidManifest.xml:29-45`: 1 sola `<activity>` esportata (`launchMode="singleTask"`). **0 `<service>`**, **0 `<receiver>`** statici. | Nessun conflitto di componenti esportati né duplicazione di servizi in background rispetto alla `v7`. |
| **Intent Filter `HOME`** | `AndroidManifest.xml:40-44` dichiara `MAIN + HOME + DEFAULT`. | Con `-ExcludeHomeIntent`, lo staging manifest rimuove il filtro `HOME` mantenendo solo `LAUNCHER + LEANBACK_LAUNCHER` (installabile senza perturbare il resolver `HOME`). |
| **`ContentProvider` / Authorities** | Assenti: **0 `<provider>`** e **0 `android:authorities`** in tutto il manifest. | Nessun rischio di errore `INSTALL_FAILED_CONFLICTING_PROVIDER`. |
| **Permessi** | Solo `ACCESS_NETWORK_STATE` e `ACCESS_WIFI_STATE` (`normal`). Nessun `<permission>` custom, nessun permesso `dangerous`/`signature`. | Nessun conflitto di firma sui permessi fra `v7` e `v8` parallela. |
| **`BroadcastReceiver` / Azioni** | `MainActivity.java:330-366`: unico receiver registrato dinamicamente in `onResume()` / rimosso in `onPause()` su azioni di sistema `ACTION_PACKAGE_ADDED|REMOVED|REPLACED` (`scheme="package"`). | Non esportato; attivo solo mentre `v8` è in foreground. |
| **`SharedPreferences` & Sandbox** | `MainActivity.java:86, 254`: `PREFS_NAME = "akai_custom_home_prefs"`, `MODE_PRIVATE`. | Dati isolati da Android in `/data/user/0/it.akai.customhome.v8/shared_prefs/` senza toccare `v7` (la build parallela parte con default puliti). |
| **Gestione Tasto `BACK`** | `MainActivity.java:323-326`: `onBackPressed()` intercetta `BACK` e mostra un `Toast` senza chiamare `super.onBackPressed()` né `finish()`. | **Critico**: premendo `BACK` nella `v8` **non si esce dall'activity** (vedi Sezione 4). |
| **Riferimenti Hardcoded a `"it.akai.customhome"`** | Individuati 2 punti in `MainActivity.java` (mantenuto frozen come da Review 10/11):<br>1. **Riga `148`**: `SYSTEM_FILTER_PACKAGES` contiene `"it.akai.customhome"` (match `startsWith` a riga `1040`).<br>2. **Riga `1236`**: `if ("it.akai.customhome".equals(pkg)) continue;` (non usa `getPackageName()`). | Con `showSystemApps=false` (default), la riga `148` nasconde sia `it.akai.customhome.v8` sia `v7`. Se però in build parallela l'utente attiva manualmente `"App Tecniche OEM: Visibili"` (`showSystemApps=true`), `it.akai.customhome.v8` comparirebbe in *Tutte le Applicazioni* (avvio innocuo grazie a `singleTask`, limite noto documentato per mantenere inviolato il bytecode emulator-verified `e193008`). I target esterni (`it.akai.customremote`, `com.android.tv.settings`, `com.mediatek.wwtv.tvcenter`) non confliggono. |

### Opzione B — Upgrade In-Place su `it.akai.customhome`
Ammissibile **solo dopo** che tutti i seguenti gate siano stati verificati positivi sulla TV:
1. Preflight read-only completato (`resolve-activity`, launcher alternativi abilitati, baseline RAM, `dumpsys package it.akai.customhome`).
2. Backup binario APK `v7` estratto (`pm path` -> `adb pull`) e verificato offline (`apksigner verify --print-certs`) **identico** alla keystore del pacchetto candidato `vc=9`.
3. Inventario manuale delle preferenze (Sezione 3) completato prima del comando `adb install -r`.
4. **Stop fail-closed**: qualsiasi mismatch di certificato (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`), assenza di un secondo launcher attivo o fallimento backup APK impone l'arresto immediato senza usare `-d` né disinstallazioni preventive.

---

## 3. Distinzione Netta: Backup APK ≠ Backup Dati / Stato HOME (P1 #3)

È essenziale separare tre livelli di salvataggio distinti:

1. **Backup binario APK (`pm path it.akai.customhome` + `adb pull`)**:
   - **Cosa salva**: *esclusivamente* l'eseguibile APK (`base.apk`) installato sulla TV, consentendo il confronto offline di `versionCode` e certificato (`apksigner`) e la disponibilità del file binario originale.
   - **Cosa NON salva**: **non** copia le `SharedPreferences` utente (`/data/user/0/it.akai.customhome/shared_prefs/akai_custom_home_prefs.xml`), che su Android TV 9 non-root **non sono leggibili via `adb pull`** per isolamento DAC/SELinux; **non** salva neppure l'assegnazione `preferredActivity` del resolver `HOME` nel `PackageManager`.
2. **Comportamento di `adb install -r` (Upgrade In-Place)**:
   - Normalmente Android conserva la directory dati (`/data/user/0/<pkg>/`) quando il pacchetto aggiornato mantiene stesso `packageName`, firma identica e `versionCode` maggiore (`8 -> 9`). Tuttavia **`install -r` non va trattato come garanzia assoluta di rollback**:
     - Se si dovesse **tornare da `v8` (`vc=9`) a `v7` (`vc=8`)**, `adb install -r` rifiuta il downgrade senza `-d` (spesso negato su Android 9 per build non-debuggable); una disinstallazione (`adb uninstall`) per reinstallare `v7` **cancella irreversibilmente** `akai_custom_home_prefs.xml`.
3. **Inventario Obbligatorio Ricostruibile Manualmente Prima di Qualsiasi Upgrade In-Place**:
   Prima di eseguire qualunque `install -r` su `it.akai.customhome`, annotare sullo schermo TV (poiché interamente ricostruibile a mano in 1–2 minuti in caso di perdita dati o downgrade con reinstallazione pulita):
   - Lista ordinata delle **App Preferite** (`KEY_FAVORITES_ORDERED`, es. YouTube, RaiPlay, Infinity, Disney+).
   - **Sfondo selezionato** (`KEY_THEME_BG`, indice `0..4`).
   - **Colore evidenziazione focus** (`KEY_THEME_ACCENT`, indice `0..3`).
   - **Disposizione sezioni** (`KEY_LAYOUT_ORDER`: `Ingressi prima` vs `Preferiti prima`).
   - Toggle **App Tecniche OEM** (`KEY_SHOW_SYSTEM_APPS`) e **Dettagli Rete** (`KEY_SHOW_NETWORK_DETAILS`).
   - **Launcher `HOME` predefinito** prima del test (letto via `resolve-activity`).
   *(Le applicazioni di terze parti installate e i rispettivi login/account non risiedono nel launcher e restano estranei a qualsiasi operazione su `it.akai.customhome`.)*

---

## 4. Procedura Graduata di Recupero HOME (Nessun Fallback Dato per Certo — P1 #2)

Nell'audit `05/11/2026` (`backups/audit_20261105_225521/`) risultavano `/system/app/TvLauncher_Cetus_1_A/TvLauncher_Cetus_1_A.apk` (`cn.cultraview.launcher.technical.open`, `priority=0`) e successivamente `com.leanbitlab.ltvL` (`LTvLauncher`); **non** è presente `com.google.android.tvlauncher`. Poiché né il resolver attuale né l'accessibilità di `Impostazioni -> App Home` sul firmware OEM Cultraview sono stati provati di recente sulla TV reale, **nessun ritorno automatico viene assunto come garantito**.

**Prerequisito Obbligatorio Preflight Read-Only (prima di installare anche in Opzione A)**:
- Leggere `cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME` e l'elenco completo dei receiver `HOME` abilitati (`cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME`).
- Confermare presenza di **almeno un secondo launcher funzionante abilitato** (es. `com.leanbitlab.ltvL` e/o `cn.cultraview.launcher.technical.open`).
- Verificare a schermo se sul firmware OEM Cultraview esiste ed è usabile `Impostazioni -> App -> App predefinite -> App Home` prima di darle ruolo di salvagente locale.

**Livelli di Recupero Graduati**:
1. **Durante Prova Parallela (`it.akai.customhome.v8` con `-ExcludeHomeIntent`, `HOME` invariata)**:
   - **Avvertenza `BACK`**: poiché `MainActivity.onBackPressed()` (`MainActivity.java:324`) consuma `KEYCODE_BACK`, premere `BACK` **non** chiude la preview parallela.
   - **Tentare il ritorno via telecomando**: **tentare** la pressione fisica di **`HOME`** (dipendente dall'effettivo mantenimento della `preferredActivity` baseline su Android/Cultraview), oppure aprire Settings tramite il pulsante header `Impostazioni TV`. *Non è garantito* finché non provato dal vivo con il telecomando sulla TV.
   - **Recupero deterministico da PC (ADB session già aperta)**:
     ```powershell
     adb -s 192.168.1.8:5555 shell am force-stop it.akai.customhome.v8
     adb -s 192.168.1.8:5555 shell am start -n <launcher_baseline_package>/<activity>
     adb -s 192.168.1.8:5555 uninstall it.akai.customhome.v8
     ```
2. **Se il ruolo `HOME` fosse stato modificato (step successivo separato)**:
   - Ripristino esplicito verso il `<launcher_baseline>` fotografato nel preflight (`com.leanbitlab.ltvL/.MainActivity`, `v7` se reinstallata, o OEM `cn.cultraview.launcher.technical.open/com.cultraview.launcher.technical.open.ui.MainActivity`):
     ```powershell
     adb -s 192.168.1.8:5555 shell cmd package set-home-activity <launcher_baseline_package>/<activity>
     adb -s 192.168.1.8:5555 shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME
     adb -s 192.168.1.8:5555 shell am start -n <launcher_baseline_package>/<activity>
     ```
   - Solo dopo conferma visiva su schermo TV dell'avvenuto ripristino, disinstallare eventualmente l'APK di test (`adb uninstall <pkg_test>`) e rieseguire `resolve-activity` + verifica manuale tasto `HOME`.
3. **Tentativo di recupero locale da TV senza PC (subordinato a verifica OEM)**:
   - Qualora `v8` restasse bloccata in foreground con PC non disponibile, provare ad accedere alle Impostazioni Android dal pulsante `Impostazioni TV` o dal tasto Settings del telecomando per **tentare** di reimpostare l'`App Home` o disinstallare il pacchetto di test (funzionalità subordinata a conferma preliminare sul firmware Cultraview).

---

## 5. Autorizzazioni Separate Richieste al Proprietario (Tutte Attualmente Sospese)

1. **[ ] Autorizzazione 1 — Solo Audit ADB Read-Only su `192.168.1.8:5555`** *(zero scritture/installazioni)*:
   - Lettura `resolve-activity` & `query-activities HOME`, `dumpsys package it.akai.customhome`, `adb pull` binario `v7` per confronto firma/versionCode offline, baseline RAM `dumpsys meminfo`, verifica menu `App Home` OEM e inventario preferiti a schermo.
2. **[ ] Autorizzazione 2 — Generazione / Conferma Keystore Release Dedicata & Scelta Percorso (Opzione A vs B)**:
   - Scelta tra **Opzione A (Consigliata: prova parallela `it.akai.customhome.v8` con `-ExcludeHomeIntent`, firmata release dedicata, senza toccare `v7` né `HOME`)** oppure **Opzione B** (solo se preflight firma compatibile e inventario dati completato).
3. **[ ] Autorizzazione 3 — Eventuale Cambio Temporaneo `HOME`** *(solo dopo test visuale/D-Pad/RAM positivo in Opzione A)*.
4. **[ ] Autorizzazione 4 — Eventuale Merge PR #3 su `main`** *(separato da PR #1 e PR #2, solo dopo validazione su TV reale)*.
