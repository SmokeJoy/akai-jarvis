package it.akai.customremote.ai;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.os.Build;
import android.os.Bundle;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;
import android.util.Log;

import java.util.HashMap;
import java.util.Locale;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * AkaiSpeechEngine: Motore vocale ibrido per AKAI Custom TV (Fase 15).
 * 
 * Orchestra a doppio livello:
 * 1. Livello Neurale Cloud: Microsoft Azure Speech F0 (voci naturali it-IT-DiegoNeural, it-IT-IsabellaNeural)
 *    con cache audio 8 MB su disco ed AudioFocus Ducking.
 * 2. Livello Offline Fallback: Android TextToSpeech nativo (com.reecedunn.espeak) in caso di assenza
 *    di connessione, quota esaurita o richiesta esplicita di modalità offline.
 */
public class AkaiSpeechEngine implements TextToSpeech.OnInitListener {
    private static final String TAG = "AKAI_SpeechEngine";
    private static final String PREFERRED_OFFLINE_ENGINE = "com.reecedunn.espeak";

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

    private TextToSpeech mTts;
    private final AtomicBoolean mIsInitialized = new AtomicBoolean(false);
    private final AtomicBoolean mIsOfflineSpeaking = new AtomicBoolean(false);

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
        mCloudAdapter = new CloudSpeechAdapter(context);

        mCloudAdapter.setPlaybackListener(new CloudSpeechAdapter.PlaybackListener() {
            @Override
            public void onPreparing() {
                mSpeechState = SpeechState.FETCHING;
            }

            @Override
            public void onPlaying() {
                mSpeechState = SpeechState.PLAYING;
            }

            @Override
            public void onCompleted() {
                mSpeechState = SpeechState.IDLE;
            }

            @Override
            public void onError(String error) {
                mSpeechState = SpeechState.IDLE;
            }
        });

        initOfflineTts();
    }

    private void initOfflineTts() {
        try {
            Log.i(TAG, "Initializing Android TextToSpeech with engine: " + PREFERRED_OFFLINE_ENGINE);
            mTts = new TextToSpeech(mContext, this, PREFERRED_OFFLINE_ENGINE);
        } catch (Exception e) {
            Log.w(TAG, "Failed with " + PREFERRED_OFFLINE_ENGINE + ", trying system default: " + e.getMessage());
            try {
                mTts = new TextToSpeech(mContext, this);
            } catch (Exception ex) {
                Log.e(TAG, "Fatal TTS initialization error: " + ex.getMessage());
            }
        }
    }

    @Override
    public void onInit(int status) {
        if (status == TextToSpeech.SUCCESS) {
            Log.i(TAG, "Offline TTS Engine successfully connected.");
            try {
                int langResult = mTts.setLanguage(Locale.ITALIAN);
                if (langResult == TextToSpeech.LANG_MISSING_DATA || langResult == TextToSpeech.LANG_NOT_SUPPORTED) {
                    Log.w(TAG, "Italian not directly supported in offline engine, using default locale");
                    mTts.setLanguage(Locale.getDefault());
                } else {
                    Log.i(TAG, "Italian voice successfully loaded in offline TTS engine.");
                }

                mTts.setSpeechRate(1.0f);
                mTts.setPitch(1.0f);

                mTts.setOnUtteranceProgressListener(new UtteranceProgressListener() {
                    @Override
                    public void onStart(String utteranceId) {
                        mIsOfflineSpeaking.set(true);
                        mSpeechState = SpeechState.PLAYING;
                        Log.d(TAG, "Offline TTS speaking started: " + utteranceId);
                    }

                    @Override
                    public void onDone(String utteranceId) {
                        mIsOfflineSpeaking.set(false);
                        mSpeechState = SpeechState.IDLE;
                        Log.d(TAG, "Offline TTS speaking finished: " + utteranceId);
                        abandonAudioFocus();
                    }

                    @Override
                    public void onError(String utteranceId) {
                        mIsOfflineSpeaking.set(false);
                        mSpeechState = SpeechState.IDLE;
                        Log.e(TAG, "Offline TTS error: " + utteranceId);
                        abandonAudioFocus();
                    }
                });

                mIsInitialized.set(true);
            } catch (Exception e) {
                Log.e(TAG, "Error configuring TTS parameters: " + e.getMessage());
            }
        } else {
            Log.e(TAG, "Offline TTS initialization failed with code: " + status);
            mIsInitialized.set(false);
        }
    }

    /**
     * Pronuncia un testo attraverso gli altoparlanti della televisione.
     * Tenta prioritariamente la voce neurale configurata (Diego/Isabella); in caso di errore
     * o assenza di credenziali esegue un fallback trasparente su TTS locale offline.
     */
    public synchronized boolean speak(String text, boolean interrupt) {
        if (text == null || text.trim().isEmpty()) return false;

        if (interrupt) {
            stop();
        }

        mSpeechId.incrementAndGet();
        mSpeechState = SpeechState.FETCHING;

        String voice = getTtsVoice();
        String region = getAzureRegion();
        String apiKey = getAzureKey();

        // Tentativo con voce neurale cloud se configurata e chiave presente (inibito se STRICT_LOCAL_ONLY)
        if (!AkaiAiController.isStrictLocalOnly() && !CloudSpeechAdapter.VOICE_OFFLINE.equals(voice) && apiKey != null && !apiKey.isEmpty()) {
            Log.i(TAG, "Attempting neural speech with voice: " + voice + " (" + region + ")");
            boolean neuralSuccess = mCloudAdapter.speakNeural(text, voice, region, apiKey, null);
            if (neuralSuccess) {
                return true;
            }
            Log.w(TAG, "Neural speech failed or unavailable. Falling back to offline AOSP TTS engine...");
        }

        // Fallback offline su Android TextToSpeech
        return speakOfflineTts(text, interrupt);
    }

    public synchronized boolean previewVoice(String voice, String text) {
        if (text == null || text.trim().isEmpty()) text = "Ciao, questa è la voce dell'assistente per la tua televisione AKAI.";
        stop();

        mSpeechId.incrementAndGet();
        mSpeechState = SpeechState.FETCHING;

        String region = getAzureRegion();
        String apiKey = getAzureKey();

        if (!AkaiAiController.isStrictLocalOnly() && !CloudSpeechAdapter.VOICE_OFFLINE.equals(voice) && apiKey != null && !apiKey.isEmpty()) {
            return mCloudAdapter.speakNeural(text, voice, region, apiKey, null);
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

        try {
            requestAudioFocus();
            int queueMode = interrupt ? TextToSpeech.QUEUE_FLUSH : TextToSpeech.QUEUE_ADD;
            String utteranceId = "akai_offline_" + System.currentTimeMillis();

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                Bundle params = new Bundle();
                params.putInt(TextToSpeech.Engine.KEY_PARAM_STREAM, AudioManager.STREAM_MUSIC);
                int res = mTts.speak(text, queueMode, params, utteranceId);
                if (res != TextToSpeech.SUCCESS) {
                    mSpeechState = SpeechState.IDLE;
                    abandonAudioFocus();
                    return false;
                }
                return true;
            } else {
                HashMap<String, String> params = new HashMap<>();
                params.put(TextToSpeech.Engine.KEY_PARAM_STREAM, String.valueOf(AudioManager.STREAM_MUSIC));
                params.put(TextToSpeech.Engine.KEY_PARAM_UTTERANCE_ID, utteranceId);
                int res = mTts.speak(text, queueMode, params);
                if (res != TextToSpeech.SUCCESS) {
                    mSpeechState = SpeechState.IDLE;
                    abandonAudioFocus();
                    return false;
                }
                return true;
            }
        } catch (Exception e) {
            Log.e(TAG, "Error in speakOfflineTts: " + e.getMessage());
            mSpeechState = SpeechState.IDLE;
            abandonAudioFocus();
            return false;
        }
    }

    public synchronized void stop() {
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

    public boolean isSpeaking() {
        return mSpeechState != SpeechState.IDLE || (mCloudAdapter != null && mCloudAdapter.isPlaying()) || mIsOfflineSpeaking.get();
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
        return mMemoryEngine.getPreference("tts_voice", CloudSpeechAdapter.VOICE_DIEGO);
    }

    public void setTtsVoice(String voice) {
        if (voice != null && !voice.isEmpty()) {
            mMemoryEngine.setPreference("tts_voice", voice, "tts", 0);
            Log.i(TAG, "Selected TTS voice: " + voice);
        }
    }

    public String getAzureRegion() {
        return mMemoryEngine.getPreference("azure_speech_region", "westeurope");
    }

    public void setAzureRegion(String region) {
        if (region != null && !region.isEmpty()) {
            mMemoryEngine.setPreference("azure_speech_region", region, "tts", 0);
        }
    }

    public String getAzureKey() {
        String enc = mMemoryEngine.getPreference("azure_speech_key_enc", "");
        if (enc == null || enc.isEmpty()) return "";
        return KeystoreSecurityHelper.decrypt(enc);
    }

    public void setAzureKey(String key) {
        if (key == null || key.trim().isEmpty()) {
            mMemoryEngine.deletePreference("azure_speech_key_enc");
        } else {
            String enc = KeystoreSecurityHelper.encrypt(key.trim());
            mMemoryEngine.setPreference("azure_speech_key_enc", enc, "tts_security", 0);
        }
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
