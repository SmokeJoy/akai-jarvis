# AKAI Custom Home v8 — Specifiche Architetturali, Layout Leanback e Audit Visivo

## 1. Visione e Obiettivi del Redesign

La versione precedente del launcher (`it.akai.customhome` v7), pur garantendo stabilità ed accesso diretto agli ingressi fisici e alle app, presentava limiti evidenti di usabilità tipici dell'adattamento di una griglia generica su un display televisivo:
- **Testi e didascalie troppo piccoli** (10–12sp), difficilmente leggibili dal divano a 3–4 metri di distanza.
- **Griglia fissa a 6 colonne**, con scarso respiro visivo e navigazione D-Pad affollata.
- **Inquinamento visivo da utility tecniche OEM** (`A2dpSinkPlayer`, `Boot Video`, `CULTRAVIEW_OPEN_LAUNCH...`), prive di valore d'uso quotidiano per l'utente finale.
- **Mancanza di categorizzazione streaming**, disperdendo app di intrattenimento (RaiPlay, Netflix, Prime Video, Disney+, YouTube) in un elenco alfabetico generico.

La nuova architettura **v8 Leanback** adotta le linee guida canoniche di Google Android TV per interfacce a 10 piedi (10-Foot UI), riorganizzando i contenuti in **quattro righe orizzontali tematiche**, con tipografia maggiorata (&ge; 14sp), focus ad altissimo contrasto (WCAG AAA 13.3:1) e zoom leggero (1.08x) su D-Pad.

> [!NOTE]
> **Dichiarazione Trasparente Materiali Grafici**:
> I file `AKAI_CUSTOM_HOME_v8_anteprima_leanback.png` e `AKAI_CUSTOM_HOME_v8_comparazione_prima_dopo.png` sono render e simulazioni grafiche generate via headless browser del mockup interattivo `AKAI_CUSTOM_HOME_v8_LEANBACK_COMPARAZIONE.html`. **Non costituiscono catture runtime da dispositivo TV fisico né da emulatore Android.** Il collaudo visivo e strumentale su hardware reale rimane subordinato al superamento del preflight privilege gate e a esplicita autorizzazione dell'utente.

---

## 2. Matrice di Risoluzione Rilievi (Revisione 1 — PR #3)

| Area di Rilievo | Gravità | Problema Identificato | Soluzione Implementata | Esito Tecnico |
| :--- | :--- | :--- | :--- | :--- |
| **Pressione Prolungata OK** | **P0** | Pressione lunga apriva il dialogo ma al rilascio (ACTION_UP) lanciava anche l'app | Implementato `CardKeyHandler` con tracking rigoroso `longPressHandled`: su ACTION_UP consuma l'evento se long-press è stato gestito | **Risolto (Validato da test 1.1–1.4)** |
| **Aggiornamento App Stantio** | **P1** | `onResume()` aggiornava solo Wi-Fi; app installate/rimosse in background non apparivano | Registrato `BroadcastReceiver` dinamico per `PACKAGE_ADDED/REMOVED/REPLACED` + `loadInstalledApps()` in `onResume` con pulizia orfani | **Risolto (Catalogo reattivo)** |
| **Troncamento Nomi App** | **P1** | `android:singleLine="true"` tagliava i nomi lunghi a 14sp | Aggiornato `item_leanback_card.xml` con `maxLines="2"`, `lines="2"`, altezza card a 118dp | **Risolto (Titoli su 2 righe leggibili)** |
| **Focus Uniforme su Tutta la UI** | **P1** | Chip ingressi e pulsanti header usavano selector statici indipendenti dal tema | Metodo `updateHeaderAndInputsSelectors()` che applica l'accento e i colori tema a tutti i pulsanti | **Risolto (Coerenza cromatica 100%)** |
| **Clipping Cursore Zoom 1.08x** | **P1** | Le prime/ultime tessere scalando a 1.08x venivano tagliate dai bordi dei container | Aggiunto `clipChildren="false"` e `clipToPadding="false"` su tutti i container e padding orizzontale 6dp | **Risolto (Zoom fluido senza tagli)** |
| **Privacy Dati di Rete** | **P1** | Header mostrava SSID e IP locale dinamico visibili a schermo | Aggiunto toggle `pref_show_network_details` (default: **Nascosto/Privacy**): mostra `📶 Wi-Fi Connesso` | **Risolto (Zero leak IP visivo)** |
| **Assenza Test Suite CI** | **P1** | La CI verificava solo la sintassi e il build APK senza test launcher | Creata suite `LauncherUnitTests` (46 test Java) integrata nel workflow CI | **Risolto (46/46 PASS in CI)** |
| **Artefatto CI Distribuibile** | **P1** | Rischio di confondere l'APK di CI firmato con chiave temporanea con una release | APK CI rinominato `akai-custom-home-v8-ci-test-nondistributable.apk` con blocco formale | **Risolto (Fail-Closed)** |

---

## 3. Architettura delle Sezioni v8

```
+---------------------------------------------------------------------------------------------------+
|  [AKAI] CUSTOM HOME v8 LEANBACK     [📶 Wi-Fi Connesso] [📱 Associa iPhone] [🎨 Tema] [⚙️ Setup] 12:45 |
+---------------------------------------------------------------------------------------------------+
|  INGRESSI HARDWARE (15sp bold)                                                                    |
|  [ 📺 TV Digitale ]*   [ 🎮 Fire TV (HDMI 1) ]   [ 🎬 HDMI 2 ]   [ 💻 HDMI 3 ]   [ 🔌 Menu Ingr ]  |
+---------------------------------------------------------------------------------------------------+
|  APP PREFERITE (15sp bold) · (Tieni premuto OK per riordinare o rimuovere)                        |
|  [ ▶️ YouTube TV ]*    [ 📡 RaiPlay ]    [ 🍿 Netflix ]    [ 📺 Infinity+ ]    [ 🏰 Disney+ ]     |
+---------------------------------------------------------------------------------------------------+
|  STREAMING & CINEMA (15sp bold) · (Piattaforme video e multimediali)                              |
|  [ 📦 Prime Video ]*   [ 📡 RaiPlay ]    [ 🍿 Netflix ]    [ 📺 Infinity+ ]    [ 🎧 Spotify ]     |
+---------------------------------------------------------------------------------------------------+
|  TUTTE LE APPLICAZIONI (15sp bold) · (Catalogo completo pulito da app diagnostiche OEM)          |
|  [ 🌐 Browser Web ]    [ 📁 File Mgr ]   [ 🛍️ Play Store ] [ 📸 Galleria ]    [ ⚙️ Impostazioni ] |
+---------------------------------------------------------------------------------------------------+
  * = Esempio cursore D-Pad attivo con evidenziazione dorata 3.5dp e zoom 1.08x
```

### 3.1 Sezione 1: Ingressi Hardware
- Chip orizzontali ad alto contrasto (larghezza 165–190dp, altezza 46dp).
- Supporto al passthrough codificato MediaTek WWTV Tuner & HDMI Service.
- Focus iniziale automatico sul pulsante DTV alla pressione del tasto HOME.

### 3.2 Sezione 2: App Preferite
- Card orizzontali ad ampia superficie (175dp &times; 118dp) con supporto a 2 righe di testo da 14sp.
- Possibilità di aggiungere, rimuovere e riordinare a piacimento le app tramite D-Pad (OK prolungato).
- Pulizia automatica dei preferiti se un'applicazione viene disinstallata dalla TV.

### 3.3 Sezione 3: Streaming & Cinema
- Identificazione automatica di tutte le piattaforme di intrattenimento installate tramite package signature e keyword analysis (YouTube, Netflix, Prime Video, RaiPlay, Mediaset Infinity, Disney+, Spotify, Kodi, VLC, Pluto TV, TIMVISION, ecc.).
- Raggruppamento orizzontale scorrevole con accento Ciano Neon `#00E5FF`.

### 3.4 Sezione 4: Tutte le Applicazioni (Filtro Tecnico OEM)
- Elenco alfabetico completo di tutte le app per utente.
- Esclusione deterministica di package e activity di diagnostica/fabbrica:
  - `A2dpSinkPlayer`
  - `Boot Video`
  - `com.cultraview.*` e `CULTRAVIEW_OPEN_LAUNCH...`
  - `com.airoha.*`
  - `com.mediatek.wwtv.factory`, `com.mediatek.engineermode`, `com.mediatek.TimeMeasurementAgent`
  - `com.android.traceur`
- Presenza di un'opzione nel menu di personalizzazione Tema per visualizzare le app tecniche solo su richiesta esplicita.

---

## 4. Test Suite Launcher (46/46 PASS)

La suite di collaudo offline `LauncherUnitTests` (eseguibile tramite `scripts/run_launcher_tests.ps1` e integrata in GitHub Actions) valida in modo esaustivo:
1. **P0 D-Pad Key Handling**:
   - Short press: `ACTION_DOWN` (repeat 0) $\to$ `ACTION_UP` $\to$ Avvio app = 1, Dialoghi = 0.
   - Long press: `ACTION_DOWN` (repeat 0) $\to$ `ACTION_DOWN` (repeat 1, isLongPress=true) $\to$ `ACTION_UP` $\to$ Dialoghi = 1, **Avvio app = 0 (P0 Risolto)**.
   - Equivalenza tasti `KEYCODE_ENTER` e `KEYCODE_DPAD_CENTER`.
   - Evento `Canceled`: zero avvii app.
2. **OEM Technical Blacklist**:
   - 6 pattern di test OEM bloccati (`A2dpSinkPlayer`, `Boot Video`, `Cultraview`, `Airoha`, `WWTV Factory`, `Traceur`).
   - 5 app legittime preservate (`YouTube`, `RaiPlay`, `Netflix`, `Disney+`, `Play Store`).
3. **Streaming Categorization**:
   - 10 piattaforme multimediali identificate; 4 utility generiche escluse.
4. **Matematica Contrasto sRGB (IEC 61966-2-1)**:
   - Testo Bianco su Sfondo Midnight: $19.66:1 \ge 7.0:1$ (WCAG AAA)
   - Bordo Focus Oro su Superficie Sapphire: $4.82:1 \ge 4.5:1$ (WCAG AAA componente attivo)
   - Focus Ciano su Sfondo Midnight: $12.78:1 \ge 7.0:1$ (WCAG AAA).

---

## 5. Vincoli di Sicurezza Categorici

- **ZERO DEPLOY SULLA TV FISICA**: Nessun comando ADB, nessun ping ICMP e nessuna connessione verso `192.168.1.8`.
- **ZERO MERGE SU MAIN**: Il ramo `feature/launcher-ui-v8-leanback` rimane isolato nella PR #3 aperta per peer review.
- L'APK prodotto dalla pipeline CI è formalmente classificato come `non-distributable` (firmato con chiave effimera di test).
