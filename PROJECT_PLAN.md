# Progetto: AKAI Custom TV (M7332 / Android 9)
## Piano Tecnico, Strategia di Sicurezza e Roadmap Operativa

---

### 1. Visione d'Insieme e Obiettivi
* **Dispositivo Target**: Smart TV Akai su piattaforma **M7332** (SoC MediaTek/MStar quad-core Cortex-A53, GPU Mali-G52).
* **Sistema Operativo**: Android TV 9 (Pie, API Level 28).
* **Vincoli Primari**:
  1. **Nessuna modifica irreversibile o distruttiva**: Tutte le operazioni devono essere reversibili al 100% senza ricorrere a flash di emergenza hardware.
  2. **Integrità Funzionale Hardware**: Mantenere sempre attivi e funzionanti telecomando (IR/Bluetooth), sintonizzatore Digitale Terrestre (DVB-T2 / Live TV), porte HDMI/ingressi video, stack audio e DRM Widevine per streaming (Netflix, Prime Video, RaiPlay, ecc.).
  3. **Solo Strumenti Gratuiti e Open Source**: ADB (Android SDK Platform-Tools), FLauncher, CleanYourTV methodology, REA/JADX per reverse engineering.

---

### 2. Studio delle Repository di Riferimento

#### A. CleanYourTV (`Gathin23/cleanyourtv`)
* **Meccanismo**: Sfrutta la connessione ADB over Wi-Fi (`port 5555`).
* **Principio di Sicurezza**: Non usa `rm` o modifiche alle partizioni `/system`. Utilizza comandi utente non-root:
  * `pm disable-user --user 0 <package>` (sospende e nasconde il pacchetto senza cancellarlo).
  * Consente il ripristino immediato con `pm enable <package>`.
* **Beneficio su Akai M7332**: Con solo 1.5 GB di RAM totale, il launcher di serie (`Google TV Launcher` / `Android TV Home`) e i processi in background di telemetria occupano spesso oltre il 70-80% della memoria disponibile, provocando rallentamenti e chiusure forzate. Il de-bloat selettivo libera fino a 300-450 MB di RAM.

#### B. FLauncher (`gitlab.com/flauncher/flauncher`)
* **Meccanismo**: Launcher alternativo open source scritto in Flutter per Android TV.
* **Caratteristiche**:
  * Zero pubblicità, zero banner promozionali, zero raccomandazioni invasive in streaming.
  * Consumo RAM irrisorio (circa 40-60 MB contro i 150-250 MB del launcher stock).
  * Personalizzazione completa: sfondi statici/dinamici, sezioni e categorie su misura, ordinamento griglia, scorciatoie personalizzate agli ingressi e app preferite.

#### C. REA (`morluto/rea`) e Strumenti di Reverse Engineering
* **Meccanismo**: Framework per l'analisi assistita da AI di APK, servizi di sistema, broadcast receiver e dump di sistema.
* **Applicazione su Akai**:
  * Estrazione degli APK di sistema proprietari (`com.mediatek.*` o specifici del costruttore).
  * Decompilazione con JADX / decompilatore Java.
  * Tracciamento dell'origine del popup "Eco / Risparmio Energetico" per capire se è controllato da una proprietà di sistema (`persist.vendor.*`), una preferenza in `settings_global` o un servizio disattivabile in sicurezza.

---

### 3. Matrice dei Rischi e Classificazione dei Servizi (Tiers)

| Livello (Tier) | Descrizione | Politica d'Azione | Esempi di Pacchetti |
| :--- | :--- | :--- | :--- |
| **Tier 1 - Sicuri** | Telemetria, tracker, diagnostica di terze parti, app demo di fabbrica | Disattivazione consigliata dopo backup | Servizi di statistiche, app demo, giochi preinstallati |
| **Tier 2 - Cauti** | Launcher di serie, Google Play Movies, raccomandazioni sponsorizzate | Disattivazione SOLO dopo installazione e test del launcher sostitutivo | `com.google.android.tvlauncher`, `com.google.android.videos` |
| **Tier 3 - CRITICI (NON TOCCARE)** | Sintonizzatore TV, ingressi HDMI, Audio HAL, telecomando Bluetooth/IR, CEC | **MAI disattivare o rimuovere** | `com.mediatek.wwtv.*`, `com.mediatek.tv`, `com.android.bluetooth`, `com.android.inputmethod.*` |

---

### 4. Roadmap a 4 Fasi

```
[FASE 1: Identificazione & Audit Sola Lettura]
   │  - Configurazione ADB su PC (Wi-Fi/LAN)
   │  - Abilitazione Opzioni Sviluppatore sulla TV
   │  - Dump completo proprietà hardware, RAM, CPU, pacchetti
   ▼
[FASE 2: Indagine Popup Eco & Diagnostica Specifica]
   │  - Tracciamento della finestra attiva durante il popup
   │  - Ispezione delle impostazioni energetiche MediaTek
   │  - Analisi mirata APK senza modifiche
   ▼
[FASE 3: Ottimizzazione & FLauncher (Sostituzione UI)]
   │  - Installazione parallela di FLauncher
   │  - Verifica funzionamento telecomando e scorciatoie
   │  - Sospensione selettiva dei processi superflui Tier 1
   │  - Switch controllato del launcher predefinito
   ▼
[FASE 4: Valutazione Modifiche Avanzate & Firmware]
   │  - Analisi fattibilità root / dump firmware
   │  - Solo se presenti backup completi e procedure di recupero unbrick testate
```
