package it.akai.customremote;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.media.AudioManager;
import android.media.tv.TvInputInfo;
import android.media.tv.TvInputManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import android.view.accessibility.AccessibilityNodeInfo;

import java.util.ArrayList;
import java.util.List;

public class TvController {
    private static final String TAG = "AKAI_TvController";

    private final Context context;
    private final AudioManager audioManager;
    private final UInputDriver uinputDriver;

    // Censused TV App Package Identifiers (allineati 1:1 con inventario hardware ADB)
    public static final String PKG_YOUTUBE = TvAppPackages.PKG_YOUTUBE;
    public static final String PKG_NETFLIX = TvAppPackages.PKG_NETFLIX;
    public static final String PKG_PRIME = TvAppPackages.PKG_PRIME;
    public static final String PKG_PLAYSTORE = TvAppPackages.PKG_PLAYSTORE;
    public static final String PKG_RAIPLAY = TvAppPackages.PKG_RAIPLAY;
    public static final String PKG_MEDIASET = TvAppPackages.PKG_MEDIASET;
    public static final String PKG_BROWSER_TVBRO = TvAppPackages.PKG_BROWSER_TVBRO;

    // Execution result data structure (subclasses top-level CommandResult for backward compatibility)
    public static class CommandResult extends it.akai.customremote.CommandResult {
        public CommandResult(boolean success, String message) {
            super(success, message, false);
        }

        public CommandResult(boolean success, String message, boolean unsupported) {
            super(success, message, unsupported);
        }
    }

    public TvController(Context context) {
        this.context = context.getApplicationContext();
        this.audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        this.uinputDriver = new UInputDriver();
        this.uinputDriver.init();
    }

    public synchronized CommandResult executeCommand(String action) {
        Log.i(TAG, "Executing TV command: " + action);

        switch (action) {
            // Volume Controls (Native Android SDK AudioManager - zero permissions needed)
            case "volume_up":
                audioManager.adjustSuggestedStreamVolume(AudioManager.ADJUST_RAISE, AudioManager.USE_DEFAULT_STREAM_TYPE, AudioManager.FLAG_SHOW_UI);
                return new CommandResult(true, "Volume +");

            case "volume_down":
                audioManager.adjustSuggestedStreamVolume(AudioManager.ADJUST_LOWER, AudioManager.USE_DEFAULT_STREAM_TYPE, AudioManager.FLAG_SHOW_UI);
                return new CommandResult(true, "Volume -");

            case "volume_mute":
                audioManager.adjustSuggestedStreamVolume(AudioManager.ADJUST_TOGGLE_MUTE, AudioManager.USE_DEFAULT_STREAM_TYPE, AudioManager.FLAG_SHOW_UI);
                return new CommandResult(true, "Mute alternato");

            // Home Navigation (Standard Intent + Accessibility)
            case "home":
                try {
                    Intent homeIntent = new Intent(Intent.ACTION_MAIN);
                    homeIntent.addCategory(Intent.CATEGORY_HOME);
                    homeIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    context.startActivity(homeIntent);
                    return new CommandResult(true, "Schermata Home");
                } catch (Exception e) {
                    if (AkaiAccessibilityService.getInstance() != null) {
                        boolean ok = AkaiAccessibilityService.getInstance().performGlobalAction(AkaiAccessibilityService.GLOBAL_ACTION_HOME);
                        return new CommandResult(ok, ok ? "Home (Accessibility)" : "Errore azione Home");
                    }
                    return new CommandResult(false, "Errore avvio Home: " + e.getMessage());
                }

            // Back Navigation (Accessibility performGlobalAction)
            case "back":
                if (AkaiAccessibilityService.getInstance() != null) {
                    boolean ok = AkaiAccessibilityService.getInstance().performGlobalAction(AkaiAccessibilityService.GLOBAL_ACTION_BACK);
                    if (ok) return new CommandResult(true, "Indietro");
                }
                // Try UInput fallback
                if (uinputDriver.isAvailable()) {
                    boolean sent = uinputDriver.sendKey(UInputDriver.KEY_BACK);
                    return new CommandResult(sent, sent ? "Indietro (UInput)" : "Errore UInput Back");
                }
                return new CommandResult(false, "Indietro non disponibile (richiede Servizio Accessibilità attivo)");

            // D-PAD Navigation (Primary: UInput Virtual Driver, Secondary: Accessibility Focus)
            case "up":
            case "dpad_up":
                return executeDpad(UInputDriver.KEY_UP, AccessibilityNodeInfo.FOCUS_INPUT, "Su");

            case "down":
            case "dpad_down":
                return executeDpad(UInputDriver.KEY_DOWN, AccessibilityNodeInfo.FOCUS_INPUT, "Giù");

            case "left":
            case "dpad_left":
                return executeDpad(UInputDriver.KEY_LEFT, AccessibilityNodeInfo.FOCUS_INPUT, "Sinistra");

            case "right":
            case "dpad_right":
                return executeDpad(UInputDriver.KEY_RIGHT, AccessibilityNodeInfo.FOCUS_INPUT, "Destra");

            case "center":
            case "select":
            case "enter":
            case "dpad_center":
                if (uinputDriver.isAvailable() && uinputDriver.sendKey(UInputDriver.KEY_ENTER)) {
                    return new CommandResult(true, "OK");
                }
                // Accessibility Click Fallback
                if (AkaiAccessibilityService.getInstance() != null) {
                    boolean clicked = AkaiAccessibilityService.getInstance().clickFocusedNode();
                    if (clicked) return new CommandResult(true, "OK (Accessibility Click)");
                }
                return new CommandResult(false, "D-Pad OK non supportato senza driver UInput o Accessibilità");

            // Menu Control
            case "menu":
                if (uinputDriver.isAvailable()) {
                    boolean sent = uinputDriver.sendKey(UInputDriver.KEY_MENU);
                    return new CommandResult(sent, sent ? "Menu" : "Errore invio Menu");
                }
                return new CommandResult(false, "Menu non disponibile senza driver UInput");

            // Channel Navigation
            case "channel_up":
                if (uinputDriver.isAvailable()) {
                    boolean sent = uinputDriver.sendKey(UInputDriver.KEY_CHANNELUP);
                    return new CommandResult(sent, sent ? "Canale +" : "Errore invio Canale +");
                }
                return new CommandResult(false, "Canale + non disponibile senza driver UInput");

            case "channel_down":
                if (uinputDriver.isAvailable()) {
                    boolean sent = uinputDriver.sendKey(UInputDriver.KEY_CHANNELDOWN);
                    return new CommandResult(sent, sent ? "Canale -" : "Errore invio Canale -");
                }
                return new CommandResult(false, "Canale - non disponibile senza driver UInput");

            case "channel_prev":
                if (uinputDriver.isAvailable()) {
                    boolean sent = uinputDriver.sendKey(UInputDriver.KEY_LAST);
                    return new CommandResult(sent, sent ? "Canale Precedente (Recall Last KEY_LAST)" : "Errore invio Canale Precedente");
                }
                return new CommandResult(false, "Canale Precedente non disponibile senza driver UInput");

            // Direct Inputs (DTV, HDMI 1/2/3, Source) via Android TV Input Framework (Home v8 aligned)
            case "input_tv":
                return executeTvInputAction("input_tv", "Digitale Terrestre");

            case "input_hdmi1":
                return executeTvInputAction("input_hdmi1", "HDMI 1");

            case "input_hdmi2":
                return executeTvInputAction("input_hdmi2", "HDMI 2");

            case "input_hdmi3":
                return executeTvInputAction("input_hdmi3", "HDMI 3");

            case "input_source":
                return executeTvInputAction("input_source", "Selezione Ingressi");

            // App Launch Shortcuts (allineati a censimento hardware TV)
            case "app_youtube":
            case "launch_youtube":
                return launchAppPackage(PKG_YOUTUBE, "YouTube TV");

            case "app_netflix":
            case "launch_netflix":
                return launchAppPackage(PKG_NETFLIX, "Netflix");

            case "app_prime":
            case "launch_prime":
                return launchAppPackage(PKG_PRIME, "Prime Video");

            case "app_playstore":
            case "launch_playstore":
                return launchAppPackage(PKG_PLAYSTORE, "Google Play Store");

            case "app_raiplay":
            case "launch_raiplay":
                return launchAppPackage(PKG_RAIPLAY, "RaiPlay");

            case "app_mediaset":
            case "launch_mediaset":
                return launchAppPackage(PKG_MEDIASET, "Mediaset Infinity");

            case "app_browser":
            case "launch_browser":
                return launchAppPackage(PKG_BROWSER_TVBRO, "TV Bro");

            case "diagnostics_sample":
                LocalDiagnosticsManager.getInstance(context).triggerManualSample("user_command");
                return new CommandResult(true, "Campione diagnostico registrato con successo");

            // Numeric Keys
            case "num_0": case "num_1": case "num_2": case "num_3": case "num_4":
            case "num_5": case "num_6": case "num_7": case "num_8": case "num_9":
                int num = Integer.parseInt(action.substring(4));
                int key = (num == 0) ? UInputDriver.KEY_0 : (UInputDriver.KEY_1 + (num - 1));
                if (uinputDriver.isAvailable() && uinputDriver.sendKey(key)) {
                    return new CommandResult(true, "Tasto " + num);
                }
                return new CommandResult(false, "Tastierino non disponibile senza driver UInput");

            // Power / Standby
            case "power":
                if (AkaiAccessibilityService.getInstance() != null) {
                    boolean ok = AkaiAccessibilityService.getInstance().performGlobalAction(AkaiAccessibilityService.GLOBAL_ACTION_POWER_DIALOG);
                    if (ok) return new CommandResult(true, "Menu Spegnimento visualizzato");
                }
                if (uinputDriver.isAvailable()) {
                    boolean sent = uinputDriver.sendKey(UInputDriver.KEY_POWER);
                    return new CommandResult(sent, sent ? "Power" : "Errore invio Power");
                }
                return new CommandResult(false, "Standby non supportato direttamente senza permessi di sistema");

            default:
                return new CommandResult(false, "Comando non riconosciuto: " + action, true);
        }
    }

    private CommandResult executeDpad(int uinputKey, int focusDirection, String label) {
        if (uinputDriver.isAvailable() && uinputDriver.sendKey(uinputKey)) {
            return new CommandResult(true, label);
        }
        // Fallback: Accessibility focus navigation
        if (AkaiAccessibilityService.getInstance() != null) {
            boolean navigated = AkaiAccessibilityService.getInstance().navigateFocus(focusDirection);
            if (navigated) return new CommandResult(true, label + " (Focus)");
        }
        return new CommandResult(false, "D-Pad " + label + " non disponibile su Android 9 senza UInput o Accessibilità");
    }

    private List<TvInputIntentPolicy.TifInputRecord> discoverTifInputs() {
        List<TvInputIntentPolicy.TifInputRecord> records = new ArrayList<>();
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) {
            return records;
        }
        try {
            TvInputManager mgr = (TvInputManager) context.getSystemService(Context.TV_INPUT_SERVICE);
            if (mgr == null) return records;
            List<TvInputInfo> infos = mgr.getTvInputList();
            if (infos == null) return records;
            for (TvInputInfo info : infos) {
                if (info == null) continue;
                String id = info.getId();
                if (id == null || id.trim().isEmpty()) continue;
                CharSequence lblCs = info.loadLabel(context);
                int hdmiPort = TvInputIntentPolicy.parseHdmiPortFromLabel(lblCs != null ? lblCs.toString() : null);
                if (hdmiPort < 0 && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    CharSequence customLbl = info.loadCustomLabel(context);
                    hdmiPort = TvInputIntentPolicy.parseHdmiPortFromLabel(customLbl != null ? customLbl.toString() : null);
                }
                int state = 0;
                try {
                    state = mgr.getInputState(id);
                } catch (Exception ignored) {}
                records.add(new TvInputIntentPolicy.TifInputRecord(
                        id,
                        info.getType(),
                        hdmiPort,
                        state,
                        info.isPassthroughInput()));
            }
        } catch (Exception e) {
            Log.w(TAG, "TIF discovery fallback (TvInputManager unavailable): " + e.getMessage());
        }
        return records;
    }

    private Intent buildIntentForSpec(TvInputIntentPolicy.LaunchSpec spec, boolean forceChannelMime) {
        Intent intent = (spec.intentAction != null) ? new Intent(spec.intentAction) : new Intent();
        if (spec.category != null) {
            intent.addCategory(spec.category);
        }
        if (spec.dataUri != null) {
            Uri uri = Uri.parse(spec.dataUri);
            if (forceChannelMime) {
                intent.setDataAndType(uri, TvInputIntentPolicy.TIF_CHANNEL_MIME_TYPE);
            } else {
                intent.setData(uri);
            }
        }
        if (spec.packageName != null && spec.componentClass != null) {
            intent.setComponent(new ComponentName(spec.packageName, spec.componentClass));
        } else if (spec.packageName != null) {
            intent.setPackage(spec.packageName);
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        return intent;
    }

    /**
     * Dispatches a TIF-aligned TV input intent after verifying resolution via PackageManager.
     * Note: a successful return (`CommandResult(true, ...)`) semantically means only `COMMAND_SENT`
     * (intent resolved and passed to `startActivity`), NEVER final `STATE_VERIFIED`.
     * Android 9 public API 28 `TvInputManager` exposes no active-input query for third-party apps.
     */
    private CommandResult executeTvInputAction(String action, String label) {
        PackageManager pm = context.getPackageManager();
        if (pm == null) {
            return new CommandResult(false, "PackageManager non disponibile per " + label);
        }
        List<TvInputIntentPolicy.LaunchSpec> specs = TvInputIntentPolicy.planCandidatesForAction(action, discoverTifInputs());
        for (TvInputIntentPolicy.LaunchSpec spec : specs) {
            try {
                Intent chosen = buildIntentForSpec(spec, false);
                ResolveInfo resolved = pm.resolveActivity(chosen, 0);
                if (resolved == null && spec.dataUri != null) {
                    Intent mimeIntent = buildIntentForSpec(spec, true);
                    resolved = pm.resolveActivity(mimeIntent, 0);
                    if (resolved != null) {
                        chosen = mimeIntent;
                    }
                }
                if (resolved == null) {
                    Log.d(TAG, "TIF candidate unresolved [" + spec.kind + "] for " + action);
                    continue;
                }
                String resolvedName = (resolved.activityInfo != null)
                        ? (resolved.activityInfo.packageName + "/" + resolved.activityInfo.name)
                        : "resolved";
                Log.i(TAG, "Launching TV input [" + label + "] via " + spec.kind + " -> " + resolvedName);
                context.startActivity(chosen);
                return new CommandResult(true, "Richiesta ingresso " + label + " inviata via " + spec.kind);
            } catch (Exception e) {
                Log.w(TAG, "TIF candidate failed [" + spec.kind + "]: " + e.getMessage());
            }
        }
        return new CommandResult(false, "Nessun gestore TV Input Framework disponibile per " + label);
    }

    public CommandResult launchAppPackage(String pkg, String appName) {
        try {
            PackageManager pm = context.getPackageManager();
            // TV-native applications may expose only LEANBACK_LAUNCHER, not a phone launcher.
            Intent intent = pm.getLeanbackLaunchIntentForPackage(pkg);
            if (intent == null) intent = pm.getLaunchIntentForPackage(pkg);
            if (intent != null) {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
                context.startActivity(intent);
                return new CommandResult(true, "Avvio " + appName);
            }
            return new CommandResult(false, appName + " non risulta installato sulla TV (" + pkg + ")", true);
        } catch (Exception e) {
            return new CommandResult(false, "Errore avvio " + appName + ": " + e.getMessage());
        }
    }

    public CommandResult setVolumeAbsolute(int level) {
        try {
            int max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC);
            int target = Math.max(0, Math.min(level, max));
            audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, target, AudioManager.FLAG_SHOW_UI);
            return new CommandResult(true, "Volume impostato a " + target);
        } catch (Exception e) {
            return new CommandResult(false, "Errore impostazione volume: " + e.getMessage());
        }
    }

    /**
     * Dispatches DTV switch + channel keystrokes via {@link DtvChannelTuningCoordinator}.
     * Note: a positive {@link CommandResult} means only COMMAND_SENT (keystrokes queued),
     * NEVER final TV STATE_VERIFIED.
     */
    public CommandResult tuneDtvChannel(int channel) {
        try {
            it.akai.customremote.CommandResult res = DtvChannelTuningCoordinator.tuneChannel(
                    channel,
                    new DtvChannelTuningCoordinator.HardwareBridge() {
                        @Override
                        public boolean isUInputAvailable() {
                            return uinputDriver != null && uinputDriver.isAvailable();
                        }

                        @Override
                        public it.akai.customremote.CommandResult switchToDtv() {
                            return executeTvInputAction("input_tv", "Digitale Terrestre");
                        }

                        @Override
                        public boolean sendKey(int keyCode) {
                            return uinputDriver.sendKey(keyCode);
                        }

                        @Override
                        public void sleepMs(long ms) throws InterruptedException {
                            Thread.sleep(ms);
                        }
                    });
            return new CommandResult(res.success, res.message, res.unsupported);
        } catch (Exception e) {
            return new CommandResult(false, "Errore sintonizzazione canale: " + e.getMessage());
        }
    }

    public CommandResult executeActionSequence(org.json.JSONArray actions) {
        if (actions == null || actions.length() == 0) {
            return new CommandResult(true, "Nessuna azione da eseguire");
        }

        int stepCount = actions.length();
        if (stepCount > 15) {
            return new CommandResult(false, "Sequenza troppo lunga (" + stepCount + " passi > 15 consentiti)");
        }

        try {
            for (int i = 0; i < stepCount; i++) {
                if (Thread.currentThread().isInterrupted()) {
                    return new CommandResult(false, "Sequenza interrotta prima del passo " + (i + 1) + ": stato non verificato");
                }
                org.json.JSONObject step = actions.getJSONObject(i);
                String type = step.optString("type", "");

                Log.d(TAG, "Executing sequence step [" + i + "]: " + type);

                switch (type) {
                    case "open_app":
                    case "launch_app": {
                        String pkg = step.optString("pkg", step.optString("package", ""));
                        String name = step.optString("name", pkg);
                        CommandResult res = launchAppPackage(pkg, name);
                        if (!res.success) {
                            return new CommandResult(false, "Fallito al passo " + (i + 1) + " (apri " + name + "): " + res.message);
                        }
                        break;
                    }
                    case "press_key":
                    case "command": {
                        String action = step.optString("key", step.optString("action", ""));
                        CommandResult res = executeCommand(action);
                        if (!res.success) {
                            return new CommandResult(false, "Fallito al passo " + (i + 1) + " (tasto " + action + "): " + res.message);
                        }
                        break;
                    }
                    case "click_accessibility_node":
                    case "click_text": {
                        String text = step.optString("text", "");
                        boolean clicked = false;
                        if (AkaiAccessibilityService.getInstance() != null) {
                            // The A2 planner gate sets this from a fresh accessible
                            // screen observation. Exact prevents unrelated substring matches.
                            clicked = AkaiAccessibilityService.getInstance().clickNodeByText(
                                    text, step.optBoolean("exact", false));
                            Log.d(TAG, "clickNodeByText(\"" + text + "\") -> " + clicked);
                        }
                        if (!clicked) {
                            boolean optional = step.optBoolean("optional", false);
                            if (!optional) {
                                return new CommandResult(false, "Fallito al passo " + (i + 1) + ": nodo UI \"" + text + "\" non trovato a schermo");
                            }
                        }
                        break;
                    }
                    case "set_volume":
                    case "volume_set": {
                        int level = step.optInt("level", 15);
                        CommandResult res = setVolumeAbsolute(level);
                        if (!res.success) {
                            return new CommandResult(false, "Fallito al passo " + (i + 1) + " (volume): " + res.message);
                        }
                        break;
                    }
                    case "select_channel":
                    case "tune_channel": {
                        int ch = step.optInt("number", -1);
                        CommandResult res = tuneDtvChannel(ch);
                        if (!res.success) {
                            return new CommandResult(false, "Fallito al passo " + (i + 1) + " (canale " + ch + "): " + res.message);
                        }
                        break;
                    }
                    case "read_ui_state": {
                        it.akai.customremote.ai.ScreenPerceptionEngine.PerceptionSnapshot snap =
                                it.akai.customremote.ai.ScreenPerceptionEngine.capture(context);
                        Log.i(TAG, "read_ui_state: pkg=" + snap.foregroundPackage + ", playerActive=" + snap.isPlayerActive);
                        break;
                    }
                    case "finish_task": {
                        Log.i(TAG, "finish_task: " + step.optString("status", "completed"));
                        break;
                    }
                    case "wait": {
                        long ms = Math.min(step.optLong("ms", 1000), 7000);
                        try {
                            Thread.sleep(ms);
                        } catch (InterruptedException e) {
                            Thread.currentThread().interrupt();
                            return new CommandResult(false, "Sequenza interrotta durante attesa al passo " + (i + 1) + ": stato non verificato");
                        }
                        break;
                    }
                    default:
                        Log.w(TAG, "Unknown action type: " + type + " (rejected)");
                        return new CommandResult(false, "Fallito al passo " + (i + 1) + ": tipo azione sconosciuto o non consentito (\"" + type + "\")");
                }
            }
            return new CommandResult(true, "Sequenza eseguita con successo (" + actions.length() + " passi)");
        } catch (Exception e) {
            Log.e(TAG, "Error executing action sequence: " + e.getMessage(), e);
            return new CommandResult(false, "Errore esecuzione sequenza: " + e.getMessage());
        }
    }

    public synchronized CommandResult injectText(String text) {
        if (text == null || text.isEmpty()) {
            return new CommandResult(false, "Testo vuoto");
        }

        // 1. Accessibility SET_TEXT on focused input node (Leanback & standard)
        if (AkaiAccessibilityService.getInstance() != null) {
            boolean ok = AkaiAccessibilityService.getInstance().setFocusedText(text);
            if (ok) return new CommandResult(true, "Testo inserito nel campo attivo");
        }

        // 2. Fallback: uinput hardware keystroke typing
        if (uinputDriver.isAvailable()) {
            boolean ok = uinputDriver.typeString(text);
            if (ok) return new CommandResult(true, "Testo digitato tramite emulazione hardware");
        }

        return new CommandResult(false, "Nessun campo di testo attualmente attivo a schermo");
    }

    public boolean isUInputReady() {
        return uinputDriver.isAvailable();
    }

    public void cleanup() {
        uinputDriver.close();
    }
}
