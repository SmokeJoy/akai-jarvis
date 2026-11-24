package it.akai.customremote;

/**
 * Pure Java 8 fail-closed coordinator for DTV channel tuning.
 *
 * Enforces:
 * - Strict channel bounds (1..9999) before touching TV input or UInput.
 * - Pre-start, initial-wait (600 ms), inter-digit (250 ms), and pre-ENTER
 *   interrupt checks: any InterruptedException restores the thread interrupt
 *   flag and aborts immediately without injecting further key events.
 * - Semantic truth: {@link CommandResult#success} == true means only that
 *   keys were dispatched (COMMAND_SENT), NEVER final TV STATE_VERIFIED.
 */
public final class DtvChannelTuningCoordinator {
    public static final int MIN_CHANNEL = 1;
    public static final int MAX_CHANNEL = 9999;
    public static final long INITIAL_DTV_SETTLE_MS = 600L;
    public static final long DIGIT_INTERVAL_MS = 250L;

    // Must match UInputDriver / <linux/input.h> keycodes.
    public static final int KEY_0 = 11;
    public static final int KEY_1 = 2;
    public static final int KEY_ENTER = 28;

    public interface HardwareBridge {
        boolean isUInputAvailable();
        CommandResult switchToDtv();
        boolean sendKey(int keyCode);
        void sleepMs(long ms) throws InterruptedException;
    }

    private DtvChannelTuningCoordinator() {}

    /**
     * Dispatches DTV switch + numeric channel keystrokes with standard timings.
     * Note: a successful return means only COMMAND_SENT (keystrokes queued/sent
     * to uinput), NEVER final STATE_VERIFIED.
     */
    public static CommandResult tuneChannel(int channel, HardwareBridge bridge) {
        return tuneChannel(channel, INITIAL_DTV_SETTLE_MS, DIGIT_INTERVAL_MS, bridge);
    }

    /**
     * Dispatches DTV switch + numeric channel keystrokes fail-closed under interruption.
     * Note: a successful return means only COMMAND_SENT, NEVER final STATE_VERIFIED.
     */
    public static CommandResult tuneChannel(int channel, long initialWaitMs, long digitIntervalMs, HardwareBridge bridge) {
        if (channel < MIN_CHANNEL || channel > MAX_CHANNEL) {
            return new CommandResult(false, "Numero canale DTV non valido (" + channel + "): consentiti 1..9999");
        }
        if (bridge == null || !bridge.isUInputAvailable()) {
            return new CommandResult(false, "Driver UInput non disponibile per sintonizzare canale");
        }
        if (Thread.currentThread().isInterrupted()) {
            return new CommandResult(false, "Sintonizzazione interrotta prima dell'avvio: nessun tasto inviato");
        }

        CommandResult dtvRes = bridge.switchToDtv();
        if (dtvRes == null || !dtvRes.success) {
            return (dtvRes != null)
                    ? dtvRes
                    : new CommandResult(false, "Passaggio a Digitale Terrestre fallito: nessun tasto inviato");
        }
        if (Thread.currentThread().isInterrupted()) {
            return new CommandResult(false, "Sintonizzazione interrotta dopo switch DTV: nessun tasto inviato");
        }

        if (initialWaitMs > 0L) {
            try {
                bridge.sleepMs(initialWaitMs);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return new CommandResult(false, "Sintonizzazione interrotta durante attesa iniziale DTV: nessun tasto inviato");
            }
            if (Thread.currentThread().isInterrupted()) {
                return new CommandResult(false, "Sintonizzazione interrotta durante attesa iniziale DTV: nessun tasto inviato");
            }
        }

        String chStr = String.valueOf(channel);
        for (int i = 0; i < chStr.length(); i++) {
            if (Thread.currentThread().isInterrupted()) {
                return new CommandResult(false, "Sintonizzazione interrotta durante digitazione canale: stato non verificato");
            }
            char c = chStr.charAt(i);
            if (c < '0' || c > '9') {
                return new CommandResult(false, "Carattere canale DTV non valido: stato non verificato");
            }
            int digit = c - '0';
            int keyCode = (digit == 0) ? KEY_0 : (KEY_1 + (digit - 1));
            if (!bridge.sendKey(keyCode)) {
                return new CommandResult(false, "Invio cifra canale fallito: sintonizzazione non verificata");
            }
            if (digitIntervalMs > 0L) {
                try {
                    bridge.sleepMs(digitIntervalMs);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    return new CommandResult(false, "Sintonizzazione interrotta durante digitazione canale: stato non verificato");
                }
            }
        }

        if (Thread.currentThread().isInterrupted()) {
            return new CommandResult(false, "Sintonizzazione interrotta prima della conferma canale: stato non verificato");
        }
        if (!bridge.sendKey(KEY_ENTER)) {
            return new CommandResult(false, "Invio conferma canale fallito: sintonizzazione non verificata");
        }
        return new CommandResult(true, "Comandi canale " + channel + " inviati (stato TV non verificato)");
    }
}
