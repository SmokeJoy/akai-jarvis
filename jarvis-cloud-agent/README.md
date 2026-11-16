# JARVIS Cloud Developer — prima implementazione (draft PR manuale)

**Indipendente dalla TV AKAI.** Questo agente gira su GitHub Actions, non su Android, e produce una proposta Java **di un solo file** in una nuova PR *draft*. Non può installare APK, cambiare launcher, modificare il router HTTP/HTTPS del telecomando, lanciare comandi sulla TV o effettuare merge.

Per usarlo dopo l'approvazione del workflow: **Actions → JARVIS Cloud Developer → Run workflow**, inserendo un task breve, un provider e il percorso esatto di un solo file sotto `akai-remote-tv/app/src/main/java/it/akai/customremote/ai/` oppure `akai-remote-tests/`. DeepSeek richiede il secret GitHub `DEEPSEEK_API_KEY` (modello ufficiale predefinito `deepseek-flash`); Kimi richiede `MOONSHOT_API_KEY` e la variabile `MOONSHOT_MODEL` contenente un ID compatibile. **Nessuna chiave è presente nel repository.** Ogni chiamata reale al provider può avere un costo; il workflow non è programmato automaticamente.

Il repository deve consentire a GitHub Actions di creare pull request. Il codice prodotto dal modello non è affidabile: va controllato e testato in CI da una persona prima del merge. La chiave API non viene passata agli step successivi a quello di generazione; non si eseguono script forniti dal modello. Questo workflow non effettua update o deploy sulla TV.

Test gratuiti senza provider: `python -m unittest discover -s jarvis-cloud-agent -p 'test_*.py' -v` (6 casi). Mock locale: `python jarvis-cloud-agent/developer.py --task 'Example' --target 'akai-remote-tv/app/src/main/java/it/akai/customremote/ai/SafeSkill.java' --mock-json proposal.json`, dove il JSON contiene `{"summary":"...","changes":[{"path":"...","content":"..."}]}`.

**Limiti della versione iniziale:** richiede avvio manuale, un target preciso e revisione PR. Non è ancora un agente self-hosted sulla TV, né un autoaggiornatore. L'integrazione futura TV→cloud e il ciclo iterativo PR/test devono essere costruiti e collaudati separatamente senza intaccare il telecomando.
