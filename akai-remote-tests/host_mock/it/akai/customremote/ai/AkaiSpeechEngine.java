package it.akai.customremote.ai;

import android.content.Context;

public class AkaiSpeechEngine {
    private static final AkaiSpeechEngine sInstance = new AkaiSpeechEngine();

    public static synchronized AkaiSpeechEngine getInstance(Context context) {
        return sInstance;
    }

    public synchronized boolean speak(String text, boolean interrupt) {
        return false;
    }

    public synchronized void stop() {}
}
