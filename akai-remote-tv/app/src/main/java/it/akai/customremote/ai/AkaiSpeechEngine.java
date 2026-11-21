package it.akai.customremote.ai;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.os.Handler;
import android.os.Looper;
import org.json.JSONObject;
import android.os.Build;
import android.os.Bundle;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;
import android.util.Log;

import java.util.HashMap;
import java.util.Locale;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * AkaiSpeechEngine: Android platform TTS for AKAI TV.
 * Speech uses the installed Android engine; no external Azure synthesis calls.
 * DeepSeek/Kimi remain the exclusive cloud providers for AI inference.
 */
public class AkaiSpeechEngine implements TextToSpeech.OnInitListener {
    private static final String TAG = "AKAI_SpeechEngine";
    private static final String PREFERRED_OFFLINE_ENGINE = "com.reecedunn.espeak";
    private static final long OFFLINE_UTTERANCE_WATCHDOG_MS = 25000L;

    public enum SpeechState {
        IDLE, FETCHING, PLAYING
    }

    private volatile SpeechState mSpeechState = SpeechState.IDLE;
    private final java.util.concurrent.atomic.AtomicLong mSpeechId = new java.util.concurrent.atomic.AtomicLong(0);
    private AudioFocusRequest mPlaybackFocusRequest = null;

    private static AkaiSpeechEngine sInstance = null;

    private final Context mContext;
    private final AudioManager mAudioManager;
    private final CloudSpeechAdapter mCloudAdapter;
    private final AkaiMemoryEngine mMemoryEngine;
    private final FreeItalianTtsCoordinator mFreeVoice;
    private final Handler mWatchdogHandler = new Handler(Looper.getMainLooper());
    private Runnable mOfflineWatchdog = null;

    private TextToSpeech mTts;
    private final AtomicBoolean mIsInitialized = new AtomicBoolean(false);
    private final AtomicBoolean mIsOfflineSpeaking = new AtomicBoolean(false);
    private final SpeechUtteranceGate mOfflineGate = new SpeechUtteranceGate();

    private final AudioManager.OnAudioFocusChangeListener mFocusListener = new AudioManager.OnAudioFocusChangeListener() {
        @Override
        public void onAudioFocusChange(int focusChange) {
            Log.d(TAG, "AudioFocus change: " + focusChange);
        }
    };

    public static synchronized AkaiSpeechEngine getInstance(Context context) {
        if (sInstance == null) {
            sInstance = new AkaiSpeechEngine(context.getApplicationContext());
        }
        return sInstance;
    }

    private AkaiSpeechEngine(Context context) {
        mContext = context;
        mAudioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        mMemoryEngine = AkaiMemoryEngine.getInstance(context);
        // Legacy cloud adapter is deliberately not allocated (no cache or player).
        // Compatibility API methods below tolerate a null adapter.
        mCloudAdapter = null;
        mFreeVoice = new FreeItalianTtsCoordinator(context);
        initOfflineTts();
    }

    private void initOfflineTts() {
        // Do not construct a second engine while the first one is connecting.
        if (mTts != null) return;
        try {
            Log.i(TAG, "Initializing bundled offline TextToSpeech: " + PREFERRED_OFFLINE_ENGINE);
            mIsInitialized.set(false);
            mTts = new TextToSpeech(mContext, this, PREFERRED_OFFLINE_ENGINE);
        } catch (Exception e) {
            mIsInitialized.set(false);
            mTts = null;
            // Unknown Android default engines can use third-party cloud speech.
            // Prefer no voice over violating the owner's provider policy.
            Log.e(TAG, "Offline eSpeak unavailable; no other provider fallback: " + e.getMessage());
        }
    }

    @Override
    public synchronized void onInit(int status) {
        if (status == TextToSpeech.SUCCESS) {
            if (mTts == null) return;
            Log.i(TAG, "Offline TTS Engine successfully connected.");
            try {
                int langResult = mTts.setLanguage(Locale.ITALIAN);
                if (langResult == TextToSpeech.LANG_MISSING_DATA || langResult == TextToSpeech.LANG_NOT_SUPPORTED) {
                    Log.w(TAG, "Italian not directly supported in offline engine, using default locale");
                    mTts.setLanguage(Locale.getDefault());
                } else {
                    Log.i(TAG, "Italian voice successfully loaded in offline TTS engine.");
                }

                // The stock 1.0 speech rate/pitch are already defaults.
                // Avoid redundant OEM eSpeak parameter writes during startup.

                mTts.setOnUtteranceProgressListener(new UtteranceProgressListener() {
                    @Override
                    public void onStart(String utteranceId) {
                        markOfflineUtteranceStarted(utteranceId);
                    }

                    @Override
                    public void onDone(String utteranceId) {
                        if (!finishOfflineUtterance(utteranceId)) return;
                        Log.d(TAG, "Offline TTS speaking finished: " + utteranceId);
                    }

                    @Override
                    public void onError(String utteranceId) {
                        if (!finishOfflineUtterance(utteranceId)) return;
                        Log.e(TAG, "Offline TTS error: " + utteranceId);
                    }

                    @Override
                    public void onStop(String utteranceId, boolean interrupted) {
                        if (!finishOfflineUtterance(utteranceId)) return;
                        Log.d(TAG, "Offline TTS speaking stopped: " + utteranceId + " (interrupted=" + interrupted + ")");
                    }
                });

                mIsInitialized.set(true);
            } catch (Exception e) {
                Log.e(TAG, "Error configuring TTS parameters: " + e.getMessage());
            }
        } else {
            Log.e(TAG, "Offline TTS initialization failed with code: " + status);
            mIsInitialized.set(false);
            // Dispose failed engine so a later explicit request can retry.
            TextToSpeech failed = mTts;
            mTts = null;
            if (failed != null) {
                try { failed.shutdown(); } catch (Exception ignored) {}
            }
        }
    }

    /**
     * Pronuncia un testo attraverso gli altoparlanti della televisione.
     * Uses only Android platform TTS. Legacy cloud synthesis is disabled.
     */
    public synchronized boolean speak(String text, boolean interrupt) {
        if (text == null || text.trim().isEmpty()) return false;

        if (interrupt) {
            stop();
        }

        mSpeechId.incrementAndGet();
        mSpeechState = SpeechState.FETCHING;

        // FreeTTS is only used after explicit opt-in with an encrypted personal
        // FREE-tier key; it cannot run in Guest mode or on sensitive text.
        final long requestedId = mSpeechId.get();
        if (!mMemoryEngine.isGuestMode() && mFreeVoice.speak(text,
                new FreeItalianTtsCoordinator.Events() {
                    @Override public void onPlaying() {
                        synchronized (AkaiSpeechEngine.this) {
                            if (mSpeechId.get() != requestedId) return;
                            requestAudioFocus();
                            mSpeechState = SpeechState.PLAYING;
                        }
                    }
                    @Override public void onCompleted() {
                        synchronized (AkaiSpeechEngine.this) {
                            if (mSpeechId.get() != requestedId) return;
                            mSpeechState = SpeechState.IDLE;
                            abandonAudioFocus();
                        }
                    }
                    @Override public void onFallback(final String originalText) {
                        // Exit the coordinator monitor before acquiring speech lock.
                        new Handler(Looper.getMainLooper()).post(new Runnable() {
                            @Override public void run() {
                                synchronized (AkaiSpeechEngine.this) {
                                    if (mSpeechId.get() == requestedId) {
                                        speakOfflineTts(originalText, true);
                                    }
                                }
                            }
                        });
                    }
                })) {
            return true;
        }
        return speakOfflineTts(text, interrupt);
    }

    public synchronized boolean previewVoice(String voice, String text) {
        if (text == null || text.trim().isEmpty()) text = "Ciao, questa è la voce dell'assistente per la tua televisione AKAI.";
        stop();

        mSpeechId.incrementAndGet();
        mSpeechState = SpeechState.FETCHING;

        // A preview must use the currently configured and consented provider.
        // A request may never select a third-party voice by supplying its name.
        String configured = mFreeVoice.configuredVoice();
        if (!configured.equals(voice) && !"offline_espeak".equals(voice)) {
            return false;
        }
        if (mFreeVoice.isFreeMode() && configured.equals(voice)) {
            return speak(text, true);
        }
        return speakOfflineTts(text, true);
    }

    private synchronized boolean speakOfflineTts(String text, boolean interrupt) {
        if (!mIsInitialized.get() || mTts == null) {
            Log.w(TAG, "Offline TTS not ready. Re-attempting init...");
            initOfflineTts();
            mSpeechState = SpeechState.IDLE;
            return false;
        }

        // Sequence ID prevents two requests in the same millisecond from sharing callbacks.
        final String utteranceId = "akai_offline_" + mSpeechId.get();
        mOfflineGate.activate(utteranceId);
        try {
            requestAudioFocus();
            int queueMode = interrupt ? TextToSpeech.QUEUE_FLUSH : TextToSpeech.QUEUE_ADD;

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                Bundle params = new Bundle();
                params.putInt(TextToSpeech.Engine.KEY_PARAM_STREAM, AudioManager.STREAM_MUSIC);
                int res = mTts.speak(text, queueMode, params, utteranceId);
                if (res != TextToSpeech.SUCCESS) {
                    finishOfflineUtterance(utteranceId);
                    reinitOfflineTtsLocked();
                    return false;
                }
                scheduleOfflineWatchdogLocked(utteranceId, text.length());
                return true;
            } else {
                HashMap<String, String> params = new HashMap<>();
                params.put(TextToSpeech.Engine.KEY_PARAM_STREAM, String.valueOf(AudioManager.STREAM_MUSIC));
                params.put(TextToSpeech.Engine.KEY_PARAM_UTTERANCE_ID, utteranceId);
                int res = mTts.speak(text, queueMode, params);
                if (res != TextToSpeech.SUCCESS) {
                    finishOfflineUtterance(utteranceId);
                    reinitOfflineTtsLocked();
                    return false;
                }
                scheduleOfflineWatchdogLocked(utteranceId, text.length());
                return true;
            }
        } catch (Exception e) {
            Log.e(TAG, "Error in speakOfflineTts: " + e.getMessage());
            finishOfflineUtterance(utteranceId);
            reinitOfflineTtsLocked();
            return false;
        }
    }

    private void cancelOfflineWatchdogLocked() {
        if (mOfflineWatchdog != null) {
            mWatchdogHandler.removeCallbacks(mOfflineWatchdog);
            mOfflineWatchdog = null;
        }
    }

    private void scheduleOfflineWatchdogLocked(final String utteranceId, int textLength) {
        cancelOfflineWatchdogLocked();
        // Bounded completion guard: Android 9 OEM eSpeak can omit onDone after
        // AudioTrack stops or crash mid-utterance, stranding PLAYING + AudioFocus.
        long timeoutMs = Math.min(OFFLINE_UTTERANCE_WATCHDOG_MS, Math.max(3000L, (long) textLength * 85L + 1500L));
        mOfflineWatchdog = new Runnable() {
            @Override
            public void run() {
                synchronized (AkaiSpeechEngine.this) {
                    boolean startObserved = mIsOfflineSpeaking.get();
                    if (finishOfflineUtterance(utteranceId)) {
                        Log.w(TAG, "Offline TTS completion watchdog released idle state: " + utteranceId);
                        if (!startObserved) {
                            Log.w(TAG, "Offline TTS never reached onStart before timeout; reinitializing engine.");
                            reinitOfflineTtsLocked();
                        }
                    }
                }
            }
        };
        mWatchdogHandler.postDelayed(mOfflineWatchdog, timeoutMs);
    }

    private void reinitOfflineTtsLocked() {
        TextToSpeech stale = mTts;
        mTts = null;
        mIsInitialized.set(false);
        if (stale != null) {
            try { stale.shutdown(); } catch (Exception ignored) {}
        }
        initOfflineTts();
    }

    public synchronized void stop() {
        cancelOfflineWatchdogLocked();
        // Invalidate any in-flight free cloud result before its audio is started.
        mSpeechId.incrementAndGet();
        mFreeVoice.stop();
        // Invalidate first: TTS.stop() can trigger asynchronous onDone/onError.
        mOfflineGate.stop();
        if (mCloudAdapter != null) {
            mCloudAdapter.stopCurrentPlayback();
        }
        if (mTts != null) {
            try { mTts.stop(); } catch (Exception ignored) {}
        }
        mIsOfflineSpeaking.set(false);
        mSpeechState = SpeechState.IDLE;
        abandonAudioFocus();
    }

    // Serialize callbacks with speak()/stop(): the old onDone must not
    // release audio focus after the next utterance has started.
    private synchronized void markOfflineUtteranceStarted(String utteranceId) {
        if (!mOfflineGate.isCurrent(utteranceId)) return;
        mIsOfflineSpeaking.set(true);
        mSpeechState = SpeechState.PLAYING;
        Log.d(TAG, "Offline TTS speaking started: " + utteranceId);
    }

    private synchronized boolean finishOfflineUtterance(String utteranceId) {
        if (!mOfflineGate.finish(utteranceId)) return false;
        cancelOfflineWatchdogLocked();
        mIsOfflineSpeaking.set(false);
        mSpeechState = SpeechState.IDLE;
        abandonAudioFocus();
        return true;
    }

    public boolean isSpeaking() {
        return mSpeechState != SpeechState.IDLE || mFreeVoice.isBusy()
                || (mCloudAdapter != null && mCloudAdapter.isPlaying()) || mIsOfflineSpeaking.get();
    }

    public String getSpeechState() {
        return mSpeechState.name();
    }

    public long getCurrentSpeechId() {
        return mSpeechId.get();
    }

    // =========================================================================
    // CONFIGURAZIONE VOCALE E CHIAVI AZURE SPEECH F0
    // =========================================================================

    public String getTtsVoice() {
        return mFreeVoice.configuredVoice();
    }

    public void setTtsVoice(String voice) {
        if (!CloudSpeechAdapter.VOICE_OFFLINE.equals(voice)) {
            Log.w(TAG, "Voice selection requires explicit free-tier consent in TTS settings.");
            return;
        }
        mMemoryEngine.setPreference("tts_voice", CloudSpeechAdapter.VOICE_OFFLINE, "tts", 0);
    }

    public JSONObject getVoiceConfiguration() {
        return mFreeVoice.configuration();
    }

    public synchronized boolean configureVoice(JSONObject settings) {
        boolean saved = mFreeVoice.configure(settings);
        // Switching voice profiles must also clear Android TTS/AudioFocus
        // state, not just stop the async MP3 player in the coordinator.
        if (saved) stop();
        return saved;
    }

    // Compatibility methods remain for older callers but cannot expose, write
    // or reactivate legacy third-party speech credentials.
    public String getAzureRegion() {
        return "";
    }

    public void setAzureRegion(String region) {
        Log.w(TAG, "Legacy Azure speech configuration is disabled.");
    }

    public String getAzureKey() {
        return "";
    }

    public void setAzureKey(String key) {
        Log.w(TAG, "Legacy Azure speech credentials are not accepted.");
    }

    public long getCacheSizeBytes() {
        return mCloudAdapter != null ? mCloudAdapter.getCacheSizeBytes() : 0;
    }

    public void clearCache() {
        if (mCloudAdapter != null) {
            mCloudAdapter.clearCache();
        }
    }

    private void requestAudioFocus() {
        try {
            if (mAudioManager != null) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    AudioAttributes playbackAttributes = new AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build();

                    mPlaybackFocusRequest = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                            .setAudioAttributes(playbackAttributes)
                            .setAcceptsDelayedFocusGain(false)
                            .setOnAudioFocusChangeListener(mFocusListener)
                            .build();

                    mAudioManager.requestAudioFocus(mPlaybackFocusRequest);
                } else {
                    mAudioManager.requestAudioFocus(mFocusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK);
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "Audio focus notice: " + e.getMessage());
        }
    }

    private void abandonAudioFocus() {
        try {
            if (mAudioManager != null) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && mPlaybackFocusRequest != null) {
                    mAudioManager.abandonAudioFocusRequest(mPlaybackFocusRequest);
                    mPlaybackFocusRequest = null;
                } else {
                    mAudioManager.abandonAudioFocus(mFocusListener);
                }
            }
        } catch (Exception ignored) {}
    }
}
