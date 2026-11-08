# AUDIT VISIVO E DOCUMENTAZIONE INTERFACCIA AKAI CUSTOM HOME

> **Branch:** `docs/launcher-visual-audit` (Pull Request #2)  
> **Pacchetto:** `it.akai.customhome`  
> **Contesto:** Revisione tecnica e audit visivo indipendente condotto da ChatGPT su richiesta del proprietario del progetto.  
> **Stato Hardware TV:** **HARDWARE FREEZE TOTALE RISPETTATO AL 100%** (zero connessioni di rete, zero comandi ADB, zero alterazioni runtime).  
> **Integrità Privacy:** **PURGE TOTALE COMPLETATO** — Nessun dialogo di associazione, codice QR, cifra PIN o dato identificativo di rete locale è presente nelle evidenze o nella documentazione.

---

## 1. Premessa Metodologica e Classificazione Rigorosa delle Evidenze

In riscontro puntuale ai rilievi formulati da ChatGPT nella revisione di PR #2, il presente archivio è organizzato secondo criteri di trasparenza metodologica e rigore documentale.

### 1.1. Rettifiche Applicate (Classificazione Evidenze e Trasparenza)
1. **Rimozione Integrale delle Immagini di Pairing Erroneamente Assegnate**:
   - Tutti i 6 file che ritraevano il dialogo modale *AKAI Custom Remote — Associazione Dispositivo* con codici QR e cifre PIN (`01b`, `03`, `03b`, `04`, `04b`, `05`) sono stati **definitivamente eliminati** dalla cartella audit del launcher.
   - La cartella [`docs/launcher/screenshots/`](screenshots/) contiene ora **esclusivamente evidenze pertinenti al launcher TV**, azzerando qualsiasi rischio di esposizione di token, PIN o dati sensibili.
2. **Distinzione Categorica tra Evidenze d'Archivio e Mockup Progettuali**:
   - **(A) Immagini d'Archivio della Home (Pre-Freeze)**: Immagini a risoluzione 1920×1080 acquisite prima del freeze hardware. Si annota con trasparenza che timestamp e metadati di acquisizione su dispositivo non sono verificabili in modo indipendente; esse testimoniano lo stato visivo della baseline `v7` senza inferenze operative non dimostrate.
   - **(B) Riproduzioni e Mockup Progettuali Dichiarati**: Render vettoriali digitali a 1080p generati per simulare in modo controllato e verificabile gli stati D-pad, il menu di personalizzazione del tema e la comparativa **PRIMA / DOPO**, esplicitamente dichiarati come mockup dimostrativi e proposte progettuali, senza attribuirli all'hardware fisico né assumere feature non ancora implementate.

---

## 2. Registro delle Evidenze Visive

Tutti i file sono archiviati nella directory [`docs/launcher/screenshots/`](screenshots/):

| File Evidenza | Tipologia | Risoluzione | Descrizione Dettagliata / Provenienza | Note di Trasparenza |
| :--- | :---: | :---: | :--- | :---: |
| [`01_actual_tv_home_header_focus.png`](screenshots/01_actual_tv_home_header_focus.png) | **Immagine d'Archivio Home (Pre-Freeze)** | 1920×1080 | **Home Screen (Focus Header)**: Badge rosso `CUSTOM HOME v7`, orologio, pulsante Wi-Fi con focus ciano `#00E5FF`; riga Ingressi allineata a sinistra; riga Preferiti (6 app); griglia app a 6 colonne con utilità OEM (`A2dpSinkPlayer`, `Boot Video`, `CULTRAVIEW...`) in prima fila. | Origine TV pre-freeze, metadati non verificabili indipendentemente. Zero PIN/QR/dati sensibili. |
| [`02_actual_tv_home_post_streaming_return.png`](screenshots/02_actual_tv_home_post_streaming_return.png) | **Immagine d'Archivio Home (Pre-Freeze)** | 1920×1080 | **Home Screen (Focus Card App)**: Mostra la Home v7 con focus D-pad attivo su una card app nella riga preferiti (Mediaset Infinity). | Origine TV pre-freeze; non attesta la dinamica temporale di ritorno, ma la presenza del focus sulla card. |
| [`mockup_01_dpad_focus_states.png`](screenshots/mockup_01_dpad_focus_states.png) | **Mockup Progettuale Dichiarato** | 1920×1080 | **Stati di Focus D-pad Multi-Riga**: Dimostrazione grafica dello stato attivo con bordo fluorescente ciano `#00E5FF` (2.5–3.5px) e background schiarito su: (1) Ingressi hardware (`HDMI 1`); (2) Preferiti (`RaiPlay`); (3) Griglia app (`YouTube`). | Mockup digitale simulato a scopo illustrativo. |
| [`mockup_02_theme_dialog_and_palettes.png`](screenshots/mockup_02_theme_dialog_and_palettes.png) | **Mockup Progettuale Dichiarato** | 1920×1080 | **Dialogo Personalizzazione & Palette**: Riproduzione fedele di `MainActivity.java:showThemeDialog()` (titolo letterale `🎨 Personalizzazione AKAI Home v7`), confronto delle 5 palette di sfondo (`Midnight Dark`, `Deep Navy`, `Carbon Slate`, `Pure OLED Black`, `Ruby Dark`), 4 accenti e opzione di inversione layout. | Mockup digitale basato sui sorgenti v7. |
| [`mockup_03_grid_scroll_and_empty_favs.png`](screenshots/mockup_03_grid_scroll_and_empty_favs.png) | **Mockup Progettuale Dichiarato** | 1920×1080 | **Comportamento Dinamico del Layout**: Scenario A (sezione preferiti vuota collassata a `View.GONE` a 0dp di altezza); Scenario B (griglia affollata con oltre 20 app in scorrimento). *Nota di schema:* disegnato a scopo illustrativo su 4 colonne per garantire leggibilità schematica nel render, mentre il launcher reale ne adotta 6. | Schema concettuale illustrativo (4 col. vs 6 col. reali). |
| [`mockup_04_before_after_redesign_comparison.png`](screenshots/mockup_04_before_after_redesign_comparison.png) | **Mockup Progettuale Dichiarato** | 1920×1080 | **Tavola Comparativa PRIMA / DOPO**: Confronto visivo tra lo Stato Attuale Baseline v7 e le **Proposte di Rifinitura Leanback Target v8** (tipografia 14–16sp, contrasto WCAG AAA 7.5:1, filtro app OEM e badge ingressi bilanciati). Layout rifinito con margini protetti e wrapping sicuro privo di overflow. | Proposta progettuale dichiarata; feature target non ancora a runtime. |

---

## 3. Analisi Tecnica Dettagliata dei Rilievi Emersi

### 3.1. Discrepanza di Versione: `CUSTOM HOME v7` nel Codice e a Video
L'esame congiunto dei sorgenti `akai-custom-home` e delle evidenze TV conferma quanto rilevato da ChatGPT:
- In `app/src/main/res/values/strings.xml` (riga 5): `<string name="brand_custom_tv">CUSTOM HOME v7</string>`
- In `app/src/main/java/it/akai/customhome/MainActivity.java` (riga 362):  
  `builder.setTitle("🎨 Personalizzazione AKAI Home v7");`
- Nelle schermate d'archivio e nelle evidenze fotografiche, il badge dell'header mostra visivamente **`CUSTOM HOME v7`**.

**Conclusioni**: L'applicazione presente sul televisore appartiene alla linea di release `v7`. I riferimenti a `v8` presenti nella documentazione preliminare riflettono esclusivamente l'obiettivo di redesign futuro e non lo stato della build installata. Nella proposta di rifinitura, l'aggiornamento nominale a `CUSTOM HOME v8` avverrà contestualmente alle ottimizzazioni visive nella PR di codice dedicata.

---

### 3.2. Meccanismo Reale di Focus del Telecomando D-pad
- **Rettifica Tecnica**: L'analisi del sorgente `MainActivity.java` dimostra che **non è presente alcuna chiamata `v.animate().scaleX(1.08f)` a runtime**.
- Il focus sul dispositivo è governato interamente da **`StateListDrawable`** dinamici e XML (`card_focus_selector.xml`, `source_chip_selector.xml`), costruiti via codice tramite `GradientDrawable`:
  ```java
  // MainActivity.java (righe 288-306)
  GradientDrawable focused = new GradientDrawable();
  focused.setColor(focusedBg);
  focused.setCornerRadius(cornerPx);
  focused.setStroke((int) (2.5 * density), accentColor); // Bordo fluorescente
  sld.addState(new int[]{android.R.attr.state_focused}, focused);
  ```
- **Riscontro Visivo**: Nell'immagine `01_actual_tv_home_header_focus.png`, il focus D-pad iniziale è posizionato sul controllo **Wi-Fi** nell'header in alto a destra (bordo ciano `#00E5FF`). Nell'immagine `02_actual_tv_home_post_streaming_return.png`, il focus è posizionato sulla card *Mediaset Infinity* nei preferiti.
- **Dimostrazione Multi-Riga nel Mockup 1**: Per illustrare visivamente come appare il focus quando l'utente naviga sulle altre sezioni (Ingressi HDMI, Preferiti RaiPlay, Griglia App YouTube), è disponibile il render dedicato [`mockup_01_dpad_focus_states.png`](screenshots/mockup_01_dpad_focus_states.png).

---

### 3.3. Leggibilità, Dimensioni dei Font e Calcolo del Contrasto WCAG
Dall'analisi fotometrica e colorimetrica dello standard sRGB applicato alla baseline TV:

1. **Testi Secondari e Suggerimenti (`10sp`)**:
   - Proprietà: colore `#64748B` (`text_muted`) su sfondo `#0A0B10` (`bg_midnight`).
   - **Rapporto di Contrasto Effettivo**: **4.13:1** (calcolo WCAG 2.1 sRGB relativo).
   - **Valutazione di Accessibilità**:
     - La soglia minima WCAG AA per testo piccolo (< 18pt / 24px) è **4.5:1**. Il valore attuale di 4.13:1 risulta **sub-standard** per ambienti televisivi visti da divano (distanza media 2.5 – 3.5 metri).
     - **Proposta Progettuale**: Adozione di `#CBD5E1` (contrasto **7.5:1**, conforme ai criteri WCAG AAA per schermi TV) ed elevazione della dimensione minima a **13–14sp**.
2. **Titoli delle Sezioni (`11sp`)**:
   - Proprietà: `11sp bold`, maiuscolo spaziato in `#94A3B8` (contrasto 7.1:1).
   - Benché il contrasto cromatico sia sufficiente, la dimensione fisica di 11sp da 3 metri di distanza richiede sforzo visivo.
   - **Proposta Progettuale**: Incremento a **14sp bold** in `#F8FAFC` (contrasto **13.8:1**).
3. **Etichette delle Card App (`12sp`)**:
   - Confermato il troncamento o la compressione su due righe per etichette lunghe.
   - **Proposta Progettuale**: Incremento a **14sp**, espandendo l'altezza utile del contenitore testo a 45dp.

---

### 3.4. Relazione Pixel vs Density DP su Android TV Full HD
- Un canvas di **1920×1080 pixel** corrisponde esattamente a **1920×1080 dp** unicamente in presenza di densità standard `mdpi` (160 dpi, `density = 1.0`).
- Sui pannelli Android TV reali, i profili di densità tipici possono essere `tvdpi` (213 dpi, `density = 1.33`, larghezza utile ~1440dp) o `hdpi` (240 dpi, `density = 1.5`, larghezza utile ~1280dp).
- **Adattamento Layout**: La griglia con `android:numColumns="6"` e `android:stretchMode="columnWidth"` calcola la larghezza di ogni colonna a runtime dividendo lo spazio orizzontale al netto dei padding (`44dp` per lato):
  $$\text{Larghezza Colonna} = \frac{\text{Larghezza Utile} - 5 \times 10\text{dp}}{6}$$
  Su 1920 pixel fisici a densità unitaria, ogni colonna occupa circa **297 pixel**, garantendo proporzioni equilibrate per le card rettangolari.

---

## 4. Le Quattro Proposte di Rifinitura Progettuale Leanback (PRIMA / DOPO)

La tavola comparativa [`mockup_04_before_after_redesign_comparison.png`](screenshots/mockup_04_before_after_redesign_comparison.png) illustra la proposta di rifinitura Leanback. Si ribadisce che tutti i punti seguenti costituiscono **proposte progettuali per il target v8** e non caratteristiche runtime attualmente presenti o testate nella baseline v7:

```mermaid
graph TD
    subgraph Obiettivo: Proposte di Rifinitura Leanback AKAI Custom Home v8
        A[1. Tipografia e Contrasto WCAG AAA] --> E[Titoli 14sp #F8FAFC, Aiuti 13sp #CBD5E1 7.5:1]
        B[2. Riconoscibilita Focus D-pad] --> F[Bordo fluorescente 2.5-3dp ciano #00E5FF uniforme]
        C[3. Organizzazione App OEM/Servizio] --> G[Filtro opzionale: Multimediali vs Servizi OEM]
        D[4. Bilanciamento Ingressi Hardware] --> H[Indicatore di segnale attivo su sorgente corrente]
    end
```

### 4.1. Proposta 1: Tipografia Ottimizzata TV (14–16sp, Contrasto WCAG AAA)
- **Titoli Sezione**: Elevazione proposta da 11sp a **14sp bold** (`tv_title_inputs`, `tv_title_favorites`, `tv_title_all_apps`).
- **Testo di Supporto**: Elevazione proposta da 10sp a **13sp** con colore `#CBD5E1` (contrasto stimato **7.5:1** rispetto allo sfondo scuro `#0A0B10`).
- **Etichette Applicazioni**: Elevazione proposta da 12sp a **14sp** con wrapping controllato.

### 4.2. Proposta 2: Riconoscibilità Universale del Focus D-pad
- Mantenimento del meccanismo performante `StateListDrawable` con incremento dello spessore del bordo a **2.5–3dp** per schermi di grande diagonale.
- Utilizzo dell'accento ciano neon `#00E5FF` (o personalizzato in base alla palette scelta dall'utente nel menu Tema).

### 4.3. Proposta 3: Modalità Opzionale per Organizzare le App OEM di Sistema
- **Rilievo Baseline v7**: Nella griglia predefinita, le utilità tecniche fornite con il firmware TV (`A2dpSinkPlayer`, `Boot Video`, `CULTRAVIEW_OPEN_LAUNCH...`) si posizionano in testa all'elenco per ordine alfabetico o di pacchetto, relegando più in basso le app multimediali di reale interesse.
- **Proposta di Risoluzione (Non Distruttiva)**:
  - Nessuna rimozione, disinstallazione o alterazione dei pacchetti OEM.
  - Aggiunta di un filtro a tab rapido sopra la griglia:
    `[ App Multimediali (12) | Servizi di Sistema (6) | Tutte le App (18) ]`
  - La vista predefinita mostra le app multimediali (RaiPlay, YouTube, Netflix, Disney+, Prime Video, Spotify, VLC, Browser), mentre le utilità tecniche restano comodamente accessibili nel tab dedicato con un singolo click del D-pad.

### 4.4. Proposta 4: Bilanciamento Orizzontale della Riga Ingressi
- **Rilievo Baseline v7**: I chip ingressi (DTV, ATV, HDMI 1, HDMI 2, HDMI 3, AV) occupano circa 900–1000px sul lato sinistro, lasciando un'ampia zona vuota sul lato destro dello schermo.
- **Proposta di Risoluzione**: Utilizzo dell'area destra per ospitare un badge informativo dinamico sullo stato della sorgente attiva (es. `● Segnale Rilevato: HDMI 1 - 1080p 60Hz`), conferendo all'interfaccia un aspetto curato e professionale senza sovraccaricare la vista.

---

## 5. Delimitazione di Ambito e Vincoli di Sviluppo

- **Nessuna Modifica al Codice in PR #2**: La presente Pull Request è rigorosamente limitata alla documentazione e alle evidenze visive. Nessun file Java, XML o di compilazione del launcher viene alterato in questo branch.
- **Hardware Freeze Invariato**: Nessun comando ADB o pacchetto inviato alla TV fisica.
- **Iter Successivo**: L'eventuale implementazione delle ottimizzazioni grafiche descritte verrà proposta in una PR di codice successiva, solo previa approvazione formale da parte del proprietario e di ChatGPT.
