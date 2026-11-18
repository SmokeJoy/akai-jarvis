# DEPRECATO — Requisiti già anticipati alla JARVIS v4

> Questo documento rifletteva la decisione precedente del proprietario. È **superato dalla decisione successiva del 18 novembre 2026** e non deve essere utilizzato come checklist v5.

**Fonte canonica:** [JARVIS v4 — tutti i requisiti obbligatori](JARVIS_V4_COMPLETE_ACCEPTANCE.md).

Navigazione multipasso, OTA utilizzabile a PC spento, misure delle prestazioni sulla vera AKAI e APK originale firmato con recuperabilità verificata **sono tutti requisiti della v4 Diagnostic**. Non sono lavori da rimandare alla v5.

La **v5 Release**, solo dopo approvazione della v4, deve derivare dalla *stessa base di codice applicativo* già validata: soltanto `debuggable=false`, profilo di compilazione Release e metadati di versione indispensabili all'upgrade, firma originale invariata. **Nessuna nuova funzione** nella v5.

Rimangono validi: consenso proprietario separato, no installazione automatica, no bypass DRM, cloud AI solo DeepSeek/Kimi, verifica hardware, salvaguardia di dati SQLite/WAL/TLS e impossibilità di dichiarare PASS senza prove.

Per la formulazione storica completa vedere la cronologia Git antecedente al commit di sostituzione. I criteri `GO_FOR_V5_RELEASE` e `GATE V5-1..4` precedenti NON sono più il percorso di sviluppo: usare `V4_COMPLETE_ACCEPTED` e `V4-1..4` del documento canonico.
