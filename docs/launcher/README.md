# AUDIT VISIVO E DOCUMENTAZIONE INTERFACCIA AKAI CUSTOM HOME v8

> **Branch:** `docs/launcher-visual-audit`  
> **Pacchetto:** `it.akai.customhome`  
> **Contesto:** Audit visivo indipendente condotto da ChatGPT su richiesta del proprietario del progetto.  
> **Stato TV Fisica:** **HARDWARE FREEZE TOTALE RISPETTATO** (nessuna connessione, comando ADB o alterazione hardware eseguita).

---

## 1. Premessa e Metodologia dell'Audit

Il presente documento raccoglie e documenta sistematicamente le evidenze visive relative al launcher **AKAI Custom Home v8** (`it.akai.customhome`).  
Questa iniziativa è mantenuta rigorosamente **separata** dai lavori di correzione backend e sicurezza in corso sulla Pull Request #1.

### Vincoli Operativi Applicati
1. **Zero modifiche al codice**: Nessun file XML di layout (`activity_main.xml`, `item_app_card.xml`, ecc.) né file Java (`MainActivity.java`) è stato modificato in questa fase.
2. **Zero comandi hardware (Freeze)**: Nessuna acquisizione runtime (`screencap`) è stata effettuata sul televisore fisico durante questo audit.
3. **Provenienza delle Catture**: Tutte le schermate fornite provengono da catture reali autentiche (risoluzione nativa 1920×1080 pixel) effettuate sulla TV fisica AKAI (Android 9 Pie, display Full HD) durante le sessioni di collaudo pre-freeze e archiviate nel repository al commit di baseline `ea2f35e`.
4. **Sanificazione Privacy**: Ogni riferimento a identificativi di rete (SSID Wi-Fi) o indirizzi IP privati LAN (`192.168.1.8`) visualizzati dinamicamente nel pulsante di stato di rete è stato preventivamente sanificato con etichetta generica `📶 Wi-Fi (Connesso)`. Zero token, PIN o dati sensibili presenti nelle immagini.

---

## 2. Registro delle Evidenze Visive Raccolte

Le catture ad alta risoluzione sono archiviate nella directory [`docs/launcher/screenshots/`](file:///c:/Users/danie/OneDrive/Documenti/Antygravity/Akay/docs/launcher/screenshots):

| File Screenshot | Categoria / Descrizione | Risoluzione | Fonte | Versione / Baseline | Data Acquisizione | Sanificazione Privacy |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: |
| [`01_home_1080p_complete.png`](screenshots/01_home_1080p_complete.png) | **Schermata Home 1080p Completa**: Header bar, Ingressi DTV/HDMI, Preferiti e Griglia Tutte le App | 1920×1080 | TV Reale AKAI | Custom Home v8 (`ea2f35e`) | 2026-11-07 17:48 | Sanificato pulsante rete |
| [`01b_home_1080p_clean_baseline.png`](screenshots/01b_home_1080p_clean_baseline.png) | **Home Pulita Baseline**: Vista standard senza popup né dialoghi attivi | 1920×1080 | TV Reale AKAI | Custom Home v8 (`ea2f35e`) | 2026-11-06 02:47 | Nativa senza dati sensibili |
| [`02_dpad_focus_app_card.png`](screenshots/02_dpad_focus_app_card.png) | **Focus D-pad su Scheda App**: Evidenziazione bordo ciano `#00E5FF`, background attivo e contrasto su RaiPlay | 1920×1080 | TV Reale AKAI | Custom Home v8 (`ea2f35e`) | 2026-11-07 17:17 | Sanificato pulsante rete |
| [`02b_dpad_focus_navigation.png`](screenshots/02b_dpad_focus_navigation.png) | **Navigazione D-pad Sezioni**: Transizione focus telecomando tra Ingressi, Preferiti e Griglia | 1920×1080 | TV Reale AKAI | Custom Home v8 (`ea2f35e`) | 2026-11-07 17:18 | Sanificato pulsante rete |
| [`03_theme_customization_palette.png`](screenshots/03_theme_customization_palette.png) | **Personalizzazione Tema**: Palette alternativa applicata e inversione ordine (Preferiti prima di Ingressi) | 1920×1080 | TV Reale AKAI | Custom Home v8 (`ea2f35e`) | 2026-11-06 02:51 | Nativa senza dati sensibili |
| [`03b_dialog_theme_options.png`](screenshots/03b_dialog_theme_options.png) | **Dialogo Opzioni Tema**: Modale di selezione Palette Sfondo, Colore Accento e Ordine Sezioni | 1520×780 (crop) | TV Reale AKAI | Custom Home v8 (`ea2f35e`) | 2026-11-06 02:46 | Dialogo di sistema Material |
| [`04_apps_grid_scrolled_overflow.png`](screenshots/04_apps_grid_scrolled_overflow.png) | **Griglia Affollata con Scorrimento**: Più di 20 app installate su 6 colonne fisse in scorrimento verticale | 1920×1080 | TV Reale AKAI | Custom Home v8 (`ea2f35e`) | 2026-11-06 02:39 | Nativa senza dati sensibili |
| [`04b_apps_grid_full_overview.png`](screenshots/04b_apps_grid_full_overview.png) | **Panoramica Griglia Applicazioni**: Allineamento iniziale colonne, etichette su due righe e icone 48dp | 1920×1080 | TV Reale AKAI | Custom Home v8 (`ea2f35e`) | 2026-11-06 02:38 | Nativa senza dati sensibili |
| [`05_dialog_favorites_reorder.png`](screenshots/05_dialog_favorites_reorder.png) | **Dialogo Gestione Preferiti**: AlertDialog per riordinare ("Sposta a SX/DX") o rimuovere l'app | 1000×880 (crop) | TV Reale AKAI | Custom Home v8 (`ea2f35e`) | 2026-11-06 02:44 | Dialogo di sistema Material |
| [`05b_home_after_app_return.png`](screenshots/05b_home_after_app_return.png) | **Ritorno da App via HOME**: Rendering istantaneo del launcher dopo uscita da player streaming | 1920×1080 | TV Reale AKAI | Custom Home v8 (`ea2f35e`) | 2026-11-07 17:48 | Sanificato pulsante rete |

---

## 3. Analisi Tecnica e Visiva dei Quattro Aspetti Richiesti

### 3.1. Leggibilità e Dimensioni Tipografiche (10–12 sp)
Dall'esame combinato delle schermate 1080p e dei file XML di risorsa (`activity_main.xml`, `item_app_card.xml`, `item_fav_card.xml`):

1. **Titoli di Sezione (`11sp`)**:
   - Elementi: `tv_title_inputs`, `tv_title_favorites`, `tv_title_all_apps`.
   - Proprietà: `android:textSize="11sp"`, `android:textStyle="bold"`, `android:letterSpacing="0.08"`, colori `#94A3B8` (grigio) e `#F59E0B` (oro preferiti).
   - *Riscontro visivo*: L'uso del grassetto e del maiuscolo spaziato compensa parzialmente la dimensione ridotta, ma a distanza tipica TV (2.5 – 3.5 metri) la leggibilità risulta critica per schermi inferiori a 43".
2. **Testi di Aiuto / Suggerimenti (`10sp`)**:
   - Elementi: `(Tieni premuto OK per riordinare o rimuovere)` e `hint_fav_help`.
   - Proprietà: `android:textSize="10sp"`, colore `#64748B` (`text_muted`).
   - *Riscontro visivo*: Il contrasto tra `#64748B` e lo sfondo scuro `#0A0B10` è sub-ottimale (~3.2:1, inferiore al ratio WCAG AA di 4.5:1 per testi piccoli). Da divano il testo risulta praticamente illeggibile.
3. **Etichette delle Applicazioni (`12sp`) e Icone (`48dp`)**:
   - Elementi: `item_app_card.xml` e `item_fav_card.xml`.
   - Proprietà: `android:textSize="12sp"`, `android:maxLines="2"`, `android:ellipsize="end"`, icona `48dp × 48dp`.
   - *Riscontro visivo*: I titoli brevi (es. "YouTube", "Netflix", "RaiPlay") sono nitidi. Titoli composti da tre parole (es. "Impostazioni avanzate TV") vengono spezzati o troncati. L'icona da 48dp appare proporzionata ma potrebbe beneficiare di una dimensione di 56–64dp per standard TV Leanback.
4. **Header e Orologio**:
   - Badge AKAI `20sp` bold con sfondo rosso `#E50914`, brand `17sp`, orologio `TextClock` a `24sp` bold.
   - *Riscontro visivo*: L'orologio e il logo AKAI godono di eccellente visibilità e contrasto da qualsiasi distanza.

---

### 3.2. Organizzazione del Layout e Griglia a 6 Colonne Fisse
Dall'analisi delle schermate [`04_apps_grid_scrolled_overflow.png`](screenshots/04_apps_grid_scrolled_overflow.png) e [`04b_apps_grid_full_overview.png`](screenshots/04b_apps_grid_full_overview.png):

1. **Larghezza Utile e Spaziatura**:
   - Schermo: 1920dp width; padding laterale `44dp` per lato $\rightarrow$ larghezza interna disponibile: **1832dp**.
   - Con `numColumns="6"` e spacing `10dp` (5 intervalli = 50dp), ciascuna colonna occupa circa **297dp**.
2. **Dimensioni delle Schede (`110dp` altezza)**:
   - Ogni scheda app ha larghezza ~297dp e altezza fissa di 110dp.
   - Il layout interno (`item_app_card.xml`) dispone icona e testo in verticale (`padding="8dp"`). Con un'icona da 48dp + margini di 6dp, restano circa 40dp per il contenitore di testo, sufficienti per 2 righe a 12sp.
3. **Adattamento con Molte Applicazioni**:
   - Lo scorrimento verticale è fluido e gestito nativamente da `GridView`. Quando le app superano le 12 unità (2 righe), la griglia scorre sotto la sezione Preferiti mantenendo visibili le sezioni superiori.
4. **Comportamento Sezione Preferiti Vuota**:
   - Da `MainActivity.java` (righe 250–265): quando l'utente rimuove tutte le app dai Preferiti (`favoriteApps.isEmpty()`), il codice imposta:
     ```java
     layoutFavHeader.setVisibility(View.GONE);
     llFavContainer.setVisibility(View.GONE);
     ```
   - In questo stato, l'intera sezione `APP PREFERITE` collassa a 0dp di altezza senza lasciare buchi visivi, e la griglia `TUTTE LE APPLICAZIONI` si espande verticalmente occupando lo spazio rimanente.

---

### 3.3. Navigazione D-pad e Contrasto del Focus
Dall'analisi delle schermate [`02_dpad_focus_app_card.png`](screenshots/02_dpad_focus_app_card.png) e [`02b_dpad_focus_navigation.png`](screenshots/02b_dpad_focus_navigation.png):

1. **Stile di Selezione (`card_focus_selector.xml`, `source_chip_selector.xml`)**:
   - **Stato Normale**: Background `#1A202E` (card) / `#1E293B` (chip), nessun bordo.
   - **Stato con Focus D-pad**: Background `#2A364F`, bordo ciano neon `#00E5FF` (spessore 2dp) o oro `#F59E0B` per i preferiti.
2. **Animazione e Scala Ottica**:
   - `MainActivity.java` applica un listener `OnFocusChangeListener` con scaling hardware:
     ```java
     v.animate().scaleX(1.08f).scaleY(1.08f).setDuration(150).start();
     ```
   - L'effetto combinato di ingrandimento 1.08x, bordo fluorescente `#00E5FF` e background schiarito rende inequivocabile la posizione del cursore del telecomando.
3. **Pulsanti Ingressi Hardware**:
   - Chip orizzontali ad accesso rapido (`150dp` TV Digitale, `180dp` Fire TV HDMI 1, `130dp` HDMI 2/3, `145dp` Menu Ingressi).
   - Quando selezionati, il chip passa da blu scuro `#1E293B` a blu brillante `#0284C7` con testo bianco.

---

### 3.4. Personalizzazione, Palette di Sfondo e Ordine delle Sezioni
Dall'analisi di `MainActivity.java` e della schermata [`03_theme_customization_palette.png`](screenshots/03_theme_customization_palette.png):

1. **Palette di Sfondo Disponibili**:
   - Indice 0: `Midnight Dark` (`#0A0B10`) — Default profondo
   - Indice 1: `Deep Navy Blue` (`#081225`) — Tonalità blu notte
   - Indice 2: `Carbon Slate` (`#0F172A`) — Grigio ardesia scuro
   - Indice 3: `Pure OLED Black` (`#000000`) — Nero assoluto a consumo zero
   - Indice 4: `Ruby Dark` (`#18080C`) — Accento scuro rosso/bordeaux
2. **Colori d'Accento**:
   - `Oro AKAI` (`#F59E0B`)
   - `Ciano Neon` (`#00E5FF`)
   - `Rosso AKAI` (`#E50914`)
   - `Smeraldo` (`#10B981`)
3. **Inversione Ordine Sezioni (`theme_layout_order`)**:
   - Opzione 0: `Ingressi Hardware prima, Preferiti poi` (default per uso televisivo).
   - Opzione 1: `Preferiti prima, Ingressi Hardware poi` (ottimizzato per uso app streaming).
   - La schermata `03_theme_customization_palette.png` illustra l'ordine invertito in cui la barra dei Preferiti compare immediatamente sotto l'header bar.
4. **Persistenza**:
   - Tutte le selezioni (palette, accento, ordine sezioni, lista ordinata preferiti) sono serializzate in `SharedPreferences` (`akai_custom_home_prefs`) e ripristinate fedelmente a ogni riavvio dell'applicazione.

---

### 3.5. Chiarimento Discrepanza Versione (`CUSTOM HOME v7` vs v8)
Nel file `strings.xml` (riga 5):
```xml
<string name="brand_custom_tv">CUSTOM HOME v7</string>
```
Mentre il package, il manifest e il piano di progetto fanno riferimento ad **AKAI Custom Home v8**.
- **Accertamento da codice**: La dicitura `v7` è un refuso letterale nella risorsa stringa non aggiornata durante l'incremento di versione del codice v8 (che ha introdotto le palette dinamiche e il riordino preferiti).
- L'allineamento a `CUSTOM HOME v8` è puramente nominale e potrà essere eseguito contestualmente alle ottimizzazioni tipografiche approvate dalla review.

---

## 4. Riepilogo per la Revisione Indipendente

Tutte le 10 evidenze visive richieste sono archiviate e pronte per l'esame di ChatGPT.
Nessun intervento è stato effettuato sul firmware né sul televisore fisico.

La PR per questo audit visivo è disponibile su:  
**Branch:** `docs/launcher-visual-audit`
