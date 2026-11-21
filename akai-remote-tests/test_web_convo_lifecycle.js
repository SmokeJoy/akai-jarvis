'use strict';

// Conversation lifecycle state machine regression test (zero TV/cloud calls).
// Extracts the actual Web Remote functions from akai-remote-web/app.js.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(
    path.join(__dirname, '..', 'akai-remote-web', 'app.js'),
    'utf8'
);

function extractFunction(name, asyncPrefix = false) {
    const decl = `    ${asyncPrefix ? 'async ' : ''}function ${name}(`;
    const start = source.indexOf(decl);
    assert.ok(start >= 0, `missing function ${name}`);
    const end = source.indexOf('\n    }', start);
    assert.ok(end > start, `missing closing brace for ${name}`);
    return source.slice(start, end + '\n    }'.length);
}

const bundle = [
    extractFunction('setJarvisState'),
    extractFunction('resetInactivityTimer'),
    extractFunction('startConversation'),
    extractFunction('cancelBackendAiTask', true),
    extractFunction('stopConversation'),
    extractFunction('commitTurn', true),
    extractFunction('handleTvSpeechTurn', true),
    extractFunction('getLocalItalianPhoneVoice'),
    extractFunction('speakPhoneReply'),
    extractFunction('stopPhoneSpeech'),
    extractFunction('isHandledAiReply'),
    extractFunction('isVerifiedAiReply'),
    extractFunction('classifyTurnContinuation'),
    extractFunction('askAi', true),
    extractFunction('displayAiResponse')
].join('\n');

const JarvisConvoState = {
    IDLE: 'IDLE',
    READY: 'READY',
    LISTENING: 'LISTENING',
    THINKING: 'THINKING',
    SPEAKING: 'SPEAKING',
    ERROR: 'ERROR'
};

function makeClassList(initialHidden = false) {
    const set = new Set(initialHidden ? ['hidden'] : []);
    return {
        add(c) { set.add(c); },
        remove(c) { set.delete(c); },
        contains(c) { return set.has(c); }
    };
}

function createHarness({ fetchImpl, voices = [], phoneVoiceEnabled = false } = {}) {
    const states = [];
    const timerCalls = [];
    const speechRequests = [];
    const cancelRequests = [];
    const spokenUtterances = [];
    let micStarts = 0;
    let micStops = 0;
    let nextTimerId = 1;
    let sessionExpiredCalled = false;

    const elements = {
        jarvisStateBadge: { textContent: '' },
        jarvisOrb: { className: '', setAttribute() {} },
        jarvisLiveTranscript: { textContent: '', classList: makeClassList() },
        jarvisConvoControls: { classList: makeClassList(true) },
        btnOrbAction: { classList: makeClassList(false) },
        btnConvoTalkAgain: { classList: makeClassList(true) },
        btnVoiceAi: { classList: makeClassList() },
        aiTextInput: { value: '' },
        aiActiveLabel: { textContent: '' },
        aiActiveState: { classList: makeClassList(true) },
        aiResponseText: { textContent: '' },
        aiBadgeSource: { className: '', textContent: '' },
        aiBadgeStatus: { className: '', textContent: '' },
        aiBadgeMeta: { textContent: '' },
        aiResponseBox: { classList: makeClassList(true) },
        aiRetryBox: { classList: makeClassList(true) }
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
        lastQuery: '',
        lastTurnContinuation: null,
        phoneSpeechPromise: null,
        phoneSpeechResolve: null,
        userCancelRequested: false
    };

    const state = {
        token: 'test-token',
        isListening: false,
        phoneVoiceEnabled,
        speechRecognition: {
            start() { micStarts++; state.isListening = true; },
            stop() { micStops++; state.isListening = false; }
        }
    };

    function SpeechSynthesisUtterance(text) {
        this.text = text;
        spokenUtterances.push(this);
    }

    const windowObj = {
        speechSynthesis: {
            getVoices() { return voices; },
            speak(u) { spokenUtterances.push(u); },
            cancel() {}
        },
        SpeechSynthesisUtterance
    };

    const rawSetJarvisState = null;
    const context = {
        JarvisConvoState,
        convoSession,
        elements,
        state,
        window: windowObj,
        AbortController,
        console,
        triggerHaptic() {},
        showToast() {},
        openPairingModal() {},
        loadAiConfig() {},
        handleSessionExpired() { sessionExpiredCalled = true; state.token = null; },
        getApiUrl(p) { return 'https://tv.test.invalid' + p; },
        setTimeout(fn, ms) {
            const id = nextTimerId++;
            timerCalls.push({ id, ms });
            if (ms === 400) {
                // Deterministic fast poll step without 16s wall wait.
                setImmediate(fn);
                return id;
            }
            return id;
        },
        clearTimeout() {},
        fetch: async (url, options = {}) => {
            if (url.endsWith('/api/ai/speech_status')) {
                const idx = speechRequests.length;
                speechRequests.push(url);
                return fetchImpl ? await fetchImpl(url, options, idx) : {
                    ok: true, status: 200,
                    json: async () => ({ speaking: idx === 0, speech_state: idx === 0 ? 'PLAYING' : 'IDLE' })
                };
            }
            if (url.endsWith('/api/ai/cancel')) {
                cancelRequests.push(url);
                return { ok: true, status: 200, json: async () => ({ active_task_cancelled: true }) };
            }
            return await fetchImpl(url, options);
        }
    };

    const exposed = vm.runInNewContext(
        bundle + '\n({ startConversation, stopConversation, commitTurn, handleTvSpeechTurn, askAi, classifyTurnContinuation, setJarvisState })',
        context
    );

    // Spy on setJarvisState transitions while keeping exact implementation
    const origSet = context.setJarvisState;
    context.setJarvisState = function (newState, label, orbClass) {
        states.push({ state: newState, label });
        return origSet(newState, label, orbClass);
    };

    return {
        exposed, convoSession, elements, state, states, timerCalls,
        speechRequests, cancelRequests, spokenUtterances,
        get micStarts() { return micStarts; },
        get micStops() { return micStops; },
        get sessionExpiredCalled() { return sessionExpiredCalled; }
    };
}

async function run() {
    // 1. COMPLETED_UNVERIFIED / COMMAND_SENT must advance speech polling -> READY and unlock turn
    {
        let askReturn = null;
        const h = createHarness({
            fetchImpl: async (url, _opts, idx) => {
                if (url.endsWith('/api/ai/speech_status')) {
                    return {
                        ok: true, status: 200,
                        json: async () => ({ speaking: idx === 0, speech_state: idx === 0 ? 'PLAYING' : 'IDLE' })
                    };
                }
                return {
                    ok: false, status: 400,
                    json: async () => ({
                        success: false,
                        status: 'COMPLETED_UNVERIFIED',
                        verified: false,
                        execution_outcome: 'COMMAND_SENT',
                        reply: 'Ho aperto YouTube, obiettivo finale non verificato.'
                    })
                };
            }
        });
        const origAsk = h.exposed.askAi;
        // Direct askAi contract check stays false while continuation advances conversation
        h.exposed.startConversation();
        h.convoSession.turnLocked = true;
        const turnId = ++h.convoSession.currentTurnId;
        await h.exposed.commitTurn('Apri YouTube', turnId);
        askReturn = await origAsk('Apri YouTube', false);

        assert.equal(askReturn, false, 'askAi return value must stay false for COMPLETED_UNVERIFIED');
        assert.match(h.elements.aiBadgeStatus.textContent, /Non Verificato/);
        assert.deepEqual(h.states.map(s => s.state), [
            JarvisConvoState.THINKING,
            JarvisConvoState.SPEAKING,
            JarvisConvoState.READY
        ]);
        assert.equal(h.convoSession.turnLocked, false, 'turnLocked must be cleared cleanly');
        assert.equal(h.convoSession.state, JarvisConvoState.READY);
        assert.ok(h.speechRequests.length >= 2, 'must poll /api/ai/speech_status until IDLE');
        assert.equal(h.micStarts, 2, 'initial startConversation + reopen mic after speech');
        assert.ok(h.timerCalls.some(t => t.ms === 25000), 'inactivity timer must be armed');
    }

    // 2. SUCCESS_VERIFIED / STATE_VERIFIED normal full cycle
    {
        const h = createHarness({
            fetchImpl: async (url, _opts, idx) => {
                if (url.endsWith('/api/ai/speech_status')) {
                    return {
                        ok: true, status: 200,
                        json: async () => ({ speaking: idx === 0, speech_state: idx === 0 ? 'PLAYING' : 'IDLE' })
                    };
                }
                return {
                    ok: true, status: 200,
                    json: async () => ({
                        success: true, status: 'SUCCESS_VERIFIED',
                        verified: true, execution_outcome: 'STATE_VERIFIED',
                        reply: 'YouTube aperto.'
                    })
                };
            }
        });
        h.exposed.startConversation();
        h.convoSession.turnLocked = true;
        await h.exposed.commitTurn('Apri YouTube', ++h.convoSession.currentTurnId);
        assert.deepEqual(h.states.map(s => s.state), [
            JarvisConvoState.THINKING,
            JarvisConvoState.SPEAKING,
            JarvisConvoState.READY
        ]);
        assert.equal(h.convoSession.turnLocked, false);
        assert.equal(h.micStarts, 2);
    }

    // 3. Handled ERROR with reply vs network failure / BUDGET_EXCEEDED / 426 never hang on THINKING
    for (const errCase of [
        { name: 'handled ERROR with reply', status: 400, body: { success: false, status: 'ERROR', execution_outcome: 'FAILED', reply: 'Impossibile aprire il browser.' }, expectSpeak: true },
        { name: 'BUDGET_EXCEEDED silent', status: 200, body: { success: false, status: 'BUDGET_EXCEEDED', execution_outcome: 'FAILED', reply: 'Budget esaurito.' }, expectSpeak: false },
        { name: 'HTTP 426 TLS upgrade', status: 426, body: { error: 'HTTPS_REQUIRED' }, expectSpeak: false },
        { name: 'network throw', throwErr: new Error('ECONNREFUSED'), expectSpeak: false },
        { name: 'client AbortError timeout', throwErr: Object.assign(new Error('Aborted'), { name: 'AbortError' }), expectSpeak: false }
    ]) {
        const h = createHarness({
            fetchImpl: async (url, _opts, idx) => {
                if (url.endsWith('/api/ai/speech_status')) {
                    return { ok: true, status: 200, json: async () => ({ speaking: idx === 0, speech_state: idx === 0 ? 'PLAYING' : 'IDLE' }) };
                }
                if (errCase.throwErr) throw errCase.throwErr;
                return { ok: errCase.status >= 200 && errCase.status < 300, status: errCase.status, json: async () => errCase.body };
            }
        });
        h.exposed.startConversation();
        h.convoSession.turnLocked = true;
        await h.exposed.commitTurn('Test error recovery', ++h.convoSession.currentTurnId);
        assert.equal(h.convoSession.state, JarvisConvoState.READY, `${errCase.name}: must exit THINKING to READY`);
        assert.equal(h.convoSession.turnLocked, false, `${errCase.name}: turnLocked must unlock`);
        assert.ok(h.timerCalls.some(t => t.ms === 25000), `${errCase.name}: inactivity timer must re-arm`);
        if (errCase.expectSpeak) {
            assert.equal(h.states.includes(h.states.find(s => s.state === JarvisConvoState.SPEAKING)), true);
        } else {
            assert.equal(h.states.some(s => s.state === JarvisConvoState.SPEAKING), false, `${errCase.name}: must not enter SPEAKING`);
            assert.equal(h.elements.btnConvoTalkAgain.classList.contains('hidden'), false, `${errCase.name}: talk-again control must show`);
        }
    }

    // 4. Backend CANCELLED exits THINKING cleanly without SPEAKING
    {
        const h = createHarness({
            fetchImpl: async () => ({
                ok: false, status: 400,
                json: async () => ({ success: false, status: 'CANCELLED', reply: 'Operazione annullata.' })
            })
        });
        h.exposed.startConversation();
        h.convoSession.turnLocked = true;
        await h.exposed.commitTurn('Apri app', ++h.convoSession.currentTurnId);
        assert.equal(h.convoSession.state, JarvisConvoState.READY);
        assert.equal(h.convoSession.turnLocked, false);
        assert.equal(h.speechRequests.length, 0, 'cancelled turn must not wait for TV speech');
        assert.equal(h.states.some(s => s.state === JarvisConvoState.SPEAKING), false);
    }

    // 5. Explicit STOP + Turn ID Race Guard: stale Turn 1 resolving during Turn 2 must be ignored
    {
        let resolveTurn1;
        let callIdx = 0;
        const h = createHarness({
            fetchImpl: async (url) => {
                if (url.endsWith('/api/ai/speech_status')) {
                    return { ok: true, status: 200, json: async () => ({ speaking: false, speech_state: 'IDLE' }) };
                }
                callIdx++;
                if (callIdx === 1) {
                    return await new Promise(res => { resolveTurn1 = res; });
                }
                return {
                    ok: true, status: 200,
                    json: async () => ({ success: true, status: 'SUCCESS_VERIFIED', verified: true, execution_outcome: 'STATE_VERIFIED', reply: 'OK 2' })
                };
            }
        });
        h.exposed.startConversation();
        h.convoSession.turnLocked = true;
        const turn1Id = ++h.convoSession.currentTurnId;
        const turn1Promise = h.exposed.commitTurn('Comando uno lento', turn1Id);

        assert.equal(h.convoSession.state, JarvisConvoState.THINKING);
        h.exposed.stopConversation();
        assert.equal(h.convoSession.state, JarvisConvoState.IDLE);
        assert.equal(h.convoSession.active, false);
        assert.equal(h.cancelRequests.length, 1);

        // User starts fresh conversation while stale turn 1 later settles
        h.exposed.startConversation();
        const freshTurnId = h.convoSession.currentTurnId;
        h.convoSession.turnLocked = true;
        const turn2Promise = h.exposed.commitTurn('Comando due veloce', ++h.convoSession.currentTurnId);
        await turn2Promise;
        const micStartsAfterTurn2 = h.micStarts;
        assert.equal(h.convoSession.state, JarvisConvoState.READY);

        resolveTurn1({
            ok: false, status: 400,
            json: async () => ({ success: false, status: 'COMPLETED_UNVERIFIED', execution_outcome: 'COMMAND_SENT', reply: 'Tardo 1' })
        });
        await turn1Promise;
        assert.equal(h.micStarts, micStartsAfterTurn2, 'stale Turn 1 resolution must not touch Turn 2 mic');
        assert.equal(h.elements.aiResponseText.textContent, 'OK 2', 'stale Turn 1 must not overwrite Turn 2 reply');
        assert.equal(h.convoSession.state, JarvisConvoState.READY);
        assert.notEqual(h.convoSession.currentTurnId, freshTurnId);
    }

    // 6. Phone voice opt-in with COMPLETED_UNVERIFIED waits for phone speech, skips TV speech polling
    {
        const italianOffline = { name: 'Italiano', lang: 'it-IT', localService: true };
        const h = createHarness({
            phoneVoiceEnabled: true,
            voices: [italianOffline],
            fetchImpl: async () => ({
                ok: false, status: 400,
                json: async () => ({
                    success: false,
                    status: 'COMPLETED_UNVERIFIED',
                    verified: false,
                    execution_outcome: 'COMMAND_SENT',
                    reply: 'Fatto sulla TV.'
                })
            })
        });
        h.exposed.startConversation();
        h.convoSession.turnLocked = true;
        const turnPromise = h.exposed.commitTurn('Alza il volume', ++h.convoSession.currentTurnId);
        // Wait a microtask tick so fetch resolves and speakPhoneReply installs promise
        await new Promise(r => setImmediate(r));
        assert.ok(h.convoSession.phoneSpeechPromise, 'phoneSpeechPromise should be created for COMPLETED_UNVERIFIED');
        assert.equal(h.spokenUtterances.length >= 1, true);
        h.spokenUtterances[0].onend();
        await turnPromise;
        assert.equal(h.speechRequests.length, 0, 'must skip /api/ai/speech_status when spoken by phone');
        assert.equal(h.convoSession.state, JarvisConvoState.READY);
        assert.equal(h.convoSession.turnLocked, false);
    }

    // 7. HTTP 401 session expiry cleanly closes conversation
    {
        const h = createHarness({
            fetchImpl: async () => ({ ok: false, status: 401, json: async () => ({ error: 'Unauthorized' }) })
        });
        h.exposed.startConversation();
        h.convoSession.turnLocked = true;
        await h.exposed.commitTurn('Test auth', ++h.convoSession.currentTurnId);
        assert.equal(h.sessionExpiredCalled, true);
        assert.equal(h.convoSession.active, false);
        assert.equal(h.convoSession.state, JarvisConvoState.IDLE);
        assert.equal(h.convoSession.turnLocked, false);
    }

    console.log('test_web_convo_lifecycle PASS: 11 conversation lifecycle, error, STOP and turnId-race cases OK');
}

run().catch(err => {
    console.error(err);
    process.exitCode = 1;
});
