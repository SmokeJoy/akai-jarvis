# Riscontro Tecnico alla Nona Revisione PR #3 — P0 `HOME RETURN GATE`, Verifica UIAutomator, Header/Card Polish & Trasparenza Release

**Data**: 08 Novembre 2026  
**PR Riferimento**: [#3 — AKAI Custom Home v8 Leanback UI](https://github.com/SmokeJoy/akai-jarvis/pull/3)  
**Revisione Riscontrata**: Nona Revisione ChatGPT (`#issuecomment-6721472537`)  
**Commit Implementativo Verificato**: `5169abb` (`5169abb08c258567e6615f909c8bea1c091e8546`)  
**Pipeline CI su `5169abb`**:
- `AKAI Launcher CI` (`push`): [#42482329682](https://github.com/SmokeJoy/akai-jarvis/actions/runs/42482329682) — **SUCCESS**
- `AKAI Launcher CI` (`pull_request`): [#42482333336](https://github.com/SmokeJoy/akai-jarvis/actions/runs/42482333336) — **SUCCESS**
- **113 / 113** unit test Java (`LauncherUnitTests.java`) — **PASS**
- **7 / 7** test di isolamento fail-closed ADB (`scripts/11_test_emulator_smoke_script_isolation.ps1`) — **PASS**
- Build standalone Android API 28 (compile `android-28`, `aapt2`, `d8`, `zipalign`, `apksigner`, verifica interna APK) — **PASS**

**Stato Hardware TV (`192.168.1.8`)**: 🔒 **HARDWARE FREEZE ASSOLUTO** (zero comandi ADB, zero socket, zero ping verso la TV reale).  
**Politica Ramo**: Nessun merge su `main`. PR #1 (`fix/pr01-endpoints-remote-activity`), PR #2 (`docs/launcher-visual-audit`) e PR #3 (`feature/launcher-ui-v8-leanback`) restano rigorosamente separate e aperte.

---

## 1. P0 — Risoluzione «HOME focus retention» (`HOME RETURN GATE` reale con `KEYCODE_HOME`)

Nel ciclo precedente `07_home_key_focus_retention.png` mostrava il launcher Google Android TV di fabbrica dell'AVD e `scripts/10_android_tv_emulator_smoke_test.ps1` non verificava né il package in foreground dopo `input keyevent 3` né il nodo focalizzato.

**Interventi eseguiti in `5169abb`**:
1. **Eleggibilità `HOME` nel Manifest (`akai-custom-home/app/src/main/AndroidManifest.xml`)**:
   - Aggiunto il filtro esplicito su `.MainActivity`:
     - `<action android:name="android.intent.action.MAIN" />`
     - `<category android:name="android.intent.category.HOME" />`
     - `<category android:name="android.intent.category.DEFAULT" />`
2. **Isolamento Default HOME nella sola sandbox AVD (`scripts/10_android_tv_emulator_smoke_test.ps1`, fase `[4/7]`)**:
   - Oltre a `cmd package set-home-activity it.akai.customhome/.MainActivity`, lo script verifica `cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME`.
   - Poiché sull'emulatore Google Android TV 9 `com.google.android.tvlauncher` ha `mPriority=2`, quando necessario lo script lo disabilita temporaneamente **esclusivamente in sandbox emulatore** (`pm disable-user --user 0 com.google.android.tvlauncher`, poi riabilitato al termine della sessione AVD) e fallisce subito con `Assert-Step` se il resolver `HOME` non punta esplicitamente a `it.akai.customhome/.MainActivity`.
3. **Assert reale di uscita app esterna + ritorno fisico tramite `KEYCODE_HOME (3)` (fase `[7/7]`)**:
   - Avvio reale di un'app esterna (`am start -W -n test.tv.netflix/.MainActivity`) con assert su `dumpsys window windows` (`mCurrentFocus` contiene `test.tv.netflix`).
   - Invio autentico di `input keyevent 3` (`KEYCODE_HOME`, nessun `am start` verso il launcher).
   - Verifica fail-closed su `mCurrentFocus`: se non corrisponde a `it.akai.customhome/(.|it.akai.customhome.)MainActivity`, lo script solleva errore esplicito `"HOME RETURN: FAIL - ..."`.
   - Verifica UIAutomator sul nodo `@focused='true'` (`package="it.akai.customhome"`, focus ripristinato attivamente dentro il launcher su `btn_src_dtv`).
4. **Nuova evidenza `docs/screenshots/emulator/07_home_key_focus_retention.png`**:
   - Cattura reale 1920×1080 di `it.akai.customhome` (`11:31`) ripristinata dal tasto `HOME`, con `TV Digitale` in focus oro e i 3 preferiti (`NETFLIX`, `Prime Video`, `Infinity+`) preservati.

---

## 2. P1 — Eliminazione duplicati (`04`, `05`, `06`), Root Cause Focus Dialoghi & Rimozione Screenshot Obsolete

Le catture `05_favorites_row_populated.png` e `06_theme_customization_dialog.png` della tornata precedente risultavano duplicate sul dialogo di `Mediaset Infinity` per due motivi concorrenti: assenza di assert semantici UIAutomator prima di `screencap` e una race condition sul focus della finestra durante il long-press D-Pad.

**Root cause diagnosticata sull'emulatore**:
- In Android 9 TV, aprire una `AlertDialog` sincronicamente dentro `CardKeyHandler.onKey(ACTION_DOWN)` prima della chiusura del dispatch tasti lasciava l'`AlertDialog` senza window focus (`ViewRootImpl: Dropping event due to no window focus`), bloccando anche `KEYCODE_BACK` e causando `ERROR: null root node returned by UiTestAutomationBridge` in UIAutomator.

**Correzioni effettuate**:
1. **`MainActivity.java`**:
   - In `CardKeyHandler.onKey`, l'apertura di `showFavoriteOptionsDialog` / `showAppOptionsDialog` viene differita tramite `v.postDelayed(openDialogTask, 80L)` mentre `longPressHandled = true` resta sincrono (garantendo zero lanci app su `ACTION_UP`).
   - Introdotto l'helper `showAccessibleDialog(AlertDialog.Builder)` che esegue `lv.post` -> `lv.requestFocus(); lv.setSelection(0);` sulla `ListView` del dialogo prima dell'interazione D-Pad.
   - Aggiornati i corrispettivi host mock (`View.java`, `AlertDialog.java`, `ListView.java`) mantenendo 113/113 test Java verdi.
2. **`scripts/10_android_tv_emulator_smoke_test.ps1` (`Get-UiDumpXml` + assert semantici per ogni scatto)**:
   - Ogni cattura `01`..`07` è ora preceduta da `uiautomator dump --compressed` + query XPath/bounds:
     - `04_app_options_dialog.png`: verifica `mCurrentFocus` su `it.akai.customhome` (nessun avvio spurio su long-press) e presenza nel XML dei testi `"Aggiungi ai Preferiti"` e `"Informazioni Applicazione"` sul dialogo `Netflix`.
     - `05_favorites_row_populated.png`: dopo aggiunta reale via UI di 3 preferiti (`Netflix`, `Prime Video`, `Mediaset Infinity`) e ritorno su `scroll_favs`, verifica su XML che `scroll_favs//card_root` contenga `>= 3` card (`3` reali) e che tutte e 4 le intestazioni/sezioni siano simultaneamente visibili entro `Y2 <= 1080` (`bottom=1000`, zero taglio inferiore).
     - `06_theme_customization_dialog.png`: navigazione verificata fino a `btn_home_theme`, apertura dialogo, assert XML sui testi `"Personalizzazione AKAI Home"` e `"Scegli Sfondo"`, cattura del dialogo reale `Personalizzazione AKAI Home v8 Leanback`, seguita da chiusura verificata con `BACK`.
3. **Pulizia `docs/screenshots/emulator/`**:
   - Eliminati via `git rm` i 9 file obsoleti delle revisioni 5/6 (`02_card_focus_scale.png`, `02_streaming_focus_scale.png`, `03_theme_customization_dialog.png`, `04_oem_apps_toggle_toast.png`, `05_dpad_app_navigation.png`, `06_longpress_options_dialog.png`, `07_favorites_row_populated.png`, `08_home_key_focus_retention.png`, `smoke_test_latest.png`).
   - Nel repository resta **solo** il set univoco e coerente `01`..`07` del run verificato.

---

## 3. P1 — Correzione Reale Header, Orologio e Margini Layout 1920×1080 (Zero Clipping & Zero Bleed)

1. **`strings.xml` allineato davvero**:
   - `brand_custom_tv` modificato effettivamente da `CUSTOM HOME v8 LEANBACK` a **`CUSTOM HOME v8`**.
2. **Header e Orologio responsivi in `activity_main.xml`**:
   - `#tv_brand_version`: `singleLine="true"`, `ellipsize="end"`, `maxWidth="170dp"`.
   - Spacer elastico `layout_weight="1"` tra branding a sinistra e pillole a destra; `#btn_home_wifi` con `singleLine="true"`, `ellipsize="end"`, `maxWidth="165dp"`.
   - `#home_clock` (`TextClock`): impostati esplicitamente `android:format12Hour="HH:mm"` e `android:format24Hour="HH:mm"` su **entrambe** le modalità per eliminare definitivamente l'overflow con suffisso `AM/PM`, con `singleLine="true"`, `minWidth="46dp"` e `gravity="end|center_vertical"`.
3. **Audit UIAutomator bounds 1920×1080 in `scripts/10_android_tv_emulator_smoke_test.ps1` (`[5/7]`)**:
   - Verificato a runtime su emulatore 1080p:
     - `tv_brand_version.text == "CUSTOM HOME v8"` e separazione netta da `btn_home_wifi` (`brand.X2 < wifi.X1`, `430 < 899`);
     - `home_clock.text` formato esatto `^\d{2}:\d{2}$` (`11:30` / `11:31`), `clock.X2 <= 1900` (`x2=1880`);
     - Quinta tessera `btn_src_all` interamente visibile entro `x2 <= 1900` (`x2=1842`).
4. **Prevenzione clipping card & bleed sulla Sidebar**:
   - Abilitato `clipChildren="true"` e `clipToPadding="true"` su `scroll_main_body` e sui `HorizontalScrollView` delle righe, ridotto `attachFocusScale` card da `1.08f` a `1.045f` e ampliato padding orizzontale/verticale dei contenitori (`8dp` L/R, `6dp`/`7dp` T/B) così le card scrollate si tagliano in modo pulito sul divisore verticale della Sidebar senza mai sovrapporvisi e mantenendo integri tutti e 4 gli angoli arrotondati oro `#FFB300` della card in focus (`03_streaming_horizontal_scroll.png`, `05_favorites_row_populated.png`).
   - Aggiunti collegamenti espliciti `nextFocusUp` tra i pulsanti ingressi hardware (`btn_src_*`) e la Top Bar per navigazione telecomando predicibile.

---

## 4. P1 — Rendering Card da `PackageManager` & Chiarimento Esplicito sugli 8 Stub Locali

1. **Supporto nativo Banner Android TV nel launcher (`MainActivity.java`, `item_leanback_card.xml`)**:
   - Estesa `AppItem` con campo `banner` (`Drawable`), letto nativamente tramite `ri.activityInfo.loadBanner(pm)` con fallback su `pm.getApplicationBanner(ri.activityInfo.applicationInfo)`.
   - `item_leanback_card.xml` adotta doppia modalità:
     - quando `item.banner != null`: tessera banner full-bleed arrotondata (`iv_card_banner`, `centerCrop`, `setClipToOutline(true)`);
     - fallback automatico su pillola orizzontale glassmorfica icona + etichetta (2 righe) per le app prive di banner Leanback.
   - Dimensioni bilanciate (`168×92dp` in *Streaming & Cinema*, `136×68dp` in *App Preferite* e *Tutte le Applicazioni*) che consentono la vista simultanea di tutte e 4 le sezioni in 1080p senza sovraffollamento (`05_favorites_row_populated.png`).
   - Raffinato il filtro tecnico in `MainActivity.java` aggiungendo `com.android.traceur` / `com.google.android.traceur` / `System Tracing` (con assert negativo nel collaudo).
2. **Distinzione onesta fra stub di test e prodotto finale (`scripts/build_test_streaming_apps_apk.ps1`)**:
   - Gli 8 APK installati sull'emulatore (`test.tv.youtube`, `test.tv.netflix`, `test.tv.prime`, `test.tv.raiplay`, `test.tv.disney`, `test.tv.infinity`, `test.tv.vlc`, `test.tv.kodi`) sono **pacchetti stub di collaudo locali** dotati di grafiche vettoriali GDI+ (`320×180` banner + `192×192` icona) generati in build locale esclusivamente per verificare resa UI, banner distinti, carosello orizzontale e preferiti sull'AVD.
   - Il launcher **non** include né attribuisce cataloghi video/poster di terze parti in assenza di sorgenti/diritti: su hardware reale renderizza esclusivamente icone e banner ufficiali dichiarati dai pacchetti installati tramite `PackageManager`.

---

## 5. P1 — Trasparenza Totale su Rollback OEM e Firme di Rilascio (Nessuna Garanzia Non Dimostrata)

Accogliamo integralmente la correzione metodologica e formuliamo esplicitamente i limiti reali di quanto dimostrato finora:

1. **Nessun rollback OEM automatico dimostrato sulla TV fisica AKAI**:
   - Poiché vige l'**HARDWARE FREEZE (`192.168.1.8`)**, lo stato reale dei resolver `HOME`, il valore di `mPriority` di `cn.cultraview.launcher.technical.open` ed eventuali altri launcher preinstallati in `/system` o `/vendor` sulla TV fisica **non sono stati ispezionati live**.
   - Proprio l'esperienza sull'emulatore AVD (dove `com.google.android.tvlauncher` con `mPriority=2` intercettava `HOME` anche dopo `cmd package set-home-activity`) conferma che la presenza di un APK OEM di sistema non permette di dichiarare a priori un fallback automatico senza ispezione del `PackageManager` target.
2. **Incompatibilità firme tra eventuale `v7` installata e build di test/CI**:
   - L'artifact CI (`akamai-custom-home-v8-ci-test-nondistributable.apk`) è firmato con keystore effimera in `/tmp/ci_launcher.keystore` (esplicitamente non distribuibile) e la suite locale usa `tools/debug.keystore` per il solo emulatore.
   - Nessuna di queste chiavi — né una nuova keystore — può eseguire un aggiornamento in-place sopra un eventuale `v7` già firmato con chiave diversa (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`).
   - Prima di qualsiasi futura azione autorizzata sull'hardware sarà pertanto necessario: (a) audit read-only del certificato dell'APK `v7` eventualmente presente e dello stato effettivo di `resolve-activity` `HOME` sulla TV; (b) decisione esplicita dell'utente sulla strategia (stessa firma, package separato/installazione controllata), **senza disinstallare `v7` né toccare la TV senza consenso espresso**.

---

## 6. Riepilogo Set Screenshot 1920×1080 Verificate (`docs/screenshots/emulator/`)

| File | Stato Coperto & Evidenza UIAutomator / WindowManager |
| :--- | :--- |
| `01_home_screen_clean.png` | Top bar `AKAI \| CUSTOM HOME v8`, clock `11:30` completo, 5 ingressi completi (`Menu Ingressi` entro 1900px), 8 banner distinti, zero `System Tracing`. |
| `02_sidebar_navigation_focus.png` | Focus D-Pad acquisito realmente da `sidebar_nav_home` nella barra laterale. |
| `03_streaming_horizontal_scroll.png` | Scorrimento orizzontale reale nella riga *Streaming & Cinema*: *Disney+* ritagliata sul divisore verticale, focus oro integro sui 4 angoli su *NETFLIX*. |
| `04_app_options_dialog.png` | Long-press OK su card *NETFLIX*: finestra ancora su `it.akai.customhome` (app non avviata) e dialogo Dark Glass *Aggiungi ai Preferiti / Informazioni Applicazione*. |
| `05_favorites_row_populated.png` | Tutte e 4 le sezioni visibili in 1080p (`bottom <= 1080`) con *App Preferite* popolata realmente con 3 app (*NETFLIX*, *Prime Video*, *Infinity+* in focus). |
| `06_theme_customization_dialog.png` | Navigazione su pillola *Tema* e apertura reale del dialogo *Personalizzazione AKAI Home v8 Leanback*. |
| `07_home_key_focus_retention.png` | Uscita su `test.tv.netflix` -> `input keyevent 3` (`KEYCODE_HOME`) -> ritorno verificato a `it.akai.customhome` con focus trattenuto su *TV Digitale* e preferiti intatti. |
