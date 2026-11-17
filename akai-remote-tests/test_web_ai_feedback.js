'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(
    path.join(__dirname, '..', 'akai-remote-web', 'app.js'), 'utf8');

function extractFunction(name, asyncFunction = false) {
    const declaration = `    ${asyncFunction ? 'async ' : ''}function ${name}(`;
    const start = source.indexOf(declaration);
    assert.ok(start >= 0, `missing ${name}`);
    // All three functions are directly nested inside the top-level IIFE;
    // only their closing brace uses exactly four spaces of indentation.
    const closing = '\n    }';
    const end = source.indexOf(closing, start);
    assert.ok(end > start, `missing closing brace for ${name}`);
    return source.slice(start, end + closing.length);
}

const functions = [
    extractFunction('isHandledAiReply'),
    extractFunction('isVerifiedAiReply'),
    extractFunction('askAi', true),
    extractFunction('displayAiResponse')
].join('\n');

function fakeClassList() {
    return { add() {}, remove() {} };
}

async function scenario(httpStatus, responseBody) {
    const messages = [];
    let expired = false;
    let requestedTimeoutMs = 0;
    const elements = {
        aiTextInput: { value: '' },
        aiActiveLabel: { textContent: '' },
        aiActiveState: { classList: fakeClassList() },
        aiResponseText: { textContent: '' },
        aiBadgeSource: { className: '', textContent: '' },
        aiBadgeStatus: { className: '', textContent: '' },
        aiBadgeMeta: { textContent: '' },
        aiResponseBox: { classList: fakeClassList() },
        aiRetryBox: { classList: fakeClassList() }
    };
    const context = {
        elements,
        state: { token: 'test-only', isListening: false },
        convoSession: { active: false, aiAbortController: null, userCancelRequested: false },
        AbortController,
        setTimeout(_callback, ms) { requestedTimeoutMs = ms; return 1; },
        clearTimeout() {},
        triggerHaptic() {},
        getApiUrl() { return 'https://test.invalid/api/ai/ask'; },
        fetch: async () => ({
            status: httpStatus,
            ok: httpStatus >= 200 && httpStatus < 300,
            json: async () => responseBody
        }),
        showToast(text, isError) { messages.push({ text, isError }); },
        openPairingModal() { throw new Error('unexpected pairing'); },
        handleSessionExpired() { expired = true; },
        loadAiConfig() {}
    };
    const exposed = vm.runInNewContext(
        functions + '\n({ askAi, displayAiResponse, isHandledAiReply })',
        context
    );
    const returned = await exposed.askAi('Apri YouTube', false);
    return { returned, elements, messages, expired, requestedTimeoutMs };
}

// Real client functions under mocked configuration responses; no API/cloud call.
async function verifyConsentUi() {
    const loadSource = extractFunction('loadAiConfig', true) + '\nloadAiConfig';
    for (const cfg of [{}, { cloud_context_consent: false }, { cloud_context_consent: true }]) {
        const checkbox = { checked: true };
        const sandbox = {
            state: { token: 'test-only' },
            elements: { chkCloudContextConsent: checkbox },
            document: { getElementsByName() { return []; } },
            getApiUrl() { return 'https://test.invalid/api/ai/config'; },
            fetch: async () => ({ ok: true, json: async () => cfg }),
            console
        };
        const load = vm.runInNewContext(loadSource, sandbox);
        await load();
        assert.equal(checkbox.checked, cfg.cloud_context_consent === true,
            'missing or false cloud consent must display as unchecked');
    }

    const saveSource = extractFunction('saveAiConfig', true) + '\nsaveAiConfig';
    for (const checkbox of [undefined, { checked: true }]) {
        let saved = null;
        const sandbox = {
            state: { token: 'test-only' },
            elements: checkbox ? { chkCloudContextConsent: checkbox } : {},
            document: { querySelector() { return null; } },
            getApiUrl() { return 'https://test.invalid/api/ai/config'; },
            fetch: async (_url, options) => {
                saved = JSON.parse(options.body);
                return { ok: true, json: async () => ({ success: true }) };
            },
            showToast() {},
            loadAiConfig() {},
            console
        };
        const save = vm.runInNewContext(saveSource, sandbox);
        await save();
        assert.equal(saved.cloud_context_consent, Boolean(checkbox && checkbox.checked),
            'absent consent control must not silently opt the owner in');
    }
}

async function run() {
    const verified = await scenario(200, {
        success: true, status: 'SUCCESS_VERIFIED', verified: true,
        execution_outcome: 'STATE_VERIFIED', reply: 'YouTube aperto e verificato'
    });
    assert.equal(verified.returned, true);
    assert.equal(verified.requestedTimeoutMs, 135000,
        'web timeout must exceed the backend 2-minute autonomous task deadline');
    assert.equal(verified.elements.aiBadgeStatus.textContent, '✓ Verificato');

    const unverified = await scenario(400, {
        success: false, status: 'COMPLETED_UNVERIFIED', verified: false,
        execution_outcome: 'COMMAND_SENT',
        reply: 'YouTube aperto, obiettivo finale non verificato.'
    });
    assert.equal(unverified.returned, false);
    assert.match(unverified.elements.aiBadgeStatus.textContent, /Non Verificato/);
    assert.equal(unverified.elements.aiResponseText.textContent,
        'YouTube aperto, obiettivo finale non verificato.');

    const failed = await scenario(400, {
        success: false, status: 'ERROR', verified: false,
        execution_outcome: 'FAILED', reply: 'Click non riuscito: target assente.'
    });
    assert.equal(failed.elements.aiResponseText.textContent, 'Click non riuscito: target assente.');
    assert.match(failed.elements.aiBadgeStatus.textContent, /Non Riuscito/);

    const inconsistent = await scenario(400, {
        success: false, status: 'COMPLETED_UNVERIFIED', verified: false,
        execution_outcome: 'FAILED', reply: 'Nessuna azione riuscita.'
    });
    assert.match(inconsistent.elements.aiBadgeStatus.textContent, /Non Riuscito/,
        'failed action must not be labelled command sent');

    const cancelled = await scenario(400, {
        success: false, status: 'CANCELLED', verified: false,
        execution_outcome: 'FAILED', reply: 'Task interrotto dal proprietario.'
    });
    assert.match(cancelled.elements.aiBadgeStatus.textContent, /Annullato/);

    const answeredDialog = await scenario(400, {
        success: false, status: 'ANSWERED_DIALOG',
        execution_outcome: 'NOT_TESTED', reply: 'Ecco la risposta richiesta.'
    });
    assert.equal(answeredDialog.returned, true,
        'spoken conversational answers should continue a live voice session');
    assert.match(answeredDialog.elements.aiBadgeStatus.textContent, /Risposta/);

    const answeredWithoutTvSuccess = await scenario(400, {
        success: false, status: 'ANSWERED_DIALOG', verified: false,
        execution_outcome: 'NOT_TESTED', reply: 'Risposta conversazionale senza azioni TV.'
    });
    assert.equal(answeredWithoutTvSuccess.returned, true,
        'a valid conversational answer must not require hardware verification');
    assert.match(answeredWithoutTvSuccess.elements.aiBadgeStatus.textContent, /Risposta/);

    const contradictoryVerified = await scenario(400, {
        success: true, status: 'SUCCESS_VERIFIED', verified: true,
        execution_outcome: 'FAILED', reply: 'Incoerenza nel risultato.'
    });
    assert.equal(contradictoryVerified.returned, false,
        'FAILED must never be a successful voice turn');
    assert.match(contradictoryVerified.elements.aiBadgeStatus.textContent, /Non Riuscito/);

    const spoofedVerifiedFlag = await scenario(200, {
        success: false, status: 'ERROR', verified: true,
        execution_outcome: 'COMMAND_SENT', reply: 'Esito contraddittorio.'
    });
    assert.equal(spoofedVerifiedFlag.returned, false,
        'verified=true without STATE_VERIFIED must not advance voice session');
    assert.match(spoofedVerifiedFlag.elements.aiBadgeStatus.textContent, /Non Riuscito/);

    const spoofedSuccessStatus = await scenario(200, {
        success: false, status: 'SUCCESS_VERIFIED', verified: false,
        execution_outcome: 'COMMAND_SENT', reply: 'Stato incoerente.'
    });
    assert.equal(spoofedSuccessStatus.returned, false);
    assert.match(spoofedSuccessStatus.elements.aiBadgeStatus.textContent, /Non Riuscito/);

    const contradictedDialog = await scenario(400, {
        success: false, status: 'ANSWERED_DIALOG', verified: false,
        execution_outcome: 'FAILED', reply: 'Risposta non attendibile.'
    });
    assert.equal(contradictedDialog.returned, false,
        'failed dialog must not resume the voice conversation');
    assert.match(contradictedDialog.elements.aiBadgeStatus.textContent, /Non Riuscito/);

    const contradictedUnverified = await scenario(200, {
        success: true, status: 'COMPLETED_UNVERIFIED', verified: false,
        execution_outcome: 'COMMAND_SENT', reply: 'Comando senza prova.'
    });
    assert.equal(contradictedUnverified.returned, false);
    assert.match(contradictedUnverified.elements.aiBadgeStatus.textContent, /Non Riuscito/);

    const memoryHandled = await scenario(200, {
        success: true, status: 'MEMORY_HANDLED', verified: false,
        execution_outcome: 'NOT_TESTED', reply: 'Ho salvato la tua preferenza.'
    });
    assert.equal(memoryHandled.returned, true);
    assert.match(memoryHandled.elements.aiBadgeStatus.textContent, /Memoria/,
        'local memory handled is not an unsuccessful TV action');

    const bareHttpError = await scenario(400, { error: 'Richiesta invalida' });
    assert.match(bareHttpError.elements.aiBadgeStatus.textContent, /Non Riuscito/,
        'a generic HTTP error without AI result must not be treated as a handled command');

    const unauthorized = await scenario(401, { error: 'Token scaduto' });
    assert.equal(unauthorized.expired, true);
    assert.equal(unauthorized.elements.aiResponseText.textContent, '');

    const tlsRequired = await scenario(426, { error: 'HTTPS required' });
    assert.match(tlsRequired.elements.aiResponseText.textContent, /HTTPS/);
    assert.match(tlsRequired.elements.aiBadgeStatus.textContent, /Non Riuscito/);

    await verifyConsentUi();
    console.log('Web AI feedback regression PASS (16 outcomes + 5 consent cases; no TV or cloud API used)');
}

run().catch(err => {
    console.error(err);
    process.exitCode = 1;
});
