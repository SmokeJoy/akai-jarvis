/**
 * AKAI JARVIS · TV Assistant & Remote v16
 * Target: AKAI AKTV5037N (Android 9 Pie API 28)
 * Residente sulla Smart TV - Microfono Mobile & Risposta TV
 */

(function () {
    'use strict';

    // State management
    const isInitialHttps = (location.protocol === 'https:');
    const defaultInitialPort = isInitialHttps ? '8443' : '8088';
    const state = {
        host: localStorage.getItem('akai_host') || (location.hostname && location.hostname !== 'localhost' ? location.hostname : ''),
        port: localStorage.getItem('akai_port') || (location.port ? location.port : defaultInitialPort),
        proto: localStorage.getItem('akai_proto') || (isInitialHttps ? 'https' : 'http'),
        token: localStorage.getItem('akai_token') || null,
        connected: false,
        pingMs: 0,
        pingTimer: null,
        speechRecognition: null,
        isListening: false,
        caFingerprint: null
    };

    // Conversation State Machine (P1-02, P1-03, P1-04)
    const JarvisConvoState = {
        IDLE: 'IDLE',
        READY: 'READY',
        LISTENING: 'LISTENING',
        THINKING: 'THINKING',
        SPEAKING: 'SPEAKING',
        ERROR: 'ERROR'
    };

    const convoSession = {
        active: false,
        turnCount: 0,
        currentTurnId: 0,
        turnLocked: false,
        state: JarvisConvoState.IDLE,
        vadTimer: null,
        inactivityTimer: null,
        silenceTimeoutMs: 1400,
        lastTranscript: '',
        aiAbortController: null,
        lastQuery: ''
    };

    // DOM Elements Cache
    const elements = {
        connectionPill: document.getElementById('connection-pill'),
        statusText: document.getElementById('status-text'),
        pingBadge: document.getElementById('ping-badge'),
        toast: document.getElementById('toast'),

        // Jarvis Voice Elements (Tab 1)
        jarvisOrb: document.getElementById('jarvis-orb'),
        jarvisBadgeMode: document.getElementById('jarvis-badge-mode'),
        jarvisStateBadge: document.getElementById('jarvis-state-badge'),
        jarvisLiveTranscript: document.getElementById('jarvis-live-transcript'),
        btnOrbAction: document.getElementById('btn-orb-action'),
        jarvisConvoControls: document.getElementById('jarvis-convo-controls'),
        btnConvoStop: document.getElementById('btn-convo-stop'),
        btnConvoTalkAgain: document.getElementById('btn-convo-talk-again'),
        voiceFootnote: document.getElementById('voice-footnote'),

        // AI Input & Indicators
        btnVoiceAi: document.getElementById('btn-voice-ai'),
        aiTextInput: document.getElementById('ai-text-input'),
        btnAiSend: document.getElementById('btn-ai-send'),
        aiActiveState: document.getElementById('ai-active-state'),
        aiActiveLabel: document.getElementById('ai-active-label'),
        btnAiStop: document.getElementById('btn-ai-stop'),
        aiResponseBox: document.getElementById('ai-response-box'),
        aiBadgeSource: document.getElementById('ai-badge-source'),
        aiBadgeStatus: document.getElementById('ai-badge-status'),
        aiBadgeMeta: document.getElementById('ai-badge-meta'),
        aiResponseText: document.getElementById('ai-response-text'),
        aiRetryBox: document.getElementById('ai-retry-box'),
        btnRetryAi: document.getElementById('btn-retry-ai'),

        // Tab 2: Remote Elements
        numpadPanel: document.getElementById('numpad-panel'),
        btnToggleNumpad: document.getElementById('btn-toggle-numpad'),
        btnCloseNumpad: document.getElementById('btn-close-numpad'),
        keyboardInput: document.getElementById('keyboard-input'),
        btnSendText: document.getElementById('btn-send-text'),

        // Tab 3: Activity & SQLite
        statZeroTokenQuick: document.getElementById('stat-zero-token-quick'),
        statCloudCallsQuick: document.getElementById('stat-cloud-calls-quick'),
        budgetSpentQuick: document.getElementById('budget-spent-quick'),
        prefGuestModeQuick: document.getElementById('pref-guest-mode-quick'),
        btnClearPersonalPrefsQuick: document.getElementById('btn-clear-personal-prefs-quick'),
        btnResetProceduralQuick: document.getElementById('btn-reset-procedural-quick'),
        activityFeed: document.getElementById('activity-feed'),
        activityProceduralList: document.getElementById('activity-procedural-list'),

        // System Buttons
        btnSettings: document.getElementById('btn-settings'),
        btnPower: document.getElementById('btn-power'),

        // Pairing Modal
        modalPairing: document.getElementById('modal-pairing'),
        pinInput: document.getElementById('pin-input'),
        pinCountdown: document.getElementById('pin-countdown'),
        pairingError: document.getElementById('pairing-error'),
        btnSubmitPin: document.getElementById('btn-submit-pin'),
        btnClosePairing: document.getElementById('btn-close-pairing'),
        caTrustCard: document.getElementById('ca-trust-card'),
        chkConfirmCaTv: document.getElementById('chk-confirm-ca-tv'),
        caFpVal: document.getElementById('ca-fp-val'),
        btnDownloadCa: document.getElementById('btn-download-ca'),
        btnToggleCaInstructions: document.getElementById('btn-toggle-ca-instructions'),
        caInstructionsPanel: document.getElementById('ca-instructions-panel'),
        voiceEnvNotice: document.getElementById('voice-env-notice'),

        // Settings Modal
        modalSettings: document.getElementById('modal-settings'),
        btnCloseSettings: document.getElementById('btn-close-settings'),
        serverHost: document.getElementById('server-host'),
        serverPort: document.getElementById('server-port'),
        sessionBadge: document.getElementById('session-badge'),
        btnSaveSettings: document.getElementById('btn-save-settings'),
        btnRevokeSession: document.getElementById('btn-revoke-session'),

        // Provider & API
        aiModelSelect: document.getElementById('ai-model-select'),
        aiKimiRegionSelect: document.getElementById('ai-kimi-region-select'),
        aiApiKeyInput: document.getElementById('ai-api-key-input'),
        chkCloudContextConsent: document.getElementById('chk-cloud-context-consent'),
        btnToggleKeyVisibility: document.getElementById('btn-toggle-key-visibility'),
        btnTestAiConnection: document.getElementById('btn-test-ai-connection'),
        testConnectionResult: document.getElementById('test-connection-result'),
        btnSaveAiConfig: document.getElementById('btn-save-ai-config'),

        // Budget Guard
        budgetSpentVal: document.getElementById('budget-spent-val'),
        budgetInflightVal: document.getElementById('budget-inflight-val'),
        budgetRemainingVal: document.getElementById('budget-remaining-val'),
        budgetProgressFill: document.getElementById('budget-progress-fill'),
        budgetStatusBadge: document.getElementById('budget-status-badge'),
        budgetAlertBox: document.getElementById('budget-alert-box'),
        btnTestBudgetGuard: document.getElementById('btn-test-budget-guard'),
        btnResetBudget: document.getElementById('btn-reset-budget'),

        // Voice & TTS
        aiVoiceSelect: document.getElementById('ai-voice-select'),
        azureSpeechKeyInput: document.getElementById('azure-speech-key-input'),
        btnToggleAzureKey: document.getElementById('btn-toggle-azure-key'),
        azureRegionSelect: document.getElementById('azure-region-select'),
        ttsCacheSize: document.getElementById('tts-cache-size'),
        btnSaveVoice: document.getElementById('btn-save-voice'),
        btnPreviewVoice: document.getElementById('btn-preview-voice'),
        btnClearCache: document.getElementById('btn-clear-cache'),

        // Procedural & Preferences
        proceduralList: document.getElementById('procedural-list'),
        btnResetProcedural: document.getElementById('btn-reset-procedural'),
        prefGuestMode: document.getElementById('pref-guest-mode'),
        prefFavChannels: document.getElementById('pref-fav-channels'),
        prefFavGenres: document.getElementById('pref-fav-genres'),
        prefFavApps: document.getElementById('pref-fav-apps'),
        btnSavePrefs: document.getElementById('btn-save-prefs'),
        btnClearPersonalPrefs: document.getElementById('btn-clear-personal-prefs'),

        // Stats
        statZeroToken: document.getElementById('stat-zero-token'),
        statCloudCalls: document.getElementById('stat-cloud-calls'),
        statPromptTokens: document.getElementById('stat-prompt-tokens'),
        statCompletionTokens: document.getElementById('stat-completion-tokens')
    };

    // =========================================================================
    // INITIALIZATION & PWA SERVICE WORKER (P2-01)
    // =========================================================================

    function init() {
        bindEvents();
        updateSettingsUI();
        initSpeechRecognition();

        // Register Service Worker with fresh cache strategy (P2-01)
        if ('serviceWorker' in navigator && (location.protocol === 'https:' || location.hostname === 'localhost' || location.hostname === '127.0.0.1')) {
            navigator.serviceWorker.register('./sw.js').catch(err => {
                console.warn('SW registration failed:', err);
            });
        }

        checkConnection();
        state.pingTimer = setInterval(checkConnection, 8000);
    }

    function getApiUrl(endpoint) {
        return `${state.proto}://${state.host}:${state.port}${endpoint}`;
    }

    function triggerHaptic(duration = 15) {
        if ('vibrate' in navigator) {
            try { navigator.vibrate(duration); } catch (e) {}
        }
    }

    let toastTimeout = null;
    function showToast(message, isError = false) {
        if (toastTimeout) clearTimeout(toastTimeout);
        elements.toast.textContent = message;
        elements.toast.style.borderColor = isError ? 'var(--danger)' : 'var(--mint)';
        elements.toast.classList.remove('hidden');
        toastTimeout = setTimeout(() => {
            elements.toast.classList.add('hidden');
        }, 2800);
    }

    function setConnectionState(status, text) {
        elements.connectionPill.className = `status-pill ${status}`;
        elements.statusText.textContent = text;
        state.connected = (status === 'connected');

        if (status === 'connected' && state.pingMs > 0) {
            elements.pingBadge.textContent = `${state.pingMs} ms`;
            elements.pingBadge.classList.remove('hidden');
        } else {
            elements.pingBadge.classList.add('hidden');
        }
    }

    // Check TV connection status
    async function checkConnection() {
        const t0 = performance.now();
        try {
            const controller = new AbortController();
            const timeoutId = setTimeout(() => controller.abort(), 3500);

            const headers = {};
            if (state.token) headers['Authorization'] = `Bearer ${state.token}`;

            const res = await fetch(getApiUrl('/api/status'), {
                headers,
                signal: controller.signal
            });
            clearTimeout(timeoutId);

            state.pingMs = Math.round(performance.now() - t0);

            if (res.ok) {
                const data = await res.json();
                if (data.authenticated) {
                    setConnectionState('connected', 'Connesso');
                } else {
                    setConnectionState('pairing', 'Da associare');
                }
            } else if (res.status === 401) {
                handleSessionExpired();
            } else {
                setConnectionState('disconnected', 'TV offline');
            }
        } catch (e) {
            setConnectionState('disconnected', 'Non raggiungibile');
        }
    }

    // Handle token expired (P1-12)
    function handleSessionExpired() {
        state.token = null;
        localStorage.removeItem('akai_token');
        setConnectionState('pairing', 'Da associare');
        showToast('Sessione TV scaduta. Associa con PIN.', true);
    }

    // =========================================================================
    // VOICE CONVERSATION STATE MACHINE (P1-02, P1-03, P1-04)
    // =========================================================================

    function setJarvisState(newState, label, orbClass) {
        convoSession.state = newState;
        if (elements.jarvisStateBadge) {
            elements.jarvisStateBadge.textContent = label;
        }
        if (elements.jarvisOrb) {
            elements.jarvisOrb.className = `orb ${orbClass || ''}`;
            elements.jarvisOrb.setAttribute('aria-pressed', String(newState !== JarvisConvoState.IDLE));
        }
    }

    function initSpeechRecognition() {
        const isHttps = (location.protocol === 'https:');
        const isLocal = (location.hostname === 'localhost' || location.hostname === '127.0.0.1');
        const isSecure = (window.isSecureContext === true) || isLocal;

        const SpeechRec = window.SpeechRecognition || window.webkitSpeechRecognition;

        if (!isSecure && !isLocal) {
            console.warn('SpeechRecognition: Insecure HTTP Context.');
            if (elements.voiceEnvNotice) {
                elements.voiceEnvNotice.innerHTML = '<strong>⚠️ Connessione HTTP non cifrata:</strong> Safari (iOS) e Chrome (Android) consentono l\'accesso al microfono solo in <strong>Secure Context (HTTPS)</strong>. Passa a HTTPS (porta 8443) nelle Impostazioni dopo aver installato il certificato della TV, oppure usa la casella di testo qui sotto per digitare comandi a costo 0 token.';
                elements.voiceEnvNotice.classList.remove('hidden');
            }
            if (elements.voiceFootnote) {
                elements.voiceFootnote.textContent = 'Microfono disabilitato su HTTP non protetto. Digita da tastiera o usa HTTPS.';
            }
            return;
        } else if (!SpeechRec) {
            console.warn('SpeechRecognition API not available in this browser environment.');
            if (elements.voiceEnvNotice) {
                elements.voiceEnvNotice.innerHTML = '<strong>ℹ️ Riconoscimento vocale non supportato dal browser:</strong> utilizza la casella di testo sottostante per inviare comandi TV istantanei a costo 0 token.';
                elements.voiceEnvNotice.classList.remove('hidden');
            }
            if (elements.voiceFootnote) {
                elements.voiceFootnote.textContent = 'Riconoscimento vocale supportato nativamente su Safari iOS e Chrome Android su HTTPS.';
            }
            return;
        } else {
            if (elements.voiceFootnote) {
                elements.voiceFootnote.textContent = 'Voce Web (motore STT del sistema operativo del telefono; per uso a connessione Internet WAN disattivata, verificare la dettatura offline nelle impostazioni del telefono).';
            }
        }

        if (!SpeechRec) return;

        const recognizer = new SpeechRec();
        recognizer.lang = 'it-IT';
        recognizer.continuous = false;
        recognizer.interimResults = true;
        recognizer.maxAlternatives = 1;

        recognizer.onstart = () => {
            state.isListening = true;
            convoSession.turnLocked = false;
            if (convoSession.active) {
                setJarvisState(JarvisConvoState.LISTENING, 'In ascolto...', 'listening');
                elements.jarvisLiveTranscript.textContent = 'Ti ascolto... parla pure liberamente';
                elements.jarvisLiveTranscript.classList.add('active');
                if (elements.btnConvoTalkAgain) elements.btnConvoTalkAgain.classList.add('hidden');
            } else {
                elements.btnVoiceAi.classList.add('listening');
                elements.aiActiveLabel.textContent = 'In ascolto...';
                elements.aiActiveState.classList.remove('hidden');
            }
            triggerHaptic(20);
            resetInactivityTimer();
        };

        recognizer.onresult = (event) => {
            clearTimeout(convoSession.vadTimer);
            resetInactivityTimer();

            // P1-02: Atomically lock turn to avoid duplicate submissions
            if (!convoSession.active || convoSession.turnLocked) {
                return;
            }

            let interim = '';
            let final = '';

            for (let i = event.resultIndex; i < event.results.length; ++i) {
                const transcript = event.results[i][0].transcript;
                if (event.results[i].isFinal) {
                    final += transcript;
                } else {
                    interim += transcript;
                }
            }

            const currentText = (final || interim).trim();
            if (currentText) {
                convoSession.lastTranscript = currentText;
                if (elements.jarvisLiveTranscript) {
                    elements.jarvisLiveTranscript.textContent = `«${currentText}»`;
                    elements.jarvisLiveTranscript.classList.add('active');
                }
                if (elements.aiTextInput) {
                    elements.aiTextInput.value = currentText;
                }
            }

            // Lock and commit once final phrase or VAD pause is hit
            if (final) {
                convoSession.turnLocked = true;
                commitTurn(final, ++convoSession.currentTurnId);
            } else if (interim) {
                convoSession.vadTimer = setTimeout(() => {
                    if (!convoSession.active || convoSession.turnLocked) return;
                    convoSession.turnLocked = true;
                    commitTurn(interim, ++convoSession.currentTurnId);
                }, convoSession.silenceTimeoutMs);
            }
        };

        recognizer.onerror = (event) => {
            console.warn('Speech recognition event error:', event.error);
            if (event.error === 'no-speech') {
                if (convoSession.active) {
                    setJarvisState(JarvisConvoState.READY, 'Tocca a te', 'ready');
                    elements.jarvisLiveTranscript.textContent = 'Non ho sentito nulla. Tocca per parlare o termina.';
                    if (elements.btnConvoTalkAgain) elements.btnConvoTalkAgain.classList.remove('hidden');
                }
            } else if (event.error !== 'aborted') {
                setJarvisState(JarvisConvoState.ERROR, 'Errore microfono', 'error');
                if (event.error === 'not-allowed') {
                    showToast('Microfono: not-allowed (Accesso negato. Su iOS: verifica permessi sito e abilita la Root CA in Generali > Info > Attendibilità certificati)', true);
                } else {
                    showToast(`Microfono: ${event.error}`, true);
                }
                stopConversation();
            }
        };

        recognizer.onend = () => {
            state.isListening = false;
            elements.btnVoiceAi.classList.remove('listening');

            // P1-02: Guard against duplicate calls
            if (convoSession.active && !convoSession.turnLocked && convoSession.state === JarvisConvoState.LISTENING) {
                if (convoSession.lastTranscript) {
                    convoSession.turnLocked = true;
                    commitTurn(convoSession.lastTranscript, ++convoSession.currentTurnId);
                } else {
                    setJarvisState(JarvisConvoState.READY, 'Tocca a te', 'ready');
                    if (elements.btnConvoTalkAgain) elements.btnConvoTalkAgain.classList.remove('hidden');
                }
            }
        };

        state.speechRecognition = recognizer;
    }

    function resetInactivityTimer() {
        clearTimeout(convoSession.inactivityTimer);
        if (convoSession.active) {
            convoSession.inactivityTimer = setTimeout(() => {
                if (convoSession.active) {
                    showToast('Sessione vocale chiusa per inattività.');
                    stopConversation();
                }
            }, 25000);
        }
    }

    function startConversation() {
        if (!state.speechRecognition) {
            showToast('Riconoscimento vocale non supportato nel browser. Usa Chrome o Safari su HTTPS.', true);
            return;
        }

        convoSession.active = true;
        convoSession.turnCount = 0;
        convoSession.turnLocked = false;
        convoSession.lastTranscript = '';

        if (elements.jarvisConvoControls) {
            elements.jarvisConvoControls.classList.remove('hidden');
        }
        if (elements.btnOrbAction) {
            elements.btnOrbAction.classList.add('hidden');
        }
        if (elements.btnConvoTalkAgain) {
            elements.btnConvoTalkAgain.classList.add('hidden');
        }

        try {
            state.speechRecognition.start();
        } catch (e) {
            console.warn('Recognition start exception:', e);
            setJarvisState(JarvisConvoState.READY, 'Tocca per parlare', 'ready');
            if (elements.btnConvoTalkAgain) elements.btnConvoTalkAgain.classList.remove('hidden');
        }
    }

    async function cancelBackendAiTask() {
        const hadInFlight = Boolean(convoSession.aiAbortController);
        if (convoSession.aiAbortController) {
            convoSession.userCancelRequested = true;
            try { convoSession.aiAbortController.abort(); } catch (e) {}
            convoSession.aiAbortController = null;
        }
        if (elements.aiActiveState) {
            elements.aiActiveState.classList.add('hidden');
        }
        if (!state.token) return false;
        try {
            const res = await fetch(getApiUrl('/api/ai/cancel'), {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${state.token}`
                },
                body: JSON.stringify({ reason: 'user_stop' })
            });
            const cancelData = await res.json().catch(() => ({}));
            if (res.ok && (cancelData.active_task_cancelled || (cancelData.queued_tasks_invalidated > 0) || hadInFlight)) {
                showToast('Annullamento richiesto alla TV...');
            }
            return res.ok;
        } catch (e) {
            return false;
        }
    }

    function stopConversation() {
        const shouldCancelTv = Boolean(convoSession.aiAbortController) ||
            convoSession.state === JarvisConvoState.THINKING ||
            convoSession.state === JarvisConvoState.SPEAKING;
        convoSession.active = false;
        convoSession.turnLocked = false;
        clearTimeout(convoSession.vadTimer);
        clearTimeout(convoSession.inactivityTimer);

        // P1-2: Abort pending ask request AND signal TV backend cancel (/api/ai/cancel)
        if (shouldCancelTv) {
            cancelBackendAiTask();
        } else if (convoSession.aiAbortController) {
            try { convoSession.aiAbortController.abort(); } catch (e) {}
            convoSession.aiAbortController = null;
        }

        if (state.speechRecognition && state.isListening) {
            try { state.speechRecognition.stop(); } catch (ignored) {}
        }

        setJarvisState(JarvisConvoState.IDLE, 'Pronto ad ascoltarti', '');
        if (elements.jarvisLiveTranscript) {
            elements.jarvisLiveTranscript.textContent = 'Tocca per parlare con Jarvis (Conversazione continua)';
            elements.jarvisLiveTranscript.classList.remove('active');
        }
        if (elements.jarvisConvoControls) {
            elements.jarvisConvoControls.classList.add('hidden');
        }
        if (elements.btnOrbAction) {
            elements.btnOrbAction.classList.remove('hidden');
        }
        if (elements.btnConvoTalkAgain) {
            elements.btnConvoTalkAgain.classList.add('hidden');
        }
        triggerHaptic(20);
    }

    // Submit a recognized vocal turn to the TV
    async function commitTurn(recognizedPhrase, turnId) {
        const query = (recognizedPhrase || '').trim();
        if (!query) {
            convoSession.turnLocked = false;
            return;
        }

        convoSession.lastTranscript = '';
        convoSession.lastQuery = query;
        clearTimeout(convoSession.vadTimer);
        clearTimeout(convoSession.inactivityTimer);

        // Stop microphone while TV is thinking and speaking
        if (state.speechRecognition) {
            try { state.speechRecognition.stop(); } catch (ignored) {}
        }

        setJarvisState(JarvisConvoState.THINKING, 'Elaborazione in corso...', 'thinking');
        if (elements.jarvisLiveTranscript) {
            elements.jarvisLiveTranscript.textContent = `«${query}»`;
        }

        convoSession.turnCount++;
        triggerHaptic(25);

        // Execute request on the TV (force spoken TTS reply)
        const ok = await askAi(query, true);

        // If conversation is still active, poll until TV finished speaking, then reopen microphone
        if (convoSession.active && ok !== false) {
            await handleTvSpeechTurn();
        } else {
            convoSession.turnLocked = false;
        }
    }

    // P1-03: Robust speech status polling
    async function handleTvSpeechTurn() {
        setJarvisState(JarvisConvoState.SPEAKING, 'La TV sta rispondendo...', 'speaking');

        let pollCount = 0;
        let speechSeen = false;

        // Poll TV speech status until finished
        while (pollCount < 40 && convoSession.active) {
            await new Promise(r => setTimeout(r, 400));
            if (!convoSession.active) return;

            try {
                const res = await fetch(getApiUrl('/api/ai/speech_status'), {
                    headers: { 'Authorization': `Bearer ${state.token}` }
                });
                if (res.ok) {
                    const data = await res.json();
                    const sState = data.speech_state || (data.speaking ? 'PLAYING' : 'IDLE');
                    if (sState === 'FETCHING' || sState === 'PLAYING' || data.speaking) {
                        speechSeen = true;
                    } else if (speechSeen && sState === 'IDLE') {
                        // TV finished talking!
                        break;
                    }
                }
            } catch (ignored) {}

            pollCount++;
            // If after 10 checks (4s) speech was never seen, assume local silent execution
            if (pollCount >= 10 && !speechSeen) break;
        }

        if (!convoSession.active) return;

        // Acoustic buffer before reopening mic
        await new Promise(r => setTimeout(r, 400));
        convoSession.turnLocked = false;

        // Reopen mic for next multi-turn question
        setJarvisState(JarvisConvoState.READY, 'Tocca a te... parla pure', 'ready');
        if (elements.jarvisLiveTranscript) {
            elements.jarvisLiveTranscript.textContent = 'Tocca a te... puoi continuare la conversazione';
            elements.jarvisLiveTranscript.classList.remove('active');
        }
        triggerHaptic(30);

        try {
            state.speechRecognition.start();
        } catch (e) {
            console.warn('Auto-restart notice:', e);
            if (elements.btnConvoTalkAgain) {
                elements.btnConvoTalkAgain.classList.remove('hidden');
            }
        }

        resetInactivityTimer();
    }

    // Single-shot mic button toggle
    function toggleVoiceRecognition() {
        if (!state.speechRecognition) {
            showToast('Riconoscimento vocale non supportato nel browser. Digita la richiesta.', true);
            return;
        }

        if (state.isListening) {
            state.speechRecognition.stop();
            stopListening();
        } else {
            try {
                state.speechRecognition.start();
            } catch (e) {
                console.error(e);
            }
        }
    }

    function stopListening() {
        state.isListening = false;
        elements.btnVoiceAi.classList.remove('listening');
        if (!elements.aiActiveLabel.textContent.includes('Elaborazione')) {
            elements.aiActiveState.classList.add('hidden');
        }
    }

    // =========================================================================
    // AI DISPATCHER & ACCURATE RESPONSE FEEDBACK (P0-01, P1-04, P1-05)
    // =========================================================================

    async function askAi(userQuery, forceSpeak = true) {
        const query = (userQuery || elements.aiTextInput.value).trim();
        if (!query) return false;

        triggerHaptic(20);
        elements.aiActiveLabel.textContent = 'Elaborazione assistente AI...';
        elements.aiActiveState.classList.remove('hidden');

        if (!state.token) {
            showToast('Associa il telecomando con il PIN prima di usare JARVIS', true);
            elements.aiActiveState.classList.add('hidden');
            openPairingModal();
            return false;
        }

        // P1-04: AbortController with 25-second timeout
        convoSession.userCancelRequested = false;
        convoSession.aiAbortController = new AbortController();
        const timeoutId = setTimeout(() => {
            if (convoSession.aiAbortController) convoSession.aiAbortController.abort();
        }, 25000);

        try {
            const res = await fetch(getApiUrl('/api/ai/ask'), {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${state.token}`
                },
                body: JSON.stringify({ query, speak: forceSpeak, source: 'web_remote' }),
                signal: convoSession.aiAbortController.signal
            });
            clearTimeout(timeoutId);

            const data = await res.json().catch(() => ({}));

            if (res.ok) {
                displayAiResponse(data, query);
                return true;
            } else if (res.status === 426) {
                displayAiResponse({
                    success: false,
                    status: 'UPGRADE_REQUIRED',
                    reply: 'Connessione HTTPS (porta 8443) obbligatoria. HTTP in chiaro non consentito per inviare comandi TV.',
                    verified: false
                }, query);
                showToast('HTTPS obbligatorio (HTTP 426)', true);
                return false;
            } else if (res.status === 401) {
                handleSessionExpired();
                return false;
            } else if (data.status === 'CANCELLED') {
                displayAiResponse({
                    success: false,
                    status: 'CANCELLED',
                    reply: data.reply || 'Operazione annullata su richiesta.',
                    verified: false
                }, query);
                return false;
            } else {
                displayAiResponse({
                    success: false,
                    status: 'ERROR',
                    reply: data.error || 'Errore nella richiesta alla TV',
                    verified: false
                }, query);
                return false;
            }
        } catch (e) {
            clearTimeout(timeoutId);
            if (e.name === 'AbortError' && convoSession.userCancelRequested) {
                convoSession.userCancelRequested = false;
                displayAiResponse({
                    success: false,
                    status: 'CANCELLED',
                    client_aborted: true,
                    reply: 'Annullamento richiesto alla TV (stop cooperativo in corso).',
                    verified: false
                }, query);
                return false;
            }
            if (e.name === 'AbortError') {
                showToast('Richiesta annullata o timeout.', true);
            } else {
                showToast('Errore di comunicazione con il modulo AI della TV', true);
            }
            displayAiResponse({
                success: false,
                status: 'ERROR',
                reply: 'Comunicazione con la Smart TV interrotta.',
                verified: false
            }, query);
            return false;
        } finally {
            convoSession.aiAbortController = null;
            elements.aiActiveState.classList.add('hidden');
        }
    }

    // P1-05, P1-16: Honest and distinct representation of outcome
    function displayAiResponse(data, originalQuery) {
        const replyText = data.reply || (data.success ? 'Comando completato.' : (data.error || 'Azione non riuscita.'));
        elements.aiResponseText.textContent = replyText;

        if (convoSession.active && elements.jarvisLiveTranscript) {
            elements.jarvisLiveTranscript.textContent = `TV: «${replyText}»`;
        }

        // Badge Source & Token
        const src = data.source || 'local';
        const tokens = data.tokens || 0;
        const latency = data.latency_ms || 0;

        if (src === 'local_fast_path' || src === 'procedural_memory') {
            elements.aiBadgeSource.className = 'ai-badge-source local';
            elements.aiBadgeSource.textContent = src === 'procedural_memory' ? '⚡ Memoria Procedurale (0 Token)' : '⚡ Fast-Path Locale (0 Token)';
        } else {
            elements.aiBadgeSource.className = 'ai-badge-source cloud';
            elements.aiBadgeSource.textContent = `☁ ${src.toUpperCase()} (${tokens} token)`;
        }

        // Status Badge (P1-05 & P1-16)
        if (elements.aiBadgeStatus) {
            if (data.status === 'SUCCESS_VERIFIED' || data.verified === true) {
                elements.aiBadgeStatus.className = 'ai-badge-status verified';
                elements.aiBadgeStatus.textContent = '✓ Verificato';
                showToast('Comando verificato con successo');
                if (elements.aiRetryBox) elements.aiRetryBox.classList.add('hidden');
            } else if (data.status === 'ANSWERED_DIALOG') {
                elements.aiBadgeStatus.className = 'ai-badge-status dialog';
                elements.aiBadgeStatus.textContent = '💬 Risposta';
                showToast('Risposta da JARVIS');
                if (elements.aiRetryBox) elements.aiRetryBox.classList.add('hidden');
            } else if (data.status === 'COMPLETED_UNVERIFIED' || data.verified === false && data.success !== false) {
                elements.aiBadgeStatus.className = 'ai-badge-status unverified';
                elements.aiBadgeStatus.textContent = '⚠️ Eseguito (Non Verificato)';
                showToast('Comando inviato (Non verificato)');
                if (elements.aiRetryBox) elements.aiRetryBox.classList.add('hidden');
            } else if (data.status === 'BUDGET_EXCEEDED') {
                elements.aiBadgeStatus.className = 'ai-badge-status blocked';
                elements.aiBadgeStatus.textContent = '🛑 Budget Bloccato';
                showToast('Budget massimo raggiunto (5,00 €)', true);
                if (elements.aiRetryBox) elements.aiRetryBox.classList.add('hidden');
            } else if (data.status === 'CANCELLED') {
                elements.aiBadgeStatus.className = 'ai-badge-status blocked';
                elements.aiBadgeStatus.textContent = data.client_aborted ? '⏹ Annullamento richiesto' : '⏹ Annullato';
                showToast(data.client_aborted ? 'Annullamento richiesto' : 'Task AI annullato');
                if (elements.aiRetryBox) elements.aiRetryBox.classList.add('hidden');
            } else {
                elements.aiBadgeStatus.className = 'ai-badge-status error';
                elements.aiBadgeStatus.textContent = '❌ Non Riuscito';
                showToast(replyText, true);
                if (elements.aiRetryBox) elements.aiRetryBox.classList.remove('hidden');
            }
        }

        let metaText = `${latency} ms`;
        if (data.cost_eur > 0) {
            metaText += ` • € ${Number(data.cost_eur).toFixed(4)}`;
        }
        elements.aiBadgeMeta.textContent = metaText;

        elements.aiResponseBox.classList.remove('hidden');

        // Refresh stats & activity if visible
        loadAiConfig();
    }

    // =========================================================================
    // REMOTE CONTROL HARDWARE COMMANDS (D-PAD, VOLUME, CHANNELS, APPS)
    // =========================================================================

    async function sendCommand(action) {
        if (!state.token) {
            showToast('Associazione TV richiesta per inviare comandi', true);
            openPairingModal();
            return;
        }

        triggerHaptic(12);

        try {
            const res = await fetch(getApiUrl('/api/command'), {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${state.token}`
                },
                body: JSON.stringify({ action })
            });

            if (res.status === 426) {
                showToast('HTTPS obbligatorio (HTTP 426): passa alla porta 8443', true);
                return;
            }

            if (res.status === 401) {
                handleSessionExpired();
                return;
            }

            const data = await res.json().catch(() => ({}));
            if (!res.ok || data.success === false) {
                showToast(`Comando fallito: ${data.message || action}`, true);
            }
        } catch (e) {
            showToast('Errore di invio alla TV', true);
        }
    }

    async function sendText() {
        const text = elements.keyboardInput.value.trim();
        if (!text) return;

        if (!state.token) {
            showToast('Associa il telecomando con il PIN', true);
            openPairingModal();
            return;
        }

        try {
            const res = await fetch(getApiUrl('/api/command'), {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${state.token}`
                },
                body: JSON.stringify({ action: 'type_text', text })
            });

            if (res.status === 426) {
                showToast('HTTPS obbligatorio (HTTP 426): passa alla porta 8443', true);
                return;
            }

            if (res.ok) {
                showToast(`Testo inviato: "${text}"`);
                elements.keyboardInput.value = '';
            } else {
                showToast('Errore invio testo', true);
            }
        } catch (e) {
            showToast('Errore di comunicazione', true);
        }
    }

    // =========================================================================
    // TAB 3: ACTIVITY FEED & SQLITE MEMORY INSPECTION
    // =========================================================================

    async function loadActivityData() {
        if (!state.token) return;
        try {
            const res = await fetch(getApiUrl('/api/ai/memory'), {
                headers: { 'Authorization': `Bearer ${state.token}` }
            });
            if (res.ok) {
                const data = await res.json();
                renderActivityFeed(data.recent_conversations || []);
                renderProceduralList(data.procedures || []);

                if (elements.prefGuestModeQuick) {
                    elements.prefGuestModeQuick.checked = Boolean(data.guest_mode);
                }
                if (elements.prefGuestMode) {
                    elements.prefGuestMode.checked = Boolean(data.guest_mode);
                }

                if (data.stats) {
                    if (elements.statZeroTokenQuick) elements.statZeroTokenQuick.textContent = data.stats.local_executions_zero_token || 0;
                    if (elements.statCloudCallsQuick) elements.statCloudCallsQuick.textContent = data.stats.cloud_ai_calls || 0;
                }
            }
        } catch (e) {
            console.warn('Errore lettura memorie attività:', e);
        }
    }

    function renderActivityFeed(conversations) {
        if (!elements.activityFeed) return;
        if (!conversations || conversations.length === 0) {
            elements.activityFeed.innerHTML = '<div class="loading-state">Nessuna conversazione recente registrata.</div>';
            return;
        }

        let html = '';
        conversations.forEach(item => {
            const dateStr = item.timestamp ? new Date(item.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '';
            let statusBadge = '<span class="ai-badge-status dialog">💬 Dialogo</span>';
            if (item.status === 'SUCCESS_VERIFIED') {
                statusBadge = '<span class="ai-badge-status verified">✓ Verificato</span>';
            } else if (item.status === 'COMPLETED_UNVERIFIED') {
                statusBadge = '<span class="ai-badge-status unverified">⚠️ Non verificato</span>';
            } else if (item.status === 'ERROR') {
                statusBadge = '<span class="ai-badge-status error">❌ Errore</span>';
            }

            html += `
                <div class="feed-item">
                    <div class="feed-header">
                        <span>${dateStr}</span>
                        ${statusBadge}
                    </div>
                    <div class="feed-query">«${escapeHtml(item.user_query)}»</div>
                    <div class="feed-reply">${escapeHtml(item.assistant_reply || '')}</div>
                </div>
            `;
        });
        elements.activityFeed.innerHTML = html;
    }

    function renderProceduralList(procedures) {
        const containers = [elements.proceduralList, elements.activityProceduralList].filter(Boolean);
        if (containers.length === 0) return;

        if (!procedures || procedures.length === 0) {
            containers.forEach(c => c.innerHTML = '<div class="loading-state">Nessuna procedura in memoria SQLite.</div>');
            return;
        }

        let html = '';
        procedures.forEach(p => {
            const isVerified = (p.success_count > 0 && p.last_verified > 0);
            const statusClass = isVerified ? 'proc-status' : 'proc-status unverified';
            const statusLabel = isVerified ? `✓ Verificato (${p.success_count} esecuzioni)` : 'Template iniziale (Non verificato)';
            const goal = p.goal_intent ? `Goal: "${p.goal_intent}"` : (p.description || p.intent_key);

            html += `
                <div class="procedural-item">
                    <div class="proc-info">
                        <span class="proc-title">${escapeHtml(p.intent_key)}</span>
                        <span class="proc-meta">${escapeHtml(goal)} • ${escapeHtml(p.app_package || 'Sistema TV')}</span>
                    </div>
                    <span class="${statusClass}">${statusLabel}</span>
                </div>
            `;
        });

        containers.forEach(c => c.innerHTML = html);
    }

    function escapeHtml(str) {
        if (!str) return '';
        return String(str).replace(/[&<>"']/g, m => ({
            '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
        })[m]);
    }

    // =========================================================================
    // ADVANCED SETTINGS MODAL & CONFIG LOADERS
    // =========================================================================

    async function loadAiConfig() {
        if (!state.token) return;
        try {
            const res = await fetch(getApiUrl('/api/ai/config'), {
                headers: { 'Authorization': `Bearer ${state.token}` }
            });
            if (res.ok) {
                const cfg = await res.json();

                // Provider & Execution Mode
                const effectiveProvider = (cfg.execution_mode === 'LOCAL_ONLY' || cfg.strict_local_only)
                    ? 'local'
                    : (cfg.active_provider || 'deepseek');
                const radios = document.getElementsByName('ai-provider');
                for (const r of radios) {
                    r.checked = (r.value === effectiveProvider);
                }

                // Model & Kimi Region
                if (cfg.active_model && elements.aiModelSelect) {
                    elements.aiModelSelect.value = (cfg.active_model === 'deepseek-chat') ? 'deepseek-flash' : cfg.active_model;
                }
                if (elements.aiKimiRegionSelect) {
                    elements.aiKimiRegionSelect.value = cfg.kimi_region || 'intl';
                }
                if (elements.chkCloudContextConsent) {
                    elements.chkCloudContextConsent.checked = (cfg.cloud_context_consent !== false);
                }

                // Masked API Keys
                if (elements.aiApiKeyInput) {
                    elements.aiApiKeyInput.value = (cfg.active_provider === 'kimi') ? (cfg.masked_kimi_key || '') : (cfg.masked_deepseek_key || '');
                }

                // Preferences
                if (cfg.preferences) {
                    if (elements.prefFavChannels) elements.prefFavChannels.value = cfg.preferences.favorite_channels || '';
                    if (elements.prefFavGenres) elements.prefFavGenres.value = cfg.preferences.favorite_genres || '';
                    if (elements.prefFavApps) elements.prefFavApps.value = cfg.preferences.favorite_apps || '';
                }

                // Stats
                if (cfg.stats) {
                    if (elements.statZeroToken) elements.statZeroToken.textContent = cfg.stats.local_executions_zero_token || 0;
                    if (elements.statCloudCalls) elements.statCloudCalls.textContent = cfg.stats.cloud_ai_calls || 0;
                    if (elements.statPromptTokens) elements.statPromptTokens.textContent = cfg.stats.prompt_tokens || 0;
                    if (elements.statCompletionTokens) elements.statCompletionTokens.textContent = cfg.stats.completion_tokens || 0;

                    if (elements.statZeroTokenQuick) elements.statZeroTokenQuick.textContent = cfg.stats.local_executions_zero_token || 0;
                    if (elements.statCloudCallsQuick) elements.statCloudCallsQuick.textContent = cfg.stats.cloud_ai_calls || 0;
                }

                // Budget Guard (5,00 € Max)
                if (cfg.budget) {
                    const spent = Number(cfg.budget.total_spent_eur || 0);
                    const limit = Number(cfg.budget.total_limit_eur || 5.0);
                    const rem = Number(cfg.budget.remaining_eur != null ? cfg.budget.remaining_eur : (limit - spent));
                    const warnLvl = Number(cfg.budget.warning_level || 0);
                    const warnMsg = cfg.budget.warning_message;

                    if (elements.budgetSpentVal) elements.budgetSpentVal.textContent = `${spent.toFixed(4)} €`;
                    if (elements.budgetSpentQuick) elements.budgetSpentQuick.textContent = `${spent.toFixed(2)} €`;
                    if (elements.budgetInflightVal) {
                        const inflight = Number(cfg.budget.in_flight_reserved_eur || 0);
                        elements.budgetInflightVal.textContent = `${inflight.toFixed(4)} €`;
                    }
                    if (elements.budgetRemainingVal) {
                        elements.budgetRemainingVal.textContent = `${rem.toFixed(2)} €`;
                        elements.budgetRemainingVal.className = 'metric-val ' + (warnLvl === 3 ? 'danger' : (warnLvl >= 1 ? 'highlight' : 'success'));
                    }
                    if (elements.budgetProgressFill) {
                        const pct = Math.min(100, Math.max(0, (spent / limit) * 100));
                        elements.budgetProgressFill.style.width = `${pct}%`;
                    }
                    if (elements.budgetStatusBadge) {
                        if (warnLvl === 3) {
                            elements.budgetStatusBadge.className = 'budget-status-pill danger';
                            elements.budgetStatusBadge.textContent = '🛑 Blocco Preventivo (5,00 €)';
                        } else if (warnLvl === 2) {
                            elements.budgetStatusBadge.className = 'budget-status-pill warn';
                            elements.budgetStatusBadge.textContent = '⚠️ Critico (≥ 4,00 €)';
                        } else if (warnLvl === 1) {
                            elements.budgetStatusBadge.className = 'budget-status-pill warn';
                            elements.budgetStatusBadge.textContent = '⚠️ Avviso (≥ 3,00 €)';
                        } else {
                            elements.budgetStatusBadge.className = 'budget-status-pill ok';
                            elements.budgetStatusBadge.textContent = '✓ Normale (< 3,00 €)';
                        }
                    }
                    if (elements.budgetAlertBox) {
                        if (warnMsg) {
                            elements.budgetAlertBox.textContent = warnMsg;
                            elements.budgetAlertBox.classList.remove('hidden');
                        } else {
                            elements.budgetAlertBox.classList.add('hidden');
                        }
                    }
                }
            }
        } catch (e) {
            console.warn('Errore lettura configurazione AI:', e);
        }
    }

    async function loadTtsConfig() {
        if (!state.token) return;
        try {
            const res = await fetch(getApiUrl('/api/ai/tts_config'), {
                headers: { 'Authorization': `Bearer ${state.token}` }
            });
            if (res.ok) {
                const cfg = await res.json();
                if (elements.aiVoiceSelect && cfg.active_voice) elements.aiVoiceSelect.value = cfg.active_voice;
                if (elements.azureRegionSelect && cfg.azure_region) elements.azureRegionSelect.value = cfg.azure_region;
                if (elements.azureSpeechKeyInput) elements.azureSpeechKeyInput.value = cfg.masked_azure_key || '';
                if (elements.ttsCacheSize) elements.ttsCacheSize.textContent = `${cfg.cache_size_kb || 0} KB / ${cfg.max_cache_mb || 8} MB`;
            }
        } catch (e) {
            console.warn('Errore caricamento TTS:', e);
        }
    }

    async function saveAiConfig() {
        if (!state.token) {
            showToast('Associazione richiesta', true);
            return;
        }

        const selectedRadio = document.querySelector('input[name="ai-provider"]:checked');
        const provider = selectedRadio ? selectedRadio.value : 'deepseek';
        const executionMode = (provider === 'local') ? 'LOCAL_ONLY' : 'CLOUD_OPTIONAL';
        const model = elements.aiModelSelect ? elements.aiModelSelect.value : 'deepseek-flash';
        const kimiRegion = elements.aiKimiRegionSelect ? elements.aiKimiRegionSelect.value : 'intl';
        const cloudContextConsent = elements.chkCloudContextConsent ? Boolean(elements.chkCloudContextConsent.checked) : true;
        const key = elements.aiApiKeyInput ? elements.aiApiKeyInput.value.trim() : '';

        const payload = {
            execution_mode: executionMode,
            provider,
            model,
            kimi_region: kimiRegion,
            cloud_context_consent: cloudContextConsent
        };
        if (key && !key.includes('••••')) {
            if (provider === 'kimi') {
                payload.kimi_key = key;
            } else if (provider === 'deepseek') {
                payload.deepseek_key = key;
            }
        }

        try {
            const res = await fetch(getApiUrl('/api/ai/config'), {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${state.token}`
                },
                body: JSON.stringify(payload)
            });
            let respData = null;
            try { respData = await res.json(); } catch (_) {}
            if (res.ok && (!respData || respData.success !== false)) {
                showToast('Configurazione AI salvata con successo!');
                loadAiConfig();
            } else {
                showToast((respData && respData.error) ? respData.error : 'Errore salvataggio AI', true);
            }
        } catch (e) {
            showToast('Errore di comunicazione', true);
        }
    }

    async function saveTtsConfig() {
        if (!state.token) return;
        const voice = elements.aiVoiceSelect ? elements.aiVoiceSelect.value : 'it-IT-DiegoNeural';
        const region = elements.azureRegionSelect ? elements.azureRegionSelect.value : 'westeurope';
        const key = elements.azureSpeechKeyInput ? elements.azureSpeechKeyInput.value.trim() : '';

        const payload = { voice, azure_region: region };
        if (key && !key.includes('••••')) payload.azure_key = key;

        try {
            const res = await fetch(getApiUrl('/api/ai/tts_config'), {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${state.token}`
                },
                body: JSON.stringify(payload)
            });
            if (res.ok) {
                showToast('Impostazioni vocali salvate!');
                loadTtsConfig();
            } else {
                showToast('Errore salvataggio vocale', true);
            }
        } catch (e) {
            showToast('Errore di comunicazione', true);
        }
    }

    async function previewVoice() {
        if (!state.token) return;
        const voice = elements.aiVoiceSelect ? elements.aiVoiceSelect.value : 'it-IT-DiegoNeural';
        const sampleText = voice.includes('Isabella') ?
            'Ciao, sono Isabella. Questa è la voce naturale dell\'assistente per la tua televisione AKAI.' :
            'Ciao, sono Diego. Questa è la voce naturale dell\'assistente per la tua televisione AKAI.';

        try {
            showToast(`Riproduzione anteprima (${voice})...`);
            const res = await fetch(getApiUrl('/api/ai/tts_preview'), {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${state.token}`
                },
                body: JSON.stringify({ voice, text: sampleText })
            });
            if (!res.ok) {
                showToast('Errore anteprima vocale sulla TV', true);
            }
        } catch (e) {
            showToast('Errore anteprima voce', true);
        }
    }

    async function clearAudioCache() {
        if (!state.token) return;
        try {
            const res = await fetch(getApiUrl('/api/ai/tts_cache_clear'), {
                method: 'POST',
                headers: { 'Authorization': `Bearer ${state.token}` }
            });
            if (res.ok) {
                showToast('Cache audio svuotata');
                loadTtsConfig();
            }
        } catch (e) {
            showToast('Errore svuotamento cache', true);
        }
    }

    async function testAiConnection() {
        if (!state.token) {
            showToast('Associazione richiesta', true);
            return;
        }

        const selectedRadio = document.querySelector('input[name="ai-provider"]:checked');
        const provider = selectedRadio ? selectedRadio.value : 'deepseek';
        const model = elements.aiModelSelect.value;
        const key = elements.aiApiKeyInput.value.trim();

        elements.testConnectionResult.textContent = 'Test in corso...';
        elements.testConnectionResult.className = 'test-result-label';
        elements.testConnectionResult.classList.remove('hidden');

        try {
            const payload = { provider, model };
            if (key && !key.includes('••••')) payload.api_key = key;

            const res = await fetch(getApiUrl('/api/ai/test_connection'), {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${state.token}`
                },
                body: JSON.stringify(payload)
            });

            const data = await res.json();
            if (res.ok && data.success) {
                elements.testConnectionResult.textContent = data.message;
                elements.testConnectionResult.className = 'test-result-label ok';
            } else {
                elements.testConnectionResult.textContent = data.message || 'Test fallito';
                elements.testConnectionResult.className = 'test-result-label err';
            }
        } catch (e) {
            elements.testConnectionResult.textContent = 'Errore di rete';
            elements.testConnectionResult.className = 'test-result-label err';
        }
    }

    async function testBudgetGuard() {
        if (!state.token) return;
        try {
            const res = await fetch(getApiUrl('/api/ai/simulate_budget'), {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${state.token}`
                },
                body: JSON.stringify({ test_type: 'concurrent_reservation' })
            });
            const data = await res.json();
            showToast(data.message || 'Test simulato completato (0 Token)');
        } catch (e) {
            showToast('Errore test budget guard', true);
        }
    }

    async function resetBudget() {
        if (!confirm('Vuoi azzerare il contatore spesa TV (es. dopo nuova ricarica)?')) return;
        try {
            const res = await fetch(getApiUrl('/api/ai/config'), {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${state.token}`
                },
                body: JSON.stringify({ reset_budget: true })
            });
            if (res.ok) {
                showToast('Contatore spesa azzerato');
                loadAiConfig();
            }
        } catch (e) {
            showToast('Errore azzeramento contatore', true);
        }
    }

    async function resetProceduralMemory() {
        if (!confirm('Vuoi ripristinare i template delle procedure? Le preferenze utente rimarranno intatte.')) return;
        try {
            const res = await fetch(getApiUrl('/api/ai/memory/clear'), {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${state.token}`
                },
                body: JSON.stringify({ target: 'procedures' })
            });
            if (res.ok) {
                showToast('Procedure ripristinate ai valori predefiniti');
                loadActivityData();
            }
        } catch (e) {
            showToast('Errore ripristino procedure', true);
        }
    }

    async function clearPersonalMemories() {
        if (!confirm('Vuoi cancellare tutte le preferenze personali e la cronologia conversazioni? Le procedure tecniche TV rimarranno intatte.')) return;
        try {
            const res = await fetch(getApiUrl('/api/ai/memory/clear_personal'), {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${state.token}`
                }
            });
            if (res.ok) {
                showToast('Dati personali e cronologia eliminati');
                loadAiConfig();
                loadActivityData();
            }
        } catch (e) {
            showToast('Errore durante la cancellazione', true);
        }
    }

    async function toggleGuestMode(enabled) {
        try {
            const res = await fetch(getApiUrl('/api/ai/guest_mode'), {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${state.token}`
                },
                body: JSON.stringify({ enabled })
            });
            if (res.ok) {
                showToast(enabled ? 'Modalità Ospite attiva: conversazioni non registrate' : 'Modalità Ospite disattivata');
                if (elements.prefGuestModeQuick) elements.prefGuestModeQuick.checked = enabled;
                if (elements.prefGuestMode) elements.prefGuestMode.checked = enabled;
            }
        } catch (e) {
            showToast('Errore cambio modalità ospite', true);
        }
    }

    async function saveUserPreferences() {
        if (!state.token) return;
        const payload = {
            preferences: {
                favorite_channels: elements.prefFavChannels ? elements.prefFavChannels.value.trim() : '',
                favorite_genres: elements.prefFavGenres ? elements.prefFavGenres.value.trim() : '',
                favorite_apps: elements.prefFavApps ? elements.prefFavApps.value.trim() : ''
            }
        };

        try {
            const res = await fetch(getApiUrl('/api/ai/config'), {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${state.token}`
                },
                body: JSON.stringify(payload)
            });
            if (res.ok) {
                showToast('Preferenze aggiornate con successo');
            } else {
                showToast('Errore aggiornamento preferenze', true);
            }
        } catch (e) {
            showToast('Errore di comunicazione', true);
        }
    }

    // =========================================================================
    // PAIRING MODAL & PIN AUTHENTICATION
    // =========================================================================

    async function openPairingModal() {
        elements.modalPairing.classList.remove('hidden');
        elements.pinInput.value = '';
        elements.pinInput.focus();
        elements.pairingError.classList.add('hidden');

        // Configure CA cert download link
        if (elements.btnDownloadCa) {
            elements.btnDownloadCa.href = `${state.proto}://${state.host}:${state.port}/api/auth/ca.crt`;
        }

        if (elements.caFpVal) {
            elements.caFpVal.textContent = state.caFingerprint || 'Richiesta impronta alla TV...';
        }

        try {
            // First try pair request which generates a fresh PIN on TV and returns fingerprint
            const reqRes = await fetch(getApiUrl('/api/auth/pair/request'), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ client: 'web_remote' })
            });
            if (reqRes.status === 426) {
                const reqData = await reqRes.json().catch(() => ({}));
                const httpsPort = reqData.https_port || '8443';
                const targetHost = state.host || location.hostname || '127.0.0.1';
                elements.pairingError.innerHTML = `Connessione non cifrata (HTTP). Per associare in sicurezza, scarica il certificato CA qui sotto e passa a HTTPS sulla porta ${httpsPort}: <a href="https://${targetHost}:${httpsPort}" target="_blank" style="color:var(--accent); text-decoration:underline;">https://${targetHost}:${httpsPort}</a>`;
                elements.pairingError.classList.remove('hidden');
                const infoRes = await fetch(getApiUrl('/api/auth/tls_info'));
                if (infoRes.ok) {
                    const infoData = await infoRes.json().catch(() => ({}));
                    if (infoData.ca_sha256) {
                        state.caFingerprint = infoData.ca_sha256;
                        if (elements.caFpVal) elements.caFpVal.textContent = state.caFingerprint;
                    }
                }
            } else if (reqRes.ok) {
                const reqData = await reqRes.json();
                if (reqData.ca_fingerprint_sha256) {
                    state.caFingerprint = reqData.ca_fingerprint_sha256;
                    if (elements.caFpVal) elements.caFpVal.textContent = state.caFingerprint;
                }
                if (reqData.expires_in && elements.pinCountdown) {
                    elements.pinCountdown.textContent = reqData.expires_in;
                }
            } else {
                const infoRes = await fetch(getApiUrl('/api/auth/tls_info'));
                if (infoRes.ok) {
                    const infoData = await infoRes.json();
                    if (infoData.ca_sha256) {
                        state.caFingerprint = infoData.ca_sha256;
                        if (elements.caFpVal) elements.caFpVal.textContent = state.caFingerprint;
                    }
                }
            }
        } catch (e) {
            console.warn('CA fingerprint lookup failed:', e);
            if (elements.caFpVal && !state.caFingerprint) {
                elements.caFpVal.textContent = 'Impronta visualizzata a schermo sulla TV';
            }
        }
    }

    async function submitPin() {
        const pin = elements.pinInput.value.trim();
        if (pin.length !== 6) {
            elements.pairingError.textContent = 'Inserisci un PIN numerico valido di 6 cifre';
            elements.pairingError.classList.remove('hidden');
            return;
        }

        // HTTPS must verify CA fingerprint. Classic HTTP LAN remote retains v5 PIN
        // compatibility; never use this path for AI credentials or voice capture.
        if (state.proto === 'https' && elements.chkConfirmCaTv && !elements.chkConfirmCaTv.checked) {
            elements.pairingError.textContent = "Conferma obbligatoria su HTTPS: confronta l'impronta mostrata sulla TV e spunta la casella prima di associare.";
            elements.pairingError.classList.remove('hidden');
            return;
        }

        elements.btnSubmitPin.disabled = true;
        elements.btnSubmitPin.textContent = 'Verifica in corso...';
        elements.pairingError.classList.add('hidden');

        try {
            const res = await fetch(getApiUrl('/api/auth/pair'), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    pin,
                    device_name: `${navigator.platform || 'Mobile'} - Web Remote v16`
                })
            });

            const data = await res.json().catch(() => ({}));
            if (res.status === 426 || (data && data.error === 'HTTPS_REQUIRED')) {
                const targetPort = data.https_port || '8443';
                const targetHost = state.host || location.hostname || '127.0.0.1';
                elements.pairingError.innerHTML = `Connessione sicura richiesta (HTTP 426). Passa a HTTPS: <a href="https://${targetHost}:${targetPort}" target="_blank" style="color:var(--accent); text-decoration:underline;">https://${targetHost}:${targetPort}</a>`;
                elements.pairingError.classList.remove('hidden');
                return;
            }

            if (res.ok && data.token) {
                state.token = data.token;
                localStorage.setItem('akai_token', state.token);
                setConnectionState('connected', 'Connesso');
                updateSettingsUI();
                elements.modalPairing.classList.add('hidden');
                showToast('Telecomando associato con successo alla TV!');
            } else {
                elements.pairingError.textContent = data.error || 'PIN non corretto o scaduto';
                elements.pairingError.classList.remove('hidden');
            }
        } catch (e) {
            elements.pairingError.textContent = 'Errore di connessione durante la verifica PIN';
            elements.pairingError.classList.remove('hidden');
        } finally {
            elements.btnSubmitPin.disabled = false;
            elements.btnSubmitPin.textContent = 'Associa Dispositivo';
        }
    }

    // P1-13: Honest session revocation
    async function revokeSession() {
        if (!state.token) return;
        let remoteRevoked = false;
        try {
            const res = await fetch(getApiUrl('/api/auth/revoke'), {
                method: 'POST',
                headers: { 'Authorization': `Bearer ${state.token}` }
            });
            remoteRevoked = res.ok;
        } catch (e) {}

        state.token = null;
        localStorage.removeItem('akai_token');
        setConnectionState('disconnected', 'Disassociato');
        updateSettingsUI();
        elements.modalSettings.classList.add('hidden');

        if (remoteRevoked) {
            showToast('Sessione revocata con successo');
        } else {
            showToast('Sessione rimossa localmente (TV non raggiungibile per revoca remota)');
        }
    }

    function updateSettingsUI() {
        if (elements.serverHost) elements.serverHost.value = state.host;
        if (elements.serverPort) elements.serverPort.value = state.port;
        const radios = document.getElementsByName('proto');
        for (const r of radios) {
            r.checked = (r.value === state.proto);
        }

        if (state.token) {
            if (elements.sessionBadge) {
                elements.sessionBadge.textContent = 'Attiva (Autenticato)';
                elements.sessionBadge.style.color = 'var(--mint)';
            }
            if (elements.btnRevokeSession) elements.btnRevokeSession.style.display = 'block';
        } else {
            if (elements.sessionBadge) {
                elements.sessionBadge.textContent = 'Nessuna associazione';
                elements.sessionBadge.style.color = 'var(--subtle)';
            }
            if (elements.btnRevokeSession) elements.btnRevokeSession.style.display = 'none';
        }
    }

    function saveSettings() {
        state.host = elements.serverHost.value.trim();
        state.port = elements.serverPort.value.trim();
        const radios = document.getElementsByName('proto');
        for (const r of radios) {
            if (r.checked) state.proto = r.value;
        }

        localStorage.setItem('akai_host', state.host);
        localStorage.setItem('akai_port', state.port);
        localStorage.setItem('akai_proto', state.proto);

        elements.modalSettings.classList.add('hidden');
        showToast('Impostazioni di connessione salvate');
        checkConnection();
    }

    // =========================================================================
    // EVENT BINDINGS
    // =========================================================================

    function bindEvents() {
        // Tab switching (Assistente, Telecomando, Attività)
        document.querySelectorAll('.nav-tab').forEach(btn => {
            btn.addEventListener('click', () => {
                const targetPage = btn.getAttribute('data-page');
                document.querySelectorAll('.nav-tab').forEach(b => {
                    b.classList.remove('active');
                    b.setAttribute('aria-selected', 'false');
                });
                document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));

                btn.classList.add('active');
                btn.setAttribute('aria-selected', 'true');
                const pageElem = document.getElementById(targetPage);
                if (pageElem) {
                    pageElem.classList.add('active');
                    window.scrollTo({ top: 0, behavior: 'instant' });
                }

                if (targetPage === 'page-activity') {
                    loadActivityData();
                    loadAiConfig();
                }
            });
        });

        // Jarvis Voice Orb & Actions
        if (elements.jarvisOrb) {
            elements.jarvisOrb.addEventListener('click', () => {
                if (convoSession.active) {
                    stopConversation();
                } else {
                    startConversation();
                }
            });
        }

        if (elements.btnOrbAction) {
            elements.btnOrbAction.addEventListener('click', () => {
                startConversation();
            });
        }

        if (elements.btnConvoStop) {
            elements.btnConvoStop.addEventListener('click', stopConversation);
        }

        if (elements.btnConvoTalkAgain) {
            elements.btnConvoTalkAgain.addEventListener('click', () => {
                try {
                    state.speechRecognition.start();
                } catch (e) {
                    console.warn(e);
                }
            });
        }

        // Single-shot mic button
        if (elements.btnVoiceAi) {
            elements.btnVoiceAi.addEventListener('click', toggleVoiceRecognition);
        }

        // AI Typing & Send
        if (elements.btnAiSend) {
            elements.btnAiSend.addEventListener('click', () => askAi());
        }
        if (elements.aiTextInput) {
            elements.aiTextInput.addEventListener('keydown', (e) => {
                if (e.key === 'Enter') askAi();
            });
        }

        // AI Retry button
        if (elements.btnRetryAi) {
            elements.btnRetryAi.addEventListener('click', () => {
                if (convoSession.lastQuery) {
                    askAi(convoSession.lastQuery);
                }
            });
        }

        // AI Active Task Stop button
        if (elements.btnAiStop) {
            elements.btnAiStop.addEventListener('click', () => {
                cancelBackendAiTask();
            });
        }

        // Quick command chips [data-ai]
        document.addEventListener('click', (e) => {
            const chip = e.target.closest('[data-ai]');
            if (!chip) return;
            const prompt = chip.getAttribute('data-ai');
            if (elements.aiTextInput) elements.aiTextInput.value = prompt;
            askAi(prompt);
        });

        // D-Pad and Remote Command Delegation [data-cmd]
        document.addEventListener('click', (e) => {
            const btn = e.target.closest('[data-cmd]');
            if (!btn) return;
            const cmd = btn.getAttribute('data-cmd');

            if (cmd === 'open_numpad') {
                if (elements.numpadPanel) elements.numpadPanel.classList.toggle('collapsed');
                return;
            }

            sendCommand(cmd);
        });

        // Numpad Keys
        document.querySelectorAll('.num-btn[data-key]').forEach(btn => {
            btn.addEventListener('click', () => {
                const key = btn.getAttribute('data-key');
                sendCommand(`num_${key}`);
            });
        });

        if (elements.btnCloseNumpad) {
            elements.btnCloseNumpad.addEventListener('click', () => {
                elements.numpadPanel.classList.add('collapsed');
            });
        }

        // Text typing send to TV
        if (elements.btnSendText) {
            elements.btnSendText.addEventListener('click', sendText);
        }
        if (elements.keyboardInput) {
            elements.keyboardInput.addEventListener('keydown', (e) => {
                if (e.key === 'Enter') sendText();
            });
        }

        // Power Standby
        if (elements.btnPower) {
            elements.btnPower.addEventListener('click', () => {
                if (confirm('Vuoi mettere la Smart TV in standby?')) {
                    sendCommand('power');
                }
            });
        }

        // Connection Pill click
        if (elements.connectionPill) {
            elements.connectionPill.addEventListener('click', () => {
                if (!state.token) {
                    openPairingModal();
                } else {
                    checkConnection();
                }
            });
        }

        // Settings Modal Open/Close
        if (elements.btnSettings) {
            elements.btnSettings.addEventListener('click', () => {
                updateSettingsUI();
                loadAiConfig();
                loadTtsConfig();
                loadActivityData();
                elements.modalSettings.classList.remove('hidden');
            });
        }
        if (elements.btnCloseSettings) {
            elements.btnCloseSettings.addEventListener('click', () => {
                elements.modalSettings.classList.add('hidden');
            });
        }

        // Settings Sub-Tabs
        document.querySelectorAll('.ai-tab-btn').forEach(btn => {
            btn.addEventListener('click', () => {
                document.querySelectorAll('.ai-tab-btn').forEach(b => {
                    b.classList.remove('active');
                    b.setAttribute('aria-selected', 'false');
                });
                document.querySelectorAll('.ai-tab-content').forEach(c => c.classList.remove('active'));
                btn.classList.add('active');
                btn.setAttribute('aria-selected', 'true');
                const targetId = btn.getAttribute('data-tab');
                const content = document.getElementById(targetId);
                if (content) content.classList.add('active');
            });
        });

        // Settings Action Buttons
        if (elements.btnSaveSettings) elements.btnSaveSettings.addEventListener('click', saveSettings);
        if (elements.btnRevokeSession) elements.btnRevokeSession.addEventListener('click', revokeSession);
        if (elements.btnSaveAiConfig) elements.btnSaveAiConfig.addEventListener('click', saveAiConfig);
        if (elements.btnTestAiConnection) elements.btnTestAiConnection.addEventListener('click', testAiConnection);
        if (elements.btnTestBudgetGuard) elements.btnTestBudgetGuard.addEventListener('click', testBudgetGuard);
        if (elements.btnResetBudget) elements.btnResetBudget.addEventListener('click', resetBudget);

        // Voice & TTS
        if (elements.btnSaveVoice) elements.btnSaveVoice.addEventListener('click', saveTtsConfig);
        if (elements.btnPreviewVoice) elements.btnPreviewVoice.addEventListener('click', previewVoice);
        if (elements.btnClearCache) elements.btnClearCache.addEventListener('click', clearAudioCache);

        // Procedural & Preferences
        if (elements.btnResetProcedural) elements.btnResetProcedural.addEventListener('click', resetProceduralMemory);
        if (elements.btnResetProceduralQuick) elements.btnResetProceduralQuick.addEventListener('click', resetProceduralMemory);
        if (elements.btnSavePrefs) elements.btnSavePrefs.addEventListener('click', saveUserPreferences);
        if (elements.btnClearPersonalPrefs) elements.btnClearPersonalPrefs.addEventListener('click', clearPersonalMemories);
        if (elements.btnClearPersonalPrefsQuick) elements.btnClearPersonalPrefsQuick.addEventListener('click', clearPersonalMemories);

        if (elements.prefGuestMode) {
            elements.prefGuestMode.addEventListener('change', (e) => toggleGuestMode(e.target.checked));
        }
        if (elements.prefGuestModeQuick) {
            elements.prefGuestModeQuick.addEventListener('change', (e) => toggleGuestMode(e.target.checked));
        }

        // Password visibility toggles
        if (elements.btnToggleKeyVisibility) {
            elements.btnToggleKeyVisibility.addEventListener('click', () => {
                const isPw = elements.aiApiKeyInput.type === 'password';
                elements.aiApiKeyInput.type = isPw ? 'text' : 'password';
                elements.btnToggleKeyVisibility.textContent = isPw ? '🔒' : '👁';
            });
        }
        if (elements.btnToggleAzureKey) {
            elements.btnToggleAzureKey.addEventListener('click', () => {
                const isPw = elements.azureSpeechKeyInput.type === 'password';
                elements.azureSpeechKeyInput.type = isPw ? 'text' : 'password';
                elements.btnToggleAzureKey.textContent = isPw ? '🔒' : '👁';
            });
        }

        // Auto-switch default model when provider radio changes
        document.querySelectorAll('input[name="ai-provider"]').forEach(r => {
            r.addEventListener('change', (e) => {
                const p = e.target.value;
                if (p === 'kimi') {
                    if (!elements.aiModelSelect.value.startsWith('kimi') && !elements.aiModelSelect.value.startsWith('moonshot')) {
                        elements.aiModelSelect.value = 'kimi-k2.6';
                    }
                } else if (p === 'deepseek') {
                    if (!elements.aiModelSelect.value.startsWith('deepseek')) {
                        elements.aiModelSelect.value = 'deepseek-flash';
                    }
                }
            });
        });

        // Pairing Modal Close & Submit
        if (elements.btnClosePairing) {
            elements.btnClosePairing.addEventListener('click', () => {
                elements.modalPairing.classList.add('hidden');
            });
        }
        if (elements.btnSubmitPin) {
            elements.btnSubmitPin.addEventListener('click', submitPin);
        }
        if (elements.pinInput) {
            elements.pinInput.addEventListener('input', (e) => {
                if (e.target.value.length === 6) {
                    submitPin();
                }
            });
        }

        // Anti-MITM CA Instructions Toggle
        if (elements.btnToggleCaInstructions && elements.caInstructionsPanel) {
            elements.btnToggleCaInstructions.addEventListener('click', () => {
                elements.caInstructionsPanel.classList.toggle('hidden');
            });
        }

        // Auto-switch port when changing protocol in settings
        document.querySelectorAll('input[name="proto"]').forEach(radio => {
            radio.addEventListener('change', (e) => {
                if (e.target.value === 'https') {
                    if (elements.serverPort && (elements.serverPort.value === '8088' || elements.serverPort.value === '8080')) {
                        elements.serverPort.value = '8443';
                    }
                } else if (e.target.value === 'http') {
                    if (elements.serverPort && elements.serverPort.value === '8443') {
                        elements.serverPort.value = '8088';
                    }
                }
            });
        });

        // Escape key to close modals
        window.addEventListener('keydown', (e) => {
            if (e.key === 'Escape') {
                if (elements.modalSettings) elements.modalSettings.classList.add('hidden');
                if (elements.modalPairing) elements.modalPairing.classList.add('hidden');
            }
        });
    }

    // Launch on DOM ready
    window.addEventListener('DOMContentLoaded', init);
})();
