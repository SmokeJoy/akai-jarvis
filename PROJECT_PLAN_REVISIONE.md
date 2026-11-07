# AKAI Custom TV — piano corretto

## Fase 1 — Identificazione (attuale)
- ADB Google Platform-Tools disponibile sul PC; verificare collegamento reale alla TV.
- Rilevare modello esatto, board, CPU, RAM, versione Android, launcher e lista pacchetti.
- Nessun comando di disabilitazione, root, flash o installazione APK.

## Fase 2 — Analisi Eco
- Identificare activity o servizio responsabile mediante `dumpsys`, se possibile.
- Non disattivare servizi TV senza conoscerne dipendenze ed effetti.

## Fase 3 — Personalizzazione non invasiva
- Valutare launcher compatibile con Android 9 e telecomando.
- Provare alternative senza disattivare la Home originale.
- Misurare le prestazioni prima e dopo, senza promettere risparmi di RAM non verificati.

## Fase 4 — Studio firmware
- Solo dopo identificazione del modello: disponibilita firmware originale, schemi di partizioni, procedura di recupero verificata.
- Nessuna garanzia che il firmware sia modificabile o che il ripristino sia possibile tramite solo ADB.

## Errori del piano originale
- RAM 1,5 GB, Mali-G52, architettura Cortex-A53 e valori RAM di FLauncher non documentati per questa unità.
- "Reversibile al 100%" non dimostrabile: perfino un `pm disable-user` mal indirizzato può impedire funzioni vitali.
- Il folder chiamato `backups` contiene report diagnostici, non immagini complete del sistema.
