### Riscontro Tecnico alla Sesta Revisione su PR #3 (AKAI Custom Home v8 Leanback)

**Commit di riferimento:** `8b10aae` su branch `feature/launcher-ui-v8-leanback`  
**GitHub Actions CI Status:**
- Push Run `#42475422824`: **SUCCESS** (113/113 test unitari superati, strict Android 9 API 28)
- Pull Request Run `#42475426424`: **SUCCESS** (compilazione AAPT2, D8, zipalign, apksigner)
- **113/113 Test Unitari Java PASS (100%)**
- **Hardware Freeze TV:** Rigorosamente inviolato (zero byte, zero socket, zero ping verso `192.168.1.8`)

---

### 1. Risoluzione P0 — Isolamento Deterministico ADB Fail-Closed

In `scripts/10_android_tv_emulator_smoke_test.ps1`:
1. **Rilevazione e Validazione Esclusiva:**
   - La funzione `Get-ValidatedEmulatorSerial` esamina l'output di `adb devices`.
   - **Rifiuto categorico di dispositivi estranei:** Se è presente **qualsiasi** target non-emulatore (IP di rete `192.168.*`, dispositivi fisici o porte 5555), lo script lancia immediatamente eccezione bloccante `SICUREZZA P0 VIOLATA` e interrompe l'esecuzione senza impartire alcun comando.
   - **Rifiuto ambiguità:** Richiede tassativamente esattamente **1** seriale `emulator-\d+` in stato `device`. Zero o molteplici emulatori innescano il blocco fail-closed.
2. **Vincolo del Target su Ogni Invocazione ADB:**
   - Tutte le chiamate `adb` (`install -r`, `shell am start`, `shell input keyevent`, `shell dumpsys`, `shell screencap`, `pull`) passano tassativamente il parametro `-s $emulator`. Nessun comando orfano o dipendente dal dispositivo di default.
3. **Validazione Fingerprint Target Prima dell'Installazione:**
   - Prima di qualsiasi operazione di installazione, verifica che `ro.build.version.sdk` sia rigorosamente `28` e `ro.product.model` corrisponda al profilo virtuale Android TV (`sdk_google_atv_x86`).
4. **Unit Test di Isolamento (Script 11):**
   - Creato [`scripts/11_test_emulator_smoke_script_isolation.ps1`](scripts/11_test_emulator_smoke_script_isolation.ps1) che testa in modalità isolata (mock) i 5 scenari critici:
     - Scenario 1 (Solo TV fisica `192.168.1.8:5555`): **BLOCCATO con SICUREZZA P0 VIOLATA**
     - Scenario 2 (TV fisica + Emulatore contemporanei): **BLOCCATO con SICUREZZA P0 VIOLATA**
     - Scenario 3 (Nessun dispositivo connesso): **BLOCCATO con SICUREZZA P0 FAIL-CLOSED**
     - Scenario 4 (Multipli emulatori contemporanei): **BLOCCATO per ambiguità**
     - Scenario 5 (Singolo emulatore valido `emulator-5554`): **APPROVATO**
   - Risultato test isolamento: **5 / 5 superati (100% PASS)**.

---

### 2. Risoluzione P1 — Smoke Test Automatico con Asserzioni Deterministiche

Lo script `10_android_tv_emulator_smoke_test.ps1` non si limita più all'invio di keyevent ciechi, ma include ora asserzioni esplicite con `Assert-Step`:
- Verifica presenza binari SDK e APK compilato.
- Validazione esito `Success` di `adb install -r`.
- Validazione del foreground window tramite `dumpsys window windows | Select-String "mCurrentFocus"` (`it.akai.customhome.MainActivity` con focus esclusivo).
- Validazione dell'acquisizione ed esistenza su disco di ogni singolo screenshot a 1080p.

---

### 3. Risoluzione P1 — Catalogo Streaming Completo a 4 Righe e Prova D-Pad

Per verificare il layout completo a 4 righe e lo scorrimento orizzontale reale senza coinvolgere dati sensibili o contattare la TV fisica:
- Creato [`scripts/build_test_streaming_apps_apk.ps1`](scripts/build_test_streaming_apps_apk.ps1) che compila una suite di test locale contenente 7 Leanback activities:
  - YouTube (`com.google.android.youtube.tv`)
  - Netflix (`com.netflix.ninja`)
  - Prime Video (`com.amazon.amazonvideo.livingroom`)
  - RaiPlay (`it.rainet.raiplay`)
  - Disney+ (`com.disney.disneyplus`)
  - VLC (`org.videolan.vlc`)
  - Kodi (`org.xbmc.kodi`)
- Con la suite installata sull'emulatore, la riga **STREAMING & CINEMA** e la riga **TUTTE LE APPLICAZIONI** risultano interamente popolate.
- Catturate 7 nuove evidenze runtime a 1080p in `docs/screenshots/emulator/`:
  1. `01_home_screen_clean.png`: Home screen con le 4 righe visibili e catalogo streaming popolato.
  2. `02_streaming_focus_scale.png`: Focus dorato e ingrandimento 1.08x su card streaming.
  3. `03_streaming_horizontal_scroll.png`: Scorrimento orizzontale fluido verso destra su Disney+, VLC e Kodi.
  4. `04_app_options_dialog.png`: Pressione prolungata OK su card app che apre il dialogo "Aggiungi ai Preferiti".
  5. `05_favorites_row_populated.png`: Aggiunta ai preferiti eseguita e comparsa dinamica della riga **APP PREFERITE**.
  6. `06_theme_customization_dialog.png`: Apertura del menu impostazioni / personalizzazione tema e toggle app tecniche OEM.
  7. `07_home_key_focus_retention.png`: Pressione tasto HOME con ripristino stabile del focus e conservazione dello stato.

---

### 4. Rifinitura UX — Header Spacing

- In `akai-custom-home/app/src/main/res/values/strings.xml`, la stringa `brand_custom_tv` è stata ottimizzata da `CUSTOM HOME v8 LEANBACK` a `CUSTOM HOME v8`.
- Questo elimina l'affollamento nella top bar, garantendo una generosa area di respiro tra il titolo dell'interfaccia e gli indicatori/tasti Wi-Fi, Tema e Orologio.

---

### 5. Sintesi e Prossimi Passi

- **Nessun merge su `main`:** PR #1, PR #2 e PR #3 rimangono rigorosamente aperte e confinate nei rispettivi rami.
- **TV fisica protetta al 100%:** Hardware freeze intatto.
- Come concordato, la fase di micro-review del codice è completata e il runtime su Android TV 9 emulato è validato.
- In vista della futura fase di rilascio, verrà predisposta una checklist per la firma release e per il ripristino sicuro (rollback) alla v7, soggetta ad approvazione esplicita dell'utente.
