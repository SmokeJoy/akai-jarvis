'use strict';

// Test the actual Web Remote speech functions without a browser, API keys or a TV.
// Phone voice is opt-in, Italian, localService-only and audible on the phone.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '..', 'akai-remote-web', 'app.js'), 'utf8');
const html = fs.readFileSync(path.join(__dirname, '..', 'akai-remote-web', 'index.html'), 'utf8');

function extract(name, asyncPrefix = false) {
    const startToken = '    ' + (asyncPrefix ? 'async ' : '') + 'function ' + name + '(';
    const start = source.indexOf(startToken);
    assert.ok(start >= 0, 'missing real Web function: ' + name);
    const end = source.indexOf('\n    }', start);
    assert.ok(end > start, 'missing closing brace for ' + name);
    return source.slice(start, end + '\n    }'.length);
}

const liveFunctions = [
    extract('getLocalItalianPhoneVoice'),
    extract('stopPhoneSpeech'),
    extract('speakPhoneReply'),
    extract('isHandledAiReply'),
    extract('isVerifiedAiReply'),
    extract('askAi', true)
].join('\n');

const reply = {
    success: false, status: 'ANSWERED_DIALOG', execution_outcome: 'NOT_TESTED',
    verified: false, reply: 'Certo, la TV è pronta.'
};
const italianOffline = { name: 'Italiano Migliorata', lang: 'it-IT', localService: true };
const italianRemote = { name: 'Italiano online', lang: 'it-IT', localService: false };
const englishOffline = { name: 'English Premium', lang: 'en-US', localService: true };

async function scenario({ enabled, voices, forceSpeak = true, data = reply, hasSynth = true }) {
    const requestBodies = [];
    const utterances = [];
    const seenReplies = [];
    let cancelCount = 0;
    const synth = {
        getVoices() { return voices; },
        speak(utter) { utterances.push(utter); },
        cancel() { cancelCount++; }
    };
    function SpeechSynthesisUtterance(text) { this.text = text; }
    const window = hasSynth ? { speechSynthesis: synth, SpeechSynthesisUtterance } : {};
    const elements = {
        aiTextInput: { value: '' },
        aiActiveLabel: { textContent: '' },
        aiActiveState: { classList: { remove() {}, add() {} } }
    };
    const state = { token: 'dummy-only', phoneVoiceEnabled: enabled };
    const convoSession = {
        active: false, aiAbortController: null, phoneSpeechResolve: null,
        phoneSpeechPromise: null, userCancelRequested: false
    };
    const sandbox = {
        window, state, convoSession, elements, AbortController,
        setTimeout, clearTimeout, triggerHaptic() {},
        getApiUrl(pathname) { return 'https://test.invalid' + pathname; },
        fetch: async (_url, options) => {
            requestBodies.push(JSON.parse(options.body));
            return { status: 400, ok: false, json: async () => data };
        },
        displayAiResponse(data) { seenReplies.push(data.reply); },
        showToast() {}, openPairingModal() {}, handleSessionExpired() {}
    };
    const exposed = vm.runInNewContext(liveFunctions +
        '\n({ askAi, getLocalItalianPhoneVoice, stopPhoneSpeech, speakPhoneReply })',
        sandbox);
    const returned = await exposed.askAi('Prova voce', forceSpeak);
    return { returned, requestBodies, utterances, seenReplies, state, convoSession,
        exposed, get cancelCount() { return cancelCount; } };
}

async function main() {
    assert.match(html, /id="phone-voice-toggle"/);
    assert.match(html, /id="btn-preview-phone-voice"/);
    assert.match(html, /NON sugli altoparlanti della TV/);
    assert.ok(source.includes('phoneVoiceEnabled: false'), 'phone audio must default OFF');

    const local = await scenario({
        enabled: true, voices: [italianRemote, englishOffline, italianOffline]
    });
    assert.equal(local.returned, true, 'a dialog response remains valid without TV verification');
    assert.equal(local.requestBodies.length, 1, 'no extra paid or voice API');
    assert.equal(local.requestBodies[0].speak, false, 'TV eSpeak must not double-speak');
    assert.equal(local.utterances.length, 1, 'phone voice is used when explicitly enabled');
    assert.equal(local.utterances[0].voice.name, italianOffline.name);
    assert.equal(local.utterances[0].lang, 'it-IT');
    const phoneWait = local.convoSession.phoneSpeechPromise;
    assert.ok(phoneWait, 'voice lifecycle is observable for microphone resume');
    local.utterances[0].onend();
    await phoneWait;

    const defaultOff = await scenario({ enabled: false, voices: [italianOffline] });
    assert.equal(defaultOff.requestBodies[0].speak, true);
    assert.equal(defaultOff.utterances.length, 0);

    const unapprovedNetworkVoice = await scenario({
        enabled: true, voices: [italianRemote]
    });
    assert.equal(unapprovedNetworkVoice.requestBodies[0].speak, true);
    assert.equal(unapprovedNetworkVoice.utterances.length, 0);

    const wrongLanguage = await scenario({ enabled: true, voices: [englishOffline] });
    assert.equal(wrongLanguage.requestBodies[0].speak, true);

    const noSpeechApi = await scenario({
        enabled: true, voices: [italianOffline], hasSynth: false
    });
    assert.equal(noSpeechApi.requestBodies[0].speak, true);

    const silentRequest = await scenario({
        enabled: true, voices: [italianOffline], forceSpeak: false
    });
    assert.equal(silentRequest.requestBodies[0].speak, false);
    assert.equal(silentRequest.utterances.length, 0);

    const cancelledReply = await scenario({
        enabled: true, voices: [italianOffline],
        data: { success: false, status: 'CANCELLED', reply: 'Stop richiesto.' }
    });
    assert.equal(cancelledReply.utterances.length, 0, 'STOP must never be vocalized as success');

    const active = await scenario({ enabled: true, voices: [italianOffline] });
    const wait = active.convoSession.phoneSpeechPromise;
    active.exposed.stopPhoneSpeech();
    await wait;
    assert.equal(active.cancelCount >= 1, true, 'explicit STOP cancels browser audio');
    assert.equal(active.convoSession.phoneSpeechPromise, null);

    const prioritized = await scenario({
        enabled: true,
        voices: [
            { name: 'Italiano Normale', lang: 'it-IT', localService: true },
            italianOffline
        ]
    });
    assert.equal(prioritized.utterances[0].voice.name, italianOffline.name,
        'prefer already installed enhanced Italian voice');
    prioritized.exposed.stopPhoneSpeech();

    console.log('Web local Italian voice PASS: 10 opt-in/fallback/STOP checks (no device or cloud)');
}

main().catch(err => { console.error(err); process.exitCode = 1; });
