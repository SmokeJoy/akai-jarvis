package it.akai.customremote.ai;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.media.MediaPlayer;
import android.os.Build;
import android.util.Log;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Comparator;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * CloudSpeechAdapter: disabled legacy cloud-speech compatibility shim for AKAI TV.
 * 
 * - Supporta Microsoft Azure Speech F0 (500.000 caratteri/mese gratuiti)
 * - Voci neurali italiane: it-IT-DiegoNeural (predefinita maschile), it-IT-IsabellaNeural (femminile)
 * - Cache audio su disco limitata rigorosamente a 8 MB con eviction LRU
 * - Esclusione dalla cache di dati sensibili / password
 * - AudioFocus Ducking: abbassa temporaneamente l'audio del video in riproduzione
 * - Fallback trasparente su Android TextToSpeech offline
 */
public class CloudSpeechAdapter {
    private static final String TAG = "AKAI_CloudSpeech";
    public static final long MAX_CACHE_BYTES = 8 * 1024 * 1024L; // 8 Megabytes

    public static final String VOICE_DIEGO = "it-IT-DiegoNeural";
    public static final String VOICE_ISABELLA = "it-IT-IsabellaNeural";
    public static final String VOICE_OFFLINE = "offline_espeak";

    private final Context mContext;
    private final AudioManager mAudioManager;
    private final File mCacheDir;
    private MediaPlayer mMediaPlayer;
    private final AtomicBoolean mIsPlaying = new AtomicBoolean(false);
    private volatile File mCurrentlyPlayingFile = null;
    private AudioFocusRequest mPlaybackFocusRequest = null;
    private PlaybackListener mGlobalListener = null;

    public interface PlaybackListener {
        void onPreparing();
        void onPlaying();
        void onCompleted();
        void onError(String error);
    }

    public void setPlaybackListener(PlaybackListener listener) {
        this.mGlobalListener = listener;
    }

    private final AudioManager.OnAudioFocusChangeListener mFocusListener = new AudioManager.OnAudioFocusChangeListener() {
        @Override
        public void onAudioFocusChange(int focusChange) {
            Log.d(TAG, "AudioFocus change: " + focusChange);
        }
    };

    public CloudSpeechAdapter(Context context) {
        mContext = context.getApplicationContext();
        mAudioManager = (AudioManager) mContext.getSystemService(Context.AUDIO_SERVICE);
        mCacheDir = new File(mContext.getCacheDir(), "tts_cache");
        if (!mCacheDir.exists()) {
            mCacheDir.mkdirs();
        }
    }

    /**
     * Sintetizza e riproduce l'audio neurale con AudioFocus ducking.
     * 
     * @param text Testo da pronunciare
     * @param voice Nome della voce (es. it-IT-DiegoNeural)
     * @param region Regione Azure (es. westeurope)
     * @param apiKey Chiave Azure Speech F0 (in chiaro)
     * @param onComplete Callback opzionale al termine riproduzione
     * @return true se avviato con successo, false se fallito o fallback necessario
     */
    public synchronized boolean speakNeural(String text, String voice, String region, String apiKey, final Runnable onComplete) {
        // Legacy API retained only for compatibility with existing TV settings.
        // No cloud TTS provider other than the owner-approved DeepSeek/Kimi AI
        // services is permitted. Never read credentials or open network here.
        Log.w(TAG, "Legacy Azure Neural TTS disabled by owner provider policy.");
        return false;
    }

    private File fetchFromAzure(String text, String voice, String region, String apiKey) {
        // Defense in depth: block this historical path even if called directly.
        return null;
    }

    private synchronized boolean playAudioFile(final File file, final Runnable onComplete) {
        try {
            mCurrentlyPlayingFile = file;
            requestAudioFocus();

            if (mMediaPlayer != null) {
                try { mMediaPlayer.release(); } catch (Exception ignored) {}
                mMediaPlayer = null;
            }

            mMediaPlayer = new MediaPlayer();
            mMediaPlayer.setAudioStreamType(AudioManager.STREAM_MUSIC);

            try (FileInputStream fis = new FileInputStream(file)) {
                mMediaPlayer.setDataSource(fis.getFD());
            }

            if (mGlobalListener != null) {
                mGlobalListener.onPreparing();
            }

            mMediaPlayer.setOnPreparedListener(new MediaPlayer.OnPreparedListener() {
                @Override
                public void onPrepared(MediaPlayer mp) {
                    mIsPlaying.set(true);
                    mp.start();
                    Log.d(TAG, "Neural speech playback started.");
                    if (mGlobalListener != null) {
                        mGlobalListener.onPlaying();
                    }
                }
            });

            mMediaPlayer.setOnCompletionListener(new MediaPlayer.OnCompletionListener() {
                @Override
                public void onCompletion(MediaPlayer mp) {
                    mIsPlaying.set(false);
                    abandonAudioFocus();
                    try { mp.release(); } catch (Exception ignored) {}
                    mMediaPlayer = null;
                    if (file != null && file.getName().startsWith("tts_tmp_")) {
                        try { file.delete(); } catch (Exception ignored) {}
                    }
                    mCurrentlyPlayingFile = null;
                    Log.d(TAG, "Neural speech playback completed. AudioFocus restored.");
                    if (mGlobalListener != null) {
                        mGlobalListener.onCompleted();
                    }
                    if (onComplete != null) onComplete.run();
                }
            });

            mMediaPlayer.setOnErrorListener(new MediaPlayer.OnErrorListener() {
                @Override
                public boolean onError(MediaPlayer mp, int what, int extra) {
                    mIsPlaying.set(false);
                    abandonAudioFocus();
                    try { mp.release(); } catch (Exception ignored) {}
                    mMediaPlayer = null;
                    if (file != null && file.getName().startsWith("tts_tmp_")) {
                        try { file.delete(); } catch (Exception ignored) {}
                    }
                    mCurrentlyPlayingFile = null;
                    Log.e(TAG, "MediaPlayer error: " + what + ", " + extra);
                    if (mGlobalListener != null) {
                        mGlobalListener.onError("MediaPlayer error: " + what);
                    }
                    return true;
                }
            });

            mMediaPlayer.prepareAsync();
            return true;

        } catch (Exception e) {
            Log.e(TAG, "Error playing audio file: " + e.getMessage());
            mCurrentlyPlayingFile = null;
            abandonAudioFocus();
            if (mGlobalListener != null) {
                mGlobalListener.onError(e.getMessage());
            }
            return false;
        }
    }

    public synchronized void stopCurrentPlayback() {
        if (mMediaPlayer != null) {
            try {
                if (mMediaPlayer.isPlaying()) {
                    mMediaPlayer.stop();
                }
                mMediaPlayer.release();
            } catch (Exception ignored) {}
            mMediaPlayer = null;
        }
        if (mCurrentlyPlayingFile != null && mCurrentlyPlayingFile.getName().startsWith("tts_tmp_")) {
            try { mCurrentlyPlayingFile.delete(); } catch (Exception ignored) {}
        }
        mCurrentlyPlayingFile = null;
        mIsPlaying.set(false);
        abandonAudioFocus();
        if (mGlobalListener != null) {
            mGlobalListener.onCompleted();
        }
    }

    public boolean isPlaying() {
        return mIsPlaying.get();
    }

    public long getCacheSizeBytes() {
        long total = 0;
        File[] files = mCacheDir.listFiles();
        if (files != null) {
            for (File f : files) {
                if (f.isFile()) total += f.length();
            }
        }
        return total;
    }

    public void clearCache() {
        File[] files = mCacheDir.listFiles();
        if (files != null) {
            for (File f : files) {
                try { f.delete(); } catch (Exception ignored) {}
            }
        }
        Log.i(TAG, "Audio cache cleared.");
    }

    private void enforceCacheLimit() {
        try {
            long total = getCacheSizeBytes();
            if (total > MAX_CACHE_BYTES) {
                Log.w(TAG, "Audio cache limit exceeded (" + total + " > " + MAX_CACHE_BYTES + " bytes). Pruning oldest files...");
                File[] files = mCacheDir.listFiles();
                if (files != null && files.length > 0) {
                    Arrays.sort(files, new Comparator<File>() {
                        @Override
                        public int compare(File f1, File f2) {
                            return Long.compare(f1.lastModified(), f2.lastModified());
                        }
                    });

                    for (File f : files) {
                        if (total <= 5 * 1024 * 1024L) break; // Riduce fino a 5 MB
                        if (f.equals(mCurrentlyPlayingFile)) continue; // Protegge il file attualmente in riproduzione
                        long len = f.length();
                        if (f.delete()) {
                            total -= len;
                        }
                    }
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "Error enforcing audio cache limit: " + e.getMessage());
        }
    }

    private File getCachedAudioFile(String text, String voice) {
        if (containsSensitiveData(text)) return null;
        String hash = md5(voice + "_" + text);
        File f = new File(mCacheDir, hash + ".mp3");
        if (f.exists() && f.length() > 0) {
            f.setLastModified(System.currentTimeMillis());
            return f;
        }
        return null;
    }

    private boolean containsSensitiveData(String text) {
        if (text == null) return false;
        String lower = text.toLowerCase();
        return lower.contains("password") || lower.contains("pin") || lower.contains("token") || lower.matches(".*\\b\\d{4,16}\\b.*");
    }

    private String escapeXml(String s) {
        if (s == null) return "";
        return s.replace("&", "&amp;")
                .replace("<", "&lt;")
                .replace(">", "&gt;")
                .replace("\"", "&quot;")
                .replace("'", "&apos;");
    }

    private String md5(String input) {
        try {
            MessageDigest md = MessageDigest.getInstance("MD5");
            byte[] digest = md.digest(input.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            for (byte b : digest) {
                sb.append(String.format("%02x", b));
            }
            return sb.toString();
        } catch (Exception e) {
            return String.valueOf(input.hashCode());
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
            Log.w(TAG, "Audio focus request notice: " + e.getMessage());
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
