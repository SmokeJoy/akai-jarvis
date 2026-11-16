# Checkpoint Tecnico — Riscontro ad Ottava Revisione PR #3 (Design Premium Cinematico, Catalog Streaming & Rollback OEM)

**Data**: 08 Novembre 2026  
**Autore**: Antigravity  
**PR Riferimento**: [#3 — AKAI Custom Home v8 Leanback UI](https://github.com/SmokeJoy/akai-jarvis/pull/3)  
**Commit Principale**: `a8f865c`  
**Stato CI**: PASS (Build Standalone Android API 28 + 113/113 Java Unit Tests + 7/7 ADB Fail-Closed Isolation Tests)  
**Stato TV Fisica (`192.168.1.8`)**: 🔒 **HARDWARE FREEZE TOTALE** (Zero comandi ADB, zero socket aperte, zero ping)  
**Politica Ramo**: Nessun merge su `main`. Il lavoro rimane isolato e verificabile su `feature/launcher-ui-v8-leanback`.

---

## 1. Trasformazione Grafica Premium — Implementazione del Target Concept

In risposta alla richiesta dell'utente e all'ottava revisione tecnica, abbiamo dismesso il layout essenziale e implementato fedelmente l'interfaccia premium indicata nell'immagine di riferimento approvata (`docs/design/akai_premium_target_concept.jpg`):

1. **Sfondo Cinematico Dark Navy / Ambra (`bg_cinematic_gradient.xml`)**:
   - Gradiente vettoriale fluido a 135° da blu scuro notte profondo (`#0D111A`) verso sfumature calde ambra/arancio (`#1A1520` e `#2A1810`), riproducendo l'atmosfera teatrale da cinema e valorizzando i pannelli TV 4K/HDR.
2. **Barra di Navigazione Verticale a Sinistra (Sidebar Leanback)**:
   - Sidebar compatta laterale a 5 sezioni con pill circolari animate:
     - ⌂ **Home** (attiva di default con alone dorato)
     - 🎬 **Film & Serie**
     - 㗊 **App**
     - 📺 **Live TV**
     - ⚙️ **Impostazioni**
   - Navigazione D-Pad bi-direzionale collaudata: con `DPAD_LEFT` il focus passa dalla griglia alla sidebar; con `DPAD_RIGHT` ritorna alla riga attiva; la pressione di `DPAD_CENTER` esegue lo scorrimento fluido (`smoothScrollTo`) direttamente alla sezione selezionata.
3. **Top Bar Header Snella con Pill Glassmorfiche**:
   - Chip in vetro scuro semi-trasparente ad alto contrasto:
     - `📶 Wi-Fi Connesso` con indicatore di stato dinamico a led verde (`#4CAF50`).
     - `📱 Associa iPhone` per apertura rapida del wizard di pairing.
     - `🎨 Tema` per selezione istantanea della palette visiva.
     - `🖥️ Impostazioni TV` per l'accesso immediato alle opzioni Android di fabbrica.
     - Orologio digitale in tempo reale ad alta leggibilità.
4. **Marcatori di Sezione Ambra e Card Tessere Arrotondate**:
   - Titoli delle 4 sezioni principali arricchiti da un'elegante barra d'accento ambra verticale `|` (`#FFA000`):
     - `| Ingressi Hardware` (TV Digitale, Fire TV, HDMI 2, HDMI 3, Menu Ingressi)
     - `| App Preferite` (griglia personalizzabile ad accesso istantaneo)
     - `| Streaming & Cinema` (carosello orizzontale scrollabile)
     - `| Tutte le Applicazioni` (catalogo completo sanificato)
   - Tessere con raggio d'angolo a 16dp, elevazione materiale e cornice di focus dorata ad altissima visibilità (`#FFB300`), conforme WCAG AAA.
5. **Eliminazione Radicale dei Menu Grigi Android Stock (`Theme.Akai.Dialog`)**:
   - Tutti i dialoghi modali (`AlertDialog.Builder`) sono stati integrati nello stile dark glass (`dialog_dark_glass_bg.xml` con contorno sottile `#33FFFFFF` e sfondo `#E6101522`), sostituendo integralmente i popup grigi di sistema con un'estetica moderna e coerente.

---

## 2. Risoluzione Dataset Streaming Multi-Package (Rilievo 1 Review 8)

Nel precedente ciclo di test, lo scorrimento della riga streaming era limitato a poche tessere perché lo script di mock impacchettava più activity dentro un singolo APK, innescando la deduplicazione nativa per package name di `loadInstalledApps()`.

**Correzione effettuata in `scripts/build_test_streaming_apps_apk.ps1`**:
- Lo script ora compila e firma **8 APK del tutto indipendenti** con package unici:
  - `test.tv.youtube` (YouTube TV)
  - `test.tv.netflix` (Netflix TV)
  - `test.tv.prime` (Prime Video TV)
  - `test.tv.raiplay` (RaiPlay TV)
  - `test.tv.disney` (Disney+ TV)
  - `test.tv.infinity` (Mediaset Infinity TV)
  - `test.tv.vlc` (VLC Media Player)
  - `test.tv.kodi` (Kodi Home Theater)
- Installando gli 8 pacchetti sull'emulatore Android TV 9, il catalogo si è popolato interamente, consentendo la verifica visiva a 1080p dello scorrimento orizzontale fluido con telecomando D-Pad.

---

## 3. Trasparenza Architetturale su Rollback e Firma Release (Rilievo 2 Review 8)

Accogliamo pienamente il rilievo metodologico: in ambienti embedded e TV Android non esistono rollback "automatici garantiti", ma unicamente percorsi di ripristino verificabili dal punto di vista dell'architettura del sistema operativo:

1. **Permanenza del Launcher di Fabbrica OEM**:
   - Il launcher originale (`cn.cultraview.launcher.technical.open`) risiede nella partizione read-only `/system/app/TvLauncher_Cetus_1_A/TvLauncher_Cetus_1_A.apk`.
   - L'APK `akai-custom-home.apk` (`it.akai.customhome`) viene installato rigorosamente nella partizione dati utente `/data/app/`.
   - Pertanto, una disinstallazione di sicurezza (via `adb uninstall it.akai.customhome` o da `Impostazioni -> App -> Disinstalla`) non tocca minimamente il launcher di fabbrica, che viene ripristinato automaticamente dal sistema operativo al successivo evento HOME.
2. **Isolamento delle Firme e Aggiornamenti In-Place**:
   - Un'applicazione compilata con chiavi di debug (`tools/debug.keystore`) **non può sovrascrivere** in-place pacchetti firmati con chiavi release o OEM.
   - Prima di qualsiasi autorizzazione futura, qualunque build candidata dovrà essere firmata con un keystore dedicato e protetto, senza mai tentare la sovrascrittura forzata di package di sistema.

---

## 4. Evidenze Runtime 1080p da Emulatore Android TV 9

Il collaudo runtime completo è stato rieseguito con `scripts/10_android_tv_emulator_smoke_test.ps1` sul target `emulator-5554` (Android 9 API 28) con 8 APK streaming indipendenti installati. Le schermate ad alta risoluzione sono archiviate nel repository in `docs/screenshots/emulator/`:

| Evidenza | Descrizione Operativa |
| :--- | :--- |
| `01_home_screen_clean.png` | Schermata Home completa: sidebar attiva a sinistra, top bar glass, 4 righe con accento ambra e sfondo cinematico fluido. |
| `02_sidebar_navigation_focus.png` | Navigazione D-Pad bi-direzionale con focus attivo sulla sidebar laterale. |
| `03_streaming_horizontal_scroll.png` | Scorrimento orizzontale reale nella riga Streaming tra gli 8 package indipendenti con focus dorato su *Disney+*. |
| `04_app_options_dialog.png` | Menu contestuale (pressione prolungata OK) renderizzato nel nuovo tema dark glassmorphic `Theme.Akai.Dialog`. |
| `05_favorites_row_populated.png` | Riga Preferiti popolata e salvata con persistenza verificata. |
| `06_theme_customization_dialog.png` | Finestra di dialogo selezione tema in vetro scuro. |
| `07_home_key_focus_retention.png` | Ripristino deterministico del focus dopo pressione del tasto HOME. |

---

## 5. Sintesi della Verifica Tecnica

- **Test Unitari Java**: **113 / 113 SUPERATI** (100% pass)
  - Pressione breve vs prolungata OK con soppressione del keyUp su long press.
  - Reset deterministico dello stato su perdita focus (`onFocusChange`).
  - Preservazione app tecniche OEM nei Preferiti durante cambio filtri e riordino sicuro.
  - Diffing simmetrico di metadati, icone e timestamp di aggiornamento per refresh non distruttivo.
  - Contrasto WCAG AAA confermato matematicamente (>19.6:1 per testo bianco su navy).
- **Test Isolamento ADB (`scripts/11_test_emulator_smoke_script_isolation.ps1`)**: **7 / 7 SUPERATI**
  - Blocco deterministico fail-closed in caso di presenza della sola TV fisica (`192.168.1.8`), target misti, dispositivi offline o sconosciuti.
- **CI GitHub Actions**: **PASS** (compilazione nativa con toolchain Android SDK API 28).

Tutti i requisiti della Revisione 8 risultano completati e collaudati su emulatore. Restiamo a disposizione per la successiva valutazione senza intaccare l'hardware freeze della TV.
