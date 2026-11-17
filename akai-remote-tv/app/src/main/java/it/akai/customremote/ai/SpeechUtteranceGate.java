package it.akai.customremote.ai;

import java.util.concurrent.atomic.AtomicReference;

/**
 * Pure-Java guard for Android TextToSpeech callbacks from interrupted requests.
 * TTS callbacks are asynchronous and can arrive after STOP or a newer utterance.
 * Only the current utterance may release audio focus or set speech state to idle.
 */
public final class SpeechUtteranceGate {
    private final AtomicReference<String> active = new AtomicReference<>();

    public void activate(String utteranceId) {
        if (utteranceId == null || utteranceId.isEmpty()) {
            throw new IllegalArgumentException("utteranceId required");
        }
        active.set(utteranceId);
    }

    public boolean isCurrent(String utteranceId) {
        return utteranceId != null && utteranceId.equals(active.get());
    }

    public boolean finish(String utteranceId) {
        return utteranceId != null && active.compareAndSet(utteranceId, null);
    }

    public void stop() {
        active.set(null);
    }
}
