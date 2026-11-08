# AKAI Custom Home v8 Leanback — Release-Readiness Report (PR #3)

**Data**: 08 Novembre 2026  
**PR Riferimento**: [#3 — AKAI Custom Home v8 Leanback UI](https://github.com/SmokeJoy/akai-jarvis/pull/3) (ramo `feature/launcher-ui-v8-leanback`, post Review 10 `#issuecomment-6721821227`)  
**Stato Codice**: Freeze sulla parte Java/UI emulator-only (`e193008`, CI [#42482612035](https://github.com/SmokeJoy/akai-jarvis/actions/runs/42482612035) / [#42482616652](https://github.com/SmokeJoy/akai-jarvis/actions/runs/42482616652) `SUCCESS`).  
**Stato Hardware TV (`192.168.1.8`)**: 🔒 **HARDWARE FREEZE ASSOLUTO** — zero comandi ADB, nessuna installazione/disinstallazione, nessun merge su `main`. PR #1 e PR #2 restano separate.

> **Precisazione metodologica (recepimento Review 10)**: il collaudo emulator-only verifica che dopo `KEYCODE_HOME` la finestra attiva torni a `it.akai.customhome/.MainActivity` con un nodo focalizzato appartenente al launcher (`btn_src_dtv`), quindi dimostra **ritorno alla Home AKAI con focus attivo nell'app**, **non** il ripristino garantito dell'identico ID focalizzato prima dell'uscita. Gli 8 pacchetti `test.tv.*` usati in emulatore sono **stub locali di test** e non saranno usati sulla TV reale.

---

## 1. Compatibilità Firma & `versionCode` (v8 vs v7 installata)

| Artefatto / Sorgente | Package | `versionCode` / `versionName` | Certificato / SHA-256 (verifica offline locale) | Compatibilità Upgrade `install -r` su v7 TV |
| :--- | :--- | :--- | :--- | :--- |
| **Baseline `v7` in repo (`ea2f35e`)** (`scripts/09_compile_akai_home_apk.ps1`, `CUSTOM HOME v7`) | `it.akai.customhome` | `8` / `8.0.0` *(nota: usava già `versionCode 8`)* | `tools/debug.keystore` (`06/11/2026 00:49`, `CN=Android Debug`) SHA-256: `21:C2:C4:1D:C4:C3:45:76:CC:A1:4A:D5:40:4E:87:D1:C5:A0:7A:CE:96:1C:0F:AB:96:D1:28:C2:16:4A:51:ED` | Riferimento build locale originale |
| **Build locale `v8` (`akai-custom-home-v8.apk`)** | `it.akai.customhome` | `8` / `8.0.0` | `tools/debug.keystore` (`21:C2:C4:...51:ED`) — **identica a `ea2f35e`** | **Potenzialmente compatibile**, **NON ancora dimostrata on-TV** finché non viene letta la firma reale sulla TV |
| **Artefatto CI GitHub Actions** (`*-ci-test-nondistributable.apk`) | `it.akai.customhome` | `8` / `8.0.0` | Keystore effimera `/tmp/ci_launcher.keystore` | **NON compatibile / NON distribuibile** (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`) |
| **APK `v7` attualmente sulla TV `192.168.1.8`** | *Atteso:* `it.akai.customhome` | *Da verificare live* | **Non presente offline**: l'audit salvato in `backups/audit_20261105_225521/` risale al `05/11/2026` (prima della compilazione/deploy di `v7` del `06-07/11/2026`) | **Stato attuale: DA VERIFICARE IN SOLA LETTURA** quando autorizzato |

**Conclusione Gate 1**:
1. Offline, sia il baseline `v7` (`ea2f35e`) sia l'APK locale `v8` usano la stessa `tools/debug.keystore` (`21:C2:C4:...51:ED`), il che rende probabile la compatibilità in-place.
2. Poiché manca un dump offline dell'APK `v7` effettivamente residente sulla TV, **non è lecito assumere la compatibilità** né eseguire `adb install -r`: il primo passo autorizzato dovrà essere esclusivamente una verifica read-only (`dumpsys package it.akai.customhome` + `adb pull` dell'APK da `pm path it.akai.customhome` + confronto `apksigner verify --print-certs`).
3. Nota operativa su `versionCode`: poiché già `v7` (`ea2f35e`) compilava con `--version-code 8`, per un rilascio tracciabile in-place conviene elevare `v8` a `versionCode=9` (`8.0.1` / `8.1.0`) prima di una eventuale build candidata, **mantenendo invariate** le chiavi `SharedPreferences` (`akai_custom_home_prefs`: `user_favorites_ordered`, `theme_bg_index`, `theme_accent_index`, `theme_layout_order`, `pref_show_system_apps`, `pref_show_network_details`).

---

## 2. Come Installare o Provare la v8 senza Perdere il Launcher Funzionante

Sono previsti due percorsi esclusivi, ordinati per sicurezza, **entrambi bloccati fino ad autorizzazione esplicita**:

### Opzione A — Prova Parallela Zero-Rischi con Package Separato (Consigliata come primo collaudo su TV)
- **Quando usarla**: sempre preferibile per il primo test su hardware reale, ed **obbligatoria** se il pre-check read-only rilevasse firma diversa tra `v7` TV e `v8` locale (oppure impossibilità di backup `v7`).
- **Meccanismo**:
  1. Compilare una build dedicata di preview con package distinto (es. `it.akai.customhome.v8`) senza toccare `it.akai.customhome` (`v7`), `com.leanbitlab.ltvL` (`LTvLauncher`) né `/system/app/TvLauncher_Cetus_1_A`.
  2. Installare solo il nuovo package (`adb install it.akai.customhome.v8.apk`) **senza** modificare il resolver `HOME` predefinito.
  3. Avviare la schermata su richiesta esplicita tramite `am start -n it.akai.customhome.v8/.MainActivity`.
  4. Eseguire sulla TV reale le verifiche mancanti: resa visiva 1920×1080 con app reali installate, navigazione telecomando su 4 sezioni e consumo memoria (`dumpsys meminfo`) entro i margini della TV (`1.331 MB` totali RAM rilevati nell'audit `05/11/2026`, zRAM `499 MB`, `~390–547 MB` liberi a riposo).
- **Preferenze (`SharedPreferences`)**: poiché Android isola i dati per package name, `v7` mantiene intatti i propri preferiti e non viene alterata; `it.akai.customhome.v8` parte invece con preferenze pulite/predefinite (eventuale migrazione delle preferenze di `v7` richiede scelta ed export/import esplicito).

### Opzione B — Upgrade In-Place su `it.akai.customhome` (Solo se firma `21:C2:C4:...` confermata identica + backup `v7` estratto)
- **Precondizioni tassative**:
  1. Estratto e verificato offline il backup APK di `v7` dalla TV (`pm path it.akai.customhome` -> `adb pull`) + verifica `apksigner` con SHA-256 identica a `tools/debug.keystore`.
  2. Confermato offline almeno un secondo launcher attivo pronto al switch immediato (`com.leanbitlab.ltvL` e/o `cn.cultraview.launcher.technical.open`).
- **Meccanismo**: installazione con `adb install -r` (mai `-d` / mai disinstallazione preventiva di `v7`, mai APK effimero CI); Android preserva automaticamente `/data/user/0/it.akai.customhome/shared_prefs/akai_custom_home_prefs.xml`.
- **Stop fail-closed**: in presenza di qualsiasi mismatch di firma (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`) o assenza di backup `v7`, **arresto immediato** e passaggio forzato all'**Opzione A**.

---

## 3. Come Recuperare la Home in Caso di Problemi (Checklist con Stop Sicuri)

Nell'audit TV del `05/11/2026` (`backups/audit_20261105_225521/current_launcher.txt` e `packages_all_details.txt`) risultano presenti:
- Launcher OEM stock immutabile in `/system/app/TvLauncher_Cetus_1_A/TvLauncher_Cetus_1_A.apk`: `cn.cultraview.launcher.technical.open` (`com.cultraview.launcher.technical.open.ui.MainActivity`), `priority=0`.
- Launcher precedente documentato da `rollback_to_ltvlauncher.ps1`: `com.leanbitlab.ltvL` (`LTvLauncher`).
- Sulla AKAI **non** è presente `com.google.android.tvlauncher` (a differenza dell'emulatore AVD). Tuttavia, poiché sull'AVD è stato necessario gestire la priorità del resolver `HOME`, **non si dichiara alcun fallback automatico garantito**: il recupero segue passaggi espliciti e verificati.

**Procedura di recupero graduata**:
1. **Durante Test Parallelo (Opzione A, `HOME` non modificata)**:
   - Premere fisicamente **`HOME` o `BACK`** sul telecomando TV -> il sistema ritorna al launcher predefinito funzionante (`v7` o `LTvLauncher`).
   - Rimozione pulita opzionale della build di prova: `adb shell am force-stop it.akai.customhome.v8` seguito da `adb uninstall it.akai.customhome.v8`.
2. **Se il ruolo `HOME` fosse stato impostato su v8**:
   - **Ripristino esplicito via ADB** verso il launcher funzionante registrato nel pre-check (es. `v7` ripristinata dal backup estratto, `com.leanbitlab.ltvL/.MainActivity`, oppure stock OEM `cn.cultraview.launcher.technical.open/com.cultraview.launcher.technical.open.ui.MainActivity`):
     ```powershell
     adb -s 192.168.1.8:5555 shell cmd package set-home-activity <package_ripristino>/<activity>
     adb -s 192.168.1.8:5555 shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME
     adb -s 192.168.1.8:5555 shell am start -n <package_ripristino>/<activity>
     ```
   - Solo dopo verifica visiva del ripristino funzionante, rimuovere eventualmente il package problematico con `adb uninstall <package_v8>` e ripetere la verifica `resolve-activity` + test tasto fisico `HOME`.
3. **Recupero locale da TV senza PC (in emergenza)**:
   - Se un'activity restasse bloccata ma i tasti hardware/Settings rispondono, aprire `Impostazioni Android -> App -> App predefinite -> App Home` (oppure `App -> Disinstalla`) per riassegnare il launcher precedente o rimuovere la build di test.

---

## 4. Azioni che Richiedono Esplicita Autorizzazione del Proprietario (Tutte Attualmente Sospese)

1. **[ ] Autorizzazione Audit Read-Only su `192.168.1.8:5555`** *(zero modifiche)*:
   - Lettura `resolve-activity HOME`, elenco launcher abilitati (`customhome`, `ltvL`, `cultraview`), `dumpsys package it.akai.customhome`, `adb pull` APK `v7` per verifica firma/versionCode offline e baseline memoria.
2. **[ ] Scelta Esplicita Modalità di Collaudo TV**:
   - **Opzione A (Consigliata: Test parallelo `it.akai.customhome.v8` senza toccare `v7` né `HOME`)** vs **Opzione B (Upgrade in-place su `it.akai.customhome`)** subordinata a identità firma + backup `v7` estratto.
3. **[ ] Autorizzazione al Cambio Temporaneo di `HOME` Predefinita**:
   - Solo *dopo* superamento positivo del test visivo/telecomando/RAM via `am start` sulla TV.
4. **[ ] Autorizzazione Finale al Merge di PR #3 su `main`**:
   - Da valutare separatamente rispetto a [PR #1 (JARVIS)](https://github.com/SmokeJoy/akai-jarvis/pull/1) e [PR #2 (Visual Audit)](https://github.com/SmokeJoy/akai-jarvis/pull/2) solo dopo collaudo TV reale positivo.
