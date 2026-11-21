package it.akai.customremote.ai;

import android.content.Context;
import android.content.SharedPreferences;
import android.media.MediaPlayer;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;

/**
 * Owner-opt-in FreeTTS free personal tier, output on the TV speakers.
 * No cloud inference model moves off DeepSeek/Kimi: this component performs
 * speech output only, never interprets instructions or controls Android.
 *
 * Network I/O always runs in a single background worker; MediaPlayer lives on
 * the main Looper. A generation check prevents stale audio after STOP.
 */
public final class FreeItalianTtsCoordinator {
    private static final String TAG = "AKAI_FreeVoice";
    private static final String PREFS = "jarvis_free_voice_v1";
    private static final String MODE = "mode";
    private static final String VOICE = "voice";
    private static final String KEY = "encrypted_key";
    private static final String CONSENT = "owner_tts_consent";
    private static final String MONTH = "month";
    private static final String CHARS = "chars_used";
    private static final String FREE = FreeItalianTtsPolicy.PROVIDER;
    private static final String OFFLINE = "offline_espeak";

    public interface Events {
        void onPlaying();
        void onCompleted();
        void onFallback(String originalText);
    }

    private final Context context;
    private final SharedPreferences prefs;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private long generation;
    private boolean busy;
    private boolean audioStarted;
    private MediaPlayer player;
    private File playingFile;

    public FreeItalianTtsCoordinator(Context context) {
        this.context = context.getApplicationContext();
        this.prefs = this.context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    public synchronized JSONObject configuration() {
        JSONObject out = new JSONObject();
        int now = FreeItalianTtsPolicy.currentUtcMonth();
        int stored = prefs.getInt(MONTH, 0);
        int used = prefs.getInt(CHARS, 0);
        if (stored != now) used = stored < now ? 0 : FreeItalianTtsPolicy.MAX_MONTHLY_CHARS;
        boolean freeMode = FREE.equals(prefs.getString(MODE, OFFLINE));
        boolean hasKey = !key().isEmpty();
        boolean consent = prefs.getBoolean(CONSENT, false);
        try {
            out.put("mode", freeMode ? FREE : OFFLINE);
            out.put("active_voice", freeMode && hasKey && consent
                    ? prefs.getString(VOICE, FreeItalianTtsPolicy.VOICE_MALE) : OFFLINE);
            out.put("free_tts_available", true);
            out.put("free_tts_enabled", freeMode && hasKey && consent);
            out.put("cloud_tts_enabled", freeMode && hasKey && consent);
            out.put("free_tts_consent", consent);
            out.put("free_tts_has_key", hasKey);
            out.put("free_tts_limit_chars", FreeItalianTtsPolicy.MAX_MONTHLY_CHARS);
            out.put("free_tts_used_chars", used);
            out.put("free_tts_remaining_chars", Math.max(0,
                    FreeItalianTtsPolicy.MAX_MONTHLY_CHARS - used));
            out.put("free_tts_month_utc", now);
            out.put("free_tts_requires_personal_free_account", true);
            out.put("free_tts_audio_watermark", true);
            out.put("free_tts_max_reply_chars", FreeItalianTtsPolicy.MAX_UTTERANCE_CHARS);
            out.put("speech_provider_policy", "OWNER_OPT_IN_FREE_TTS_ONLY");
        } catch (Exception ignored) {}
        return out;
    }

    public synchronized boolean configure(JSONObject input) {
        if (input == null || input.has("azure_key") || input.has("azure_region")
                || input.has("billing") || input.has("paid_plan") || input.has("api_endpoint")) {
            return false;
        }
        String mode = input.optString("mode", OFFLINE);
        if (!OFFLINE.equals(mode) && !FREE.equals(mode)) return false;
        String selected = input.optString("voice", FreeItalianTtsPolicy.VOICE_MALE);
        if (FREE.equals(mode) && !FreeItalianTtsPolicy.voiceAllowed(selected)) return false;
        if (FREE.equals(mode) && (!input.optBoolean("free_tts_consent", false)
                || !input.optBoolean("free_tier_confirmed", false))) return false;

        String rawKey = input.optString("freetts_api_key", "").trim();
        if (!rawKey.isEmpty() && (rawKey.length() < 10 || rawKey.length() > 256
                || !rawKey.matches("[A-Za-z0-9._-]+"))) return false;

        // Encrypt BEFORE editing preferences. Encryption failure cannot leak
        // plaintext, accidentally flip modes or create a partial configuration.
        String encrypted = "";
        if (FREE.equals(mode)) {
            try {
                encrypted = rawKey.isEmpty() ? prefs.getString(KEY, "")
                        : KeystoreSecurityHelper.encrypt(rawKey);
                if (encrypted == null || encrypted.isEmpty()
                        || KeystoreSecurityHelper.decrypt(encrypted).isEmpty()) return false;
            } catch (Exception rejected) {
                return false;
            }
        }

        SharedPreferences.Editor editor = prefs.edit();
        editor.putString(MODE, mode);
        editor.putString(VOICE, FREE.equals(mode) ? selected : OFFLINE);
        editor.putBoolean(CONSENT, FREE.equals(mode));
        if (FREE.equals(mode)) editor.putString(KEY, encrypted);
        else editor.remove(KEY);
        if (!editor.commit()) return false;
        stop();
        return true;
    }

    public synchronized boolean isFreeMode() {
        return FREE.equals(prefs.getString(MODE, OFFLINE))
                && prefs.getBoolean(CONSENT, false) && !key().isEmpty();
    }

    public synchronized String configuredVoice() {
        return isFreeMode() ? prefs.getString(VOICE, FreeItalianTtsPolicy.VOICE_MALE) : OFFLINE;
    }

    private String key() {
        String stored = prefs.getString(KEY, "");
        if (stored == null || !stored.startsWith("ks:")) return "";
        return KeystoreSecurityHelper.decrypt(stored);
    }

    private boolean reserve(String text) {
        int now = FreeItalianTtsPolicy.currentUtcMonth();
        int stored = prefs.getInt(MONTH, 0);
        int oldUsed = prefs.getInt(CHARS, 0);
        if (!FreeItalianTtsPolicy.canReserve(stored, oldUsed, now, text.length())) {
            return false;
        }
        int next = (now == stored ? oldUsed : 0) + text.length();
        // Synchronous durable commit BEFORE network to prevent quota resets
        // when Android kills the process. Failed calls also count by design.
        return prefs.edit().putInt(MONTH, now).putInt(CHARS, next).commit();
    }

    public synchronized boolean speak(final String text, final Events events) {
        if (events == null || busy || !isFreeMode()
                || !FreeItalianTtsPolicy.textAllowed(text)
                || !FreeItalianTtsPolicy.voiceAllowed(configuredVoice())) return false;
        final String apiKey = key();
        if (apiKey.isEmpty() || !reserve(text)) return false;
        final String voice = configuredVoice();
        final long request = ++generation;
        busy = true;
        audioStarted = false;
        try {
            worker.execute(new Runnable() {
                @Override public void run() {
                    // STOP and owner opt-out must prevent upload when a queued
                    // worker starts after its original speech task was revoked.
                    final FreeItalianTtsClient.Cancellation cancelled =
                            new FreeItalianTtsClient.Cancellation() {
                        @Override public boolean isCancelled() {
                            synchronized (FreeItalianTtsCoordinator.this) {
                                return request != generation
                                        || !prefs.getBoolean(CONSENT, false);
                            }
                        }
                    };
                    if (cancelled.isCancelled()) return;
                    final File mp3 = FreeItalianTtsClient.synthesize(
                            context, text, voice, apiKey, cancelled);
                    if (!main.post(new Runnable() {
                        @Override public void run() {
                            boolean doFallback = false;
                            synchronized (FreeItalianTtsCoordinator.this) {
                                if (request != generation) {
                                    if (mp3 != null) mp3.delete();
                                    return;
                                }
                                if (mp3 == null) {
                                    busy = false;
                                    doFallback = true;
                                } else {
                                    doFallback = !playOnMainLocked(mp3, text, request, events);
                                }
                            }
                            if (doFallback) {
                                events.onFallback(text);
                            }
                        }
                    })) {
                        if (mp3 != null) mp3.delete();
                        synchronized (FreeItalianTtsCoordinator.this) {
                            if (request == generation) busy = false;
                        }
                    }
                }
            });
        } catch (RejectedExecutionException rejected) {
            busy = false;
            return false;
        }
        return true;
    }

    private boolean playOnMainLocked(final File file, final String text,
                                     final long request, final Events events) {
        releasePlayer();
        playingFile = file;
        try {
            player = new MediaPlayer();
            final MediaPlayer current = player;
            current.setAudioStreamType(android.media.AudioManager.STREAM_MUSIC);
            try (FileInputStream input = new FileInputStream(file)) {
                current.setDataSource(input.getFD());
            }
            current.setOnPreparedListener(new MediaPlayer.OnPreparedListener() {
                @Override public void onPrepared(MediaPlayer mp) {
                    boolean notifyPlaying = false;
                    boolean doFallback = false;
                    synchronized (FreeItalianTtsCoordinator.this) {
                        if (request != generation || current != player) return;
                        try {
                            audioStarted = true;
                            mp.start();
                            notifyPlaying = true;
                            main.postDelayed(new Runnable() {
                                @Override public void run() {
                                    boolean notifyCompleted = false;
                                    synchronized (FreeItalianTtsCoordinator.this) {
                                        if (request == generation && current == player) {
                                            Log.w(TAG, "Playback watchdog released stalled MediaPlayer.");
                                            releasePlayer();
                                            busy = false;
                                            notifyCompleted = true;
                                        }
                                    }
                                    if (notifyCompleted) {
                                        events.onCompleted();
                                    }
                                }
                            }, 60000);
                        } catch (Exception e) {
                            doFallback = failPlaybackLocked(current, request);
                        }
                    }
                    if (notifyPlaying) {
                        events.onPlaying();
                    } else if (doFallback) {
                        events.onFallback(text);
                    }
                }
            });
            current.setOnCompletionListener(new MediaPlayer.OnCompletionListener() {
                @Override public void onCompletion(MediaPlayer mp) {
                    boolean notifyCompleted = false;
                    synchronized (FreeItalianTtsCoordinator.this) {
                        if (request != generation || current != player) return;
                        releasePlayer();
                        busy = false;
                        notifyCompleted = true;
                    }
                    if (notifyCompleted) {
                        events.onCompleted();
                    }
                }
            });
            current.setOnErrorListener(new MediaPlayer.OnErrorListener() {
                @Override public boolean onError(MediaPlayer mp, int what, int extra) {
                    boolean doFallback = false;
                    synchronized (FreeItalianTtsCoordinator.this) {
                        if (request == generation && current == player) {
                            doFallback = failPlaybackLocked(current, request);
                        }
                    }
                    if (doFallback) {
                        events.onFallback(text);
                    }
                    return true;
                }
            });
            current.prepareAsync();
            main.postDelayed(new Runnable() {
                @Override public void run() {
                    boolean doFallback = false;
                    synchronized (FreeItalianTtsCoordinator.this) {
                        if (request == generation && current == player && !audioStarted) {
                            doFallback = failPlaybackLocked(current, request);
                        }
                    }
                    if (doFallback) {
                        events.onFallback(text);
                    }
                }
            }, 12000);
            return true;
        } catch (Exception e) {
            Log.w(TAG, "Local playback failed: " + e.getClass().getSimpleName());
            failPlaybackLocked(player, request);
            return false;
        }
    }

    private boolean failPlaybackLocked(MediaPlayer expected, long request) {
        if (request != generation || expected != player) return false;
        releasePlayer();
        busy = false;
        return true;
    }

    public synchronized void stop() {
        generation++;
        busy = false;
        audioStarted = false;
        // MediaPlayer must be released on its main Looper.
        final MediaPlayer stoppedPlayer = player;
        main.post(new Runnable() {
            @Override public void run() {
                synchronized (FreeItalianTtsCoordinator.this) {
                    // Do not interrupt audio created by a later request.
                    if (player == stoppedPlayer) releasePlayer();
                }
            }
        });
    }

    private void releasePlayer() {
        if (player != null) {
            try { player.reset(); player.release(); } catch (Exception ignored) {}
            player = null;
        }
        if (playingFile != null) {
            playingFile.delete();
            playingFile = null;
        }
    }

    public synchronized boolean isBusy() {
        return busy;
    }
}
