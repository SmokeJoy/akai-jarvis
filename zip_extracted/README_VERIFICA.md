# AKAI Custom TV — revisione degli script

I file sono una **revisione statica**, non sono stati eseguiti su Windows o sulla TV. Il firmware e il modello specifico della Akai non sono ancora stati identificati.

## Correzioni
- ADB installato da WinGet: usato direttamente dal PATH, senza download duplicati.
- Connessione: controllo di IPv4, exit code, presenza e autorizzazione del device.
- Audit: scelta esplicita del dispositivo quando sono collegati più device; segnalazione errori; nessuna modifica sulla TV; risultati sul PC.
- Popup Eco: evita grep non garantito sul firmware e salva dumpsys raw per analisi successiva.
- Ripristino: eliminata la riattivazione indiscriminata di tutti i pacchetti e il comando `pm unhide`; richiede nome esatto e conferma. **Non costituisce ripristino completo del firmware**.

## Procedura consigliata
1. Sul PC: `adb version` e `adb devices`.
2. Sulla TV: attivare le opzioni sviluppatore e verificare se ADB di rete è disponibile. Su Android 9 non è garantito.
3. Se abilitato, dentro la cartella `scripts` in PowerShell: `./02_connect_tv.ps1 -TvIp 192.168.1.100` (sostituire con IP reale).
4. Dopo connessione autorizzata: `./03_read_only_audit.ps1`.
5. Condividere inizialmente **solo** `backups/audit_.../AUDIT_SUMMARY.txt` (possibilmente oscurare dati identificativi, se presenti).
6. Usare `04_diagnose_eco_popup.ps1` soltanto quando si può far comparire il popup; conservare localmente i dump completi.
7. **Non usare** `99_emergency_restore.ps1` nella fase 1.

## Limitazioni
- Gli output `getprop` e `settings` possono includere dati che non andrebbero pubblicati online.
- I file raccolti in `backups` non sono un backup del firmware o delle partizioni.
- M7332, tipologia di SoC, RAM e GPU restano da verificare tramite audit.
- Il popup Eco potrebbe non corrispondere a un'attività con focus Android.
- Non eseguire modifiche di debloat, root o flash prima di documentare uno scenario di recupero affidabile.
