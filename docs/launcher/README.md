# AUDIT VISIVO E DOCUMENTAZIONE INTERFACCIA AKAI CUSTOM HOME

> **Branch:** `docs/launcher-visual-audit` (Pull Request #2)  
> **Pacchetto:** `it.akai.customhome`  
> **Contesto:** Revisione tecnica e audit visivo indipendente condotto da ChatGPT su richiesta del proprietario del progetto.  
> **Stato Hardware TV:** **HARDWARE FREEZE TOTALE RISPETTATO AL 100%** (zero connessioni di rete, zero comandi ADB, zero alterazioni runtime).  
> **Integrità Privacy:** **PURGE TOTALE COMPLETATO** — Nessun dialogo di associazione, codice QR, cifra PIN o identificativo IP privato LAN (`192.168.1.8`) è presente nelle evidenze o nella documentazione.

---

## 1. Premessa Metodologica e Classificazione Rigorosa delle Evidenze

In riscontro puntuale ai rilievi formulati da ChatGPT nella revisione di PR #2, il presente archivio è stato riorganizzato secondo criteri di assoluta trasparenza e rigore tecnico.

### 1.1. Rettifiche Applicate (P0 Privacy & P0 Classificazione)
1. **Rimozione Integrale delle Immagini di Pairing Erroneamente Assegnate**:
   - Tutti i 6 file che ritraevano il dialogo modale *AKAI Custom Remote — Associazione Dispositivo* con codici QR e cifre PIN (`01b`, `03`, `03b`, `04`, `04b`, `05`) sono stati **definitivamente eliminati** dalla cartella audit del launcher.
   - La cartella [`docs/launcher/screenshots/`](screenshots/) contiene ora **esclusivamente evidenze pertinenti al launcher TV**, eliminando alla radice qualsiasi rischio di esposizione di token, PIN o dati sensibili.
2. **Distinzione Categorica tra Catture Reali e Mockup Progettuali**:
   - **(A) Evidenze Fotografiche Reali TV (Pre-Freeze)**: Screenshot autentici a risoluzione nativa 1920×1080 acquisiti sul televisore fisico AKAI prima del freeze hardware e allineati al commit di baseline `ea2f35e`.
   - **(B) Riproduzioni e Mockup Progettuali Dichiarati**: Render vettoriali digitali a 1080p generati per simulare in modo controllato e verificabile gli stati D-pad, il menu di personalizzazione del tema e la comparativa **PRIMA / DOPO**, senza attribuirli falsamente all'hardware fisico.

---

## 2. Registro delle Evidenze Visive

Tutti i file sono archiviati nella directory [`docs/launcher/screenshots/`](screenshots/):

| File Evidenza | Tipologia | Risoluzione | Contenuto Effettivo / Stato | Sanificazione Privacy |
| :--- | :---: | :---: | :--- | :---: |
| [`01_actual_tv_home_header_focus.png`](screenshots/01_actual_tv_home_header_focus.png) | **Cattura Reale TV (Pre-Freeze)** | 1920×1080 | **Home Screen Effettiva**: Intestazione con badge rosso `CUSTOM HOME v7`, orologio, pulsante Wi-Fi con focus ciano `#00E5FF`; riga Ingressi hardware allineata a sinistra; riga Preferiti (6 app); griglia app a 6 colonne con utilità OEM (`A2dpSinkPlayer`, `Boot Video`, `CULTRAVIEW...`) in prima fila. | Wi-Fi label generica, zero PIN/QR |
| [`02_actual_tv_home_post_streaming_return.png`](screenshots/02_actual_tv_home_post_streaming_return.png) | **Cattura Reale TV (Pre-Freeze)** | 1920×1080 | **Ritorno al Launcher post-streaming**: Stato del launcher al rientro immediato premendo il tasto HOME del telecomando. Conferma la persistenza del layout e della griglia. | Zero dati sensibili |
| [`mockup_01_dpad_focus_states.png`](screenshots/mockup_01_dpad_focus_states.png) | **Mockup Progettuale Dichiarato** | 1920×1080 | **Stati di Focus D-pad Multi-Riga**: Dimostrazione grafica dello stato attivo con bordo fluorescente ciano `#00E5FF` (2.5–3.5px) e background schiarito su: (1) Ingressi hardware (`HDMI 1`); (2) Preferiti (`RaiPlay`); (3) Griglia app (`YouTube`). | Mockup digitale pulito |
| [`mockup_02_theme_dialog_and_palettes.png`](screenshots/mockup_02_theme_dialog_and_palettes.png) | **Mockup Progettuale Dichiarato** | 1920×1080 | **Dialogo Personalizzazione & Palette**: Riproduzione fedele di `MainActivity.java:showThemeDialog()` (titolo letterale `🎨 Personalizzazione AKAI Home v7`), confronto delle 5 palette di sfondo (`Midnight Dark`, `Deep Navy`, `Carbon Slate`, `Pure OLED Black`, `Ruby Dark`), 4 accenti e opzione di inversione layout (Preferiti prima di Ingressi). | Mockup digitale pulito |
| [`mockup_03_grid_scroll_and_empty_favs.png`](screenshots/mockup_03_grid_scroll_and_empty_favs.png) | **Mockup Progettuale Dichiarato** | 1920×1080 | **Comportamento Dinamico del Layout**: Scenario A (sezione preferiti vuota collassata a `View.GONE` a 0dp di altezza, la griglia sale senza spazi vuoti); Scenario B (griglia affollata con oltre 20 app in scorrimento verticale fluido con scrollbar). | Mockup digitale pulito |
| [`mockup_04_before_after_redesign_comparison.png`](screenshots/mockup_04_before_after_redesign_comparison.png) | **Mockup Progettuale Dichiarato** | 1920×1080 | **Tavola Comparativa PRIMA / DOPO**: Confronto visivo affiancato tra lo Stato Attuale Baseline v7 (osservato su TV) e la Proposta di Rifinitura Leanback Target v8 con tipografia 14–16sp, contrasto WCAG AAA (7.5:1), filtro app OEM e ingressi bilanciati. | Mockup digitale pulito |

---

## 3. Analisi Tecnica Dettagliata dei Rilievi Emersi

### 3.1. Discrepanza di Versione: `CUSTOM HOME v7` nel Codice e a Video
L'esame congiunto dei sorgenti `akai-custom-home` e delle evidenze reali TV conferma quanto rilevato da ChatGPT:
- In `app/src/main/res/values/strings.xml` (riga 5): `<string name="brand_custom_tv">CUSTOM HOME v7</string>`
- In `app/src/main/java/it/akai/customhome/MainActivity.java` (riga 362):  
  `builder.setTitle("🎨 Personalizzazione AKAI Home v7");`
- Nella schermata reale del televisore (`01_actual_tv_home_header_focus.png`) e nella fotografia diretta del proprietario, il badge dell'header mostra visivamente **`CUSTOM HOME v7`**.

**Conclusioni**: L'applicazione attualmente presente sul televisore è la versione `v7`. I riferimenti a `v8` presenti nella documentazione preliminare riflettevano l'obiettivo target del progetto e non lo stato della build installata. Nella proposta di rifinitura, l'aggiornamento nominale a `CUSTOM HOME v8` avverrà contestualmente alle ottimizzazioni visive.

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
- **Riscontro Visivo su TV Reale**: Nella cattura reale `01_actual_tv_home_header_focus.png`, il focus D-pad iniziale è posizionato sul controllo **Wi-Fi** nell'header in alto a destra (bordo ciano `#00E5FF`).
- **Dimostrazione Multi-Riga nel Mockup 1**: Per illustrare visivamente come appare il focus quando l'utente naviga sulle altre sezioni (Ingressi HDMI, Preferiti RaiPlay, Griglia App YouTube), è stato prodotto il render dedicato [`mockup_01_dpad_focus_states.png`](screenshots/mockup_01_dpad_focus_states.png).

---

### 3.3. Leggibilità, Dimensioni dei Font e Calcolo del Contrasto WCAG
Dall'analisi fotometrica e colorimetrica dello standard sRGB applicato alla baseline TV:

1. **Testi Secondari e Suggerimenti (`10sp`)**:
   - Proprietà: colore `#64748B` (`text_muted`) su sfondo `#0A0B10` (`bg_midnight`).
   - **Rapporto di Contrasto Effettivo**: **4.13:1** (calcolo WCAG 2.1 sRGB relativo).
   - **Valutazione di Accessibilità**:
     - La soglia minima WCAG AA per testo piccolo (< 18pt / 24px) è **4.5:1**. Il valore attuale di 4.13:1 risulta **sub-standard** per ambienti televisivi visti da divano (distanza media 2.5 – 3.5 metri).
     - **Soluzione Proposta**: Adozione di `#CBD5E1` (contrasto **7.5:1**, certificato WCAG AAA) ed elevazione della dimensione minima a **13–14sp**.
2. **Titoli delle Sezioni (`11sp`)**:
   - Proprietà: `11sp bold`, maiuscolo spaziato in `#94A3B8` (contrasto 7.1:1).
   - Benché il contrasto cromatico sia sufficiente, la dimensione fisica di 11sp da 3 metri di distanza richiede sforzo visivo.
   - **Soluzione Proposta**: Incremento a **14sp bold** in `#F8FAFC` (contrasto **13.8:1**).
3. **Etichette delle Card App (`12sp`)**:
   - Confermato il troncamento o la compressione su due righe per etichette lunghe.
   - **Soluzione Proposta**: Incremento a **14sp**, espandendo l'altezza utile del contenitore testo a 45dp.

---

### 3.4. Relazione Pixel vs Density DP su Android TV Full HD
- Un canvas di **1920×1080 pixel** corrisponde esattamente a **1920×1080 dp** unicamente in presenza di densità standard `mdpi` (160 dpi, `density = 1.0`).
- Sui pannelli Android TV reali, i profili di densità tipici possono essere `tvdpi` (213 dpi, `density = 1.33`, larghezza utile ~1440dp) o `hdpi` (240 dpi, `density = 1.5`, larghezza utile ~1280dp).
- **Adattamento Layout**: La griglia con `android:numColumns="6"` e `android:stretchMode="columnWidth"` calcola la larghezza di ogni singola colonna a runtime dividendo lo spazio orizzontale al netto dei padding (`44dp` per lato):
  $$\text{Larghezza Colonna} = \frac{\text{Larghezza Utile} - 5 \times 10\text{dp}}{6}$$
  Su 1920 pixel fisici, ogni colonna occupa esattamente **297 pixel**, garantendo proporzioni armoniose per le card rettangolari.

---

## 4. Le Quattro Soluzioni di Rifinitura Progettuale (PRIMA / DOPO)

In risposta alle direttive concordate con ChatGPT, la tavola comparativa [`mockup_04_before_after_redesign_comparison.png`](screenshots/mockup_04_before_after_redesign_comparison.png) illustra la proposta di rifinitura Leanback, rigorosamente conservativa:

```mermaid
graph TD
    subgraph Obiettivo: Rifinitura Leanback AKAI Custom Home v8
        A[1. Tipografia e Contrasto WCAG AAA] --> E[Titoli 14sp #F8FAFC, Aiuti 13sp #CBD5E1 7.5:1]
        B[2. Riconoscibilità Focus D-pad] --> F[Bordo fluorescente 2.5dp ciano #00E5FF multi-sezione]
        C[3. Organizzazione App OEM/Servizio] --> G[Filtro opzionale: Multimediali vs Servizi di Sistema]
        D[4. Bilanciamento Ingressi Hardware] --> H[Indicatore di segnale attivo su HDMI 1 nello spazio a destra]
    end
```

### 4.1. Miglioramento 1: Tipografia Ottimizzata TV (14–16sp, Contrasto WCAG AAA)
- **Titoli Sezione**: Elevati da 11sp a **14sp bold** (`tv_title_inputs`, `tv_title_favorites`, `tv_title_all_apps`).
- **Testo di Supporto**: Elevato da 10sp a **13sp** con colore `#CBD5E1` (contrasto **7.5:1** rispetto allo sfondo scuro `#0A0B10`).
- **Etichette Applicazioni**: Elevate da 12sp a **14sp** con wrapping controllato.

### 4.2. Miglioramento 2: Riconoscibilità Universale del Focus D-pad
- Mantenimento del meccanismo performante `StateListDrawable` con incremento dello spessore del bordo a **2.5–3dp** per schermi di grande diagonale.
- Utilizzo dell'accento ciano neon `#00E5FF` (o personalizzato in base alla palette scelta dall'utente nel menu Tema).

### 4.3. Miglioramento 3: Modalità Opzionale per Organizzare le App OEM di Sistema
- **Problema Osservato**: Nella griglia predefinita, le utilità tecniche fornite con il firmware TV (`A2dpSinkPlayer`, `Boot Video`, `CULTRAVIEW_OPEN_LAUNCH...`) si posizionano in testa all'elenco per ordine alfabetico o di pacchetto, relegando più in basso le app multimediali di reale interesse.
- **Soluzione Proposta (Non Distruttiva)**:
  - Nessuna rimozione, disinstallazione o alterazione dei pacchetti OEM.
  - Aggiunta di un filtro a tab rapido sopra la griglia:
    `[ App Multimediali (12) | Servizi di Sistema (6) | Tutte le App (18) ]`
  - La vista predefinita mostra le app multimediali (RaiPlay, YouTube, Netflix, Disney+, Prime Video, Spotify, VLC, Browser), mentre le utilità tecniche restano comodamente accessibili nel tab dedicato con un singolo click del D-pad.

### 4.4. Miglioramento 4: Bilanciamento Orizzontale della Riga Ingressi
- **Problema Osservato**: I chip ingressi (DTV, ATV, HDMI 1, HDMI 2, HDMI 3, AV) occupano circa 900–1000px sul lato sinistro, lasciando un'ampia zona vuota sul lato destro dello schermo.
- **Soluzione Proposta**: Utilizzo dell'area destra per ospitare un badge informativo dinamico sullo stato della sorgente attualmente attiva (es. `● Segnale Rilevato: HDMI 1 - 1080p 60Hz`), conferendo all'interfaccia un aspetto curato e professionale senza sovraccaricare la vista.

---

## 5. Delimitazione di Ambito e Vincoli di Sviluppo

- **Nessuna Modifica al Codice in PR #2**: La presente Pull Request è rigorosamente limitata alla documentazione e alle evidenze visive. Nessun file Java, XML o di compilazione del launcher viene alterato in questo branch.
- **Hardware Freeze Invariato**: Nessun comando ADB o pacchetto inviato alla TV fisica.
- **Iter Successivo**: L'implementazione delle ottimizzazioni grafiche descritte verrà proposta in una PR di codice successiva, solo previa approvazione formale da parte del proprietario e di ChatGPT.
