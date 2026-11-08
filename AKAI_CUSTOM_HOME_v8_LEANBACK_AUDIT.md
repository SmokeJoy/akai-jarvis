# AKAI Custom Home v8 — Specifiche Architetturali, Layout Leanback e Audit Visivo

## 1. Visione e Obiettivi del Redesign

La versione precedente del launcher (`it.akai.customhome` v7), pur garantendo stabilità ed accesso diretto agli ingressi fisici e alle app, presentava limiti evidenti di usabilità tipici dell'adattamento di una griglia generica su un display televisivo:
- **Testi e didascalie troppo piccoli** (10–12sp), difficilmente leggibili dal divano a 3–4 metri di distanza.
- **Griglia fissa a 6 colonne**, con scarso respiro visivo e navigazione D-Pad affollata.
- **Inquinamento visivo da utility tecniche OEM** (`A2dpSinkPlayer`, `Boot Video`, `CULTRAVIEW_OPEN_LAUNCH...`), prive di valore d'uso quotidiano per l'utente finale.
- **Mancanza di categorizzazione streaming**, disperdendo app di intrattenimento (RaiPlay, Netflix, Prime Video, Disney+, YouTube) in un elenco alfabetico generico.

La nuova architettura **v8 Leanback** adotta le linee guida canoniche di Google Android TV per interfacce a 10 piedi (10-Foot UI), riorganizzando i contenuti in **quattro righe orizzontali tematiche**, con tipografia maggiorata (&ge; 14sp), focus ad altissimo contrasto (WCAG AAA 13.3:1) e zoom leggero (1.08x) su D-Pad.

---

## 2. Matrice di Risoluzione Rilievi (v7 vs v8)

| Area di Rilievo | Situazione v7 (Legacy) | Implementazione v8 (Leanback) | Esito Tecnico |
| :--- | :--- | :--- | :--- |
| **Tipografia & Leggibilità** | Didascalie a 10sp, label a 12sp | Didascalie a **14sp**, titoli sezioni a **15-16sp bold**, label card a **14sp bold** | **Risolto (Leggibilità ottimale a 4 metri)** |
| **Struttura Layout** | Griglia unica a 6 colonne verticali | **4 Righe Orizzontali Tematiche** in `ScrollView` fluido | **Risolto (Navigazione Leanback naturale)** |
| **App Tecniche OEM** | Presenti nella Home (`A2dpSinkPlayer`, `Boot Video`, `Cultraview`) | **Filtro / Blacklist Intelligente** automatica con toggle nelle impostazioni | **Risolto (Interfaccia pulita e professionale)** |
| **Categorizzazione Streaming** | Nessuna (tutto confuso in All Apps) | **Sezione dedicata STREAMING & CINEMA** con keyword matching | **Risolto (Accesso immediato all'intrattenimento)** |
| **Focus D-Pad & Contrasto** | Bordo statico sottile, ratio non verificato | Bordo **3.5dp**, contrasto **13.3:1 (WCAG AAA)** e animazione **1.08x** | **Risolto (Tracciabilità cursore immediata)** |
| **Privacy Dati LAN** | Fallback hardcoded `192.168.1.8` | Fallback sanitizzato dinamico `""` / `"Wi-Fi Connesso"` | **Risolto (Zero leak di IP locali)** |
| **Hardware Freeze** | Rischio di installazione accidentale | Sviluppo su ramo isolato `feature/launcher-ui-v8-leanback`, **zero comandi ADB** | **Risolto (Zero interferenza TV)** |

---

## 3. Architettura delle Sezioni v8

```
+---------------------------------------------------------------------------------------------------+
|  [AKAI] CUSTOM HOME v8 LEANBACK     [📶 Wi-Fi]  [📱 Associa iPhone]  [🎨 Tema]  [⚙️ Setup]   12:45 |
+---------------------------------------------------------------------------------------------------+
|  INGRESSI HARDWARE (15sp bold)                                                                    |
|  [ 📺 TV Digitale ]*   [ 🎮 Fire TV (HDMI 1) ]   [ 🎬 HDMI 2 ]   [ 💻 HDMI 3 ]   [ 🔌 Menu Ingr ]  |
+---------------------------------------------------------------------------------------------------+
|  APP PREFERITE (15sp bold) · (Tieni premuto OK per riordinare o rimuovere)                        |
|  [ ▶️ YouTube TV ]*    [ 📡 RaiPlay ]    [ 🍿 Netflix ]    [ 📺 Infinity+ ]    [ 🏰 Disney+ ]     |
+---------------------------------------------------------------------------------------------------+
|  STREAMING & CINEMA (15sp bold) · (Piattaforme video e multimediali)                              |
|  [ 📦 Prime Video ]*   [ 📡 RaiPlay ]    [ 🍿 Netflix ]    [ ▶️ YouTube TV ]   [ 🎧 Spotify ]     |
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
- Card orizzontali ad ampia superficie (175dp &times; 110dp).
- Possibilità di aggiungere, rimuovere e riordinare a piacimento le app tramite D-Pad (OK prolungato).
- Aggiornamento reattivo senza ricaricamento dell'Activity.

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

## 4. Specifiche Tecniche del Codice

- **Package**: `it.akai.customhome`
- **Activity**: `MainActivity.java`
- **Target SDK**: Android 9 (API 28), Min SDK: Android 5.0 (API 21)
- **Dipendenze Esterne**: `0` (Zero librerie di terze parti, zero SDK proprietari, zero cloud).
- **Animazioni**: GPU-accelerated via `View.animate().scaleX(1.08f).scaleY(1.08f)` a durata 120ms, con consumo trascurabile di RAM e CPU, ideale per il SoC MT5867 quad-core con 1.5 GB di RAM.
- **File di Risorsa Aggiunti/Modificati**:
  - `res/layout/activity_main.xml`: Struttura a 4 righe in `ScrollView` verticale con `HorizontalScrollView` indipendenti.
  - `res/layout/item_leanback_card.xml`: Card standardizzata 175dp &times; 110dp con label a 14sp bold.
  - `res/drawable/card_focus_selector.xml`: Bordo dorato/ciano 3.5dp con angoli arrotondati 14dp.
  - `res/drawable/source_chip_selector.xml`: Bordo ciano 3.5dp ad alto contrasto per le sorgenti fisiche.
  - `res/values/strings.xml`: Stringhe localizzate v8 Leanback con didascalie descrittive.
  - `res/values/colors.xml`: Palette contrasto sRGB conforme a WCAG AAA.

---

## 5. Artefatti Visivi Generati per la Revisione

1. **`AKAI_CUSTOM_HOME_v8_LEANBACK_COMPARAZIONE.html`**:
   Dashboard interattiva con selettore di vista dinamico (v8 Leanback, Confronto Analitico, v7 Legacy).
2. **`AKAI_CUSTOM_HOME_v8_anteprima_leanback.png`**:
   Render fedele ad alta risoluzione del nuovo layout a righe sulla TV.
3. **`AKAI_CUSTOM_HOME_v8_comparazione_prima_dopo.png`**:
   Infografica comparativa tecnica con evidenza delle migliorie grafiche e prestazionali.
