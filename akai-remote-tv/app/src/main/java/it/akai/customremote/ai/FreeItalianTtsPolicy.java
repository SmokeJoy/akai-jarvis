package it.akai.customremote.ai;

import java.util.Calendar;
import java.util.Locale;
import java.util.TimeZone;
import java.util.regex.Pattern;

/**
 * Strict, non-billing guard for the personal FreeTTS free account.
 *
 * No credit card, paid plan, extra endpoint, automatic upgrade or credentials
 * can be acquired by this code. Provider quotas are NOT a substitute for our
 * independent and deliberately lower local budget.
 */
public final class FreeItalianTtsPolicy {
    public static final String PROVIDER = "freetts_free";
    public static final String ENDPOINT = "https://freetts.org/api/v1/tts";
    public static final String AUDIO_PREFIX = "https://freetts.org/api/audio/";
    public static final String VOICE_MALE = "it-IT-DiegoNeural";
    public static final String VOICE_FEMALE = "it-IT-IsabellaNeural";
    public static final int MAX_MONTHLY_CHARS = 5000;
    public static final int MAX_UTTERANCE_CHARS = 600;
    public static final int MAX_AUDIO_BYTES = 2 * 1024 * 1024;
    private static final Pattern FILE_ID = Pattern.compile("[A-Za-z0-9_-]{1,120}");
    private static final Pattern SENSITIVE = Pattern.compile(
            "(?i)(password|passwd|passcode|codice\\s+(?:pin|otp)|token|secret|"
            + "api[ _-]?key|bearer|iban|numero\\s+di\\s+carta|"
            + "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,})");
    private static final Pattern NUMBER_SEQUENCE = Pattern.compile("\\b\\d{4,16}\\b");

    private FreeItalianTtsPolicy() {}

    public static boolean voiceAllowed(String voice) {
        return VOICE_MALE.equals(voice) || VOICE_FEMALE.equals(voice);
    }

    public static boolean textAllowed(String text) {
        return text != null && text.length() > 0
                && text.length() <= MAX_UTTERANCE_CHARS
                && !text.trim().isEmpty() && !SENSITIVE.matcher(text).find()
                && !NUMBER_SEQUENCE.matcher(text).find();
    }

    public static boolean fileIdAllowed(String id) {
        return id != null && FILE_ID.matcher(id).matches();
    }

    public static boolean canReserve(int storedMonth, int used, int currentMonth, int chars) {
        if (currentMonth < storedMonth || used < 0 || used > MAX_MONTHLY_CHARS
                || chars < 1 || chars > MAX_UTTERANCE_CHARS) return false;
        int effectiveUsed = currentMonth == storedMonth ? used : 0;
        return effectiveUsed <= MAX_MONTHLY_CHARS - chars;
    }

    public static int currentUtcMonth() {
        Calendar c = Calendar.getInstance(TimeZone.getTimeZone("UTC"), Locale.US);
        return c.get(Calendar.YEAR) * 100 + c.get(Calendar.MONTH) + 1;
    }
}
