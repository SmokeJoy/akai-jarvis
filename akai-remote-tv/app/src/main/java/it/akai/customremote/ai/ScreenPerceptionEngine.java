package it.akai.customremote.ai;

import android.content.Context;
import android.graphics.Rect;
import android.media.AudioManager;
import android.util.Log;
import android.view.accessibility.AccessibilityNodeInfo;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

import it.akai.customremote.AkaiAccessibilityService;

/**
 * ScreenPerceptionEngine: Sistema di percezione a 4 livelli per Android 9 (API 28).
 * 
 * Livello 1: Stato App & Package (identificazione pacchetto in primo piano).
 * Livello 2: Gerarchia Accessibile (albero nodi, classi View).
 * Livello 3: Testi, Focus, Nodi Cliccabili e Rilevamento Player Video (SurfaceView, ExoPlayer).
 * Livello 4: Protezione Privacy & Sicurezza (blocco assoluto schermate con campi password).
 */
public class ScreenPerceptionEngine {
    private static final String TAG = "AKAI_Perception";

    public static class ClickableElement {
        public final String text;
        public final String className;
        public final String resId;
        public final Rect bounds;

        public ClickableElement(String text, String className, String resId, Rect bounds) {
            this.text = text;
            this.className = className;
            this.resId = resId;
            this.bounds = bounds;
        }
    }

    public static class PerceptionSnapshot {
        public final String foregroundPackage;
        public final List<String> visibleTexts;
        public final List<ClickableElement> clickableElements;
        public final String focusedElementText;
        public final boolean hasSensitiveFields;
        public final boolean isPlayerActive;
        public final boolean isMusicActive;
        public final long timestamp;

        public PerceptionSnapshot(String foregroundPackage, List<String> visibleTexts,
                                  List<ClickableElement> clickableElements, String focusedElementText,
                                  boolean hasSensitiveFields, boolean isPlayerActive, boolean isMusicActive) {
            this.foregroundPackage = foregroundPackage;
            this.visibleTexts = visibleTexts;
            this.clickableElements = clickableElements;
            this.focusedElementText = focusedElementText;
            this.hasSensitiveFields = hasSensitiveFields;
            this.isPlayerActive = isPlayerActive;
            this.isMusicActive = isMusicActive;
            this.timestamp = System.currentTimeMillis();
        }

        public String toContextPrompt() {
            if (hasSensitiveFields) {
                return "Schermata protetta con credenziali/password. Lettura testi bloccata per sicurezza.";
            }

            StringBuilder sb = new StringBuilder();
            sb.append("Pacchetto attivo: ").append(foregroundPackage).append("\n");
            if (focusedElementText != null) {
                sb.append("Elemento con focus: \"").append(focusedElementText).append("\"\n");
            }
            if (isPlayerActive || isMusicActive) {
                sb.append("Stato Player: IN RIPRODUZIONE (Media/Audio Attivo)\n");
            }
            sb.append("Testi visibili a schermo:\n");
            for (String t : visibleTexts) {
                sb.append(" - \"").append(t).append("\"\n");
            }
            sb.append("Elementi cliccabili:\n");
            for (ClickableElement el : clickableElements) {
                sb.append(" - [").append(el.text != null ? el.text : el.resId).append("]\n");
            }
            return sb.toString();
        }

        public boolean containsText(String query, boolean exact) {
            if (query == null) return false;
            String q = query.trim().toLowerCase();
            for (String t : visibleTexts) {
                String tl = t.toLowerCase();
                if (exact ? tl.equals(q) : tl.contains(q)) return true;
            }
            return false;
        }
    }

    public static PerceptionSnapshot capture(Context context) {
        AkaiAccessibilityService service = AkaiAccessibilityService.getInstance();
        if (context == null && service != null) {
            context = service.getApplicationContext();
        }

        boolean musicActive = false;
        if (context != null) {
            try {
                AudioManager am = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
                if (am != null) musicActive = am.isMusicActive();
            } catch (Exception ignored) {}
        }

        if (service == null) {
            return new PerceptionSnapshot("unknown", new ArrayList<String>(), new ArrayList<ClickableElement>(), null, false, false, musicActive);
        }

        AccessibilityNodeInfo root = service.getRootInActiveWindow();
        String pkg = "unknown";

        if (root == null) {
            try {
                List<android.view.accessibility.AccessibilityWindowInfo> windows = service.getWindows();
                if (windows != null) {
                    for (android.view.accessibility.AccessibilityWindowInfo w : windows) {
                        AccessibilityNodeInfo wRoot = w.getRoot();
                        if (wRoot != null) {
                            if (wRoot.getPackageName() != null) {
                                pkg = wRoot.getPackageName().toString();
                            }
                            root = wRoot;
                            break;
                        }
                    }
                }
            } catch (Exception ignored) {}
        }

        if (root == null) {
            return new PerceptionSnapshot(pkg, new ArrayList<String>(), new ArrayList<ClickableElement>(), null, false, false, musicActive);
        }

        if (root.getPackageName() != null) {
            pkg = root.getPackageName().toString();
        }
        List<String> texts = new ArrayList<>();
        List<ClickableElement> clickables = new ArrayList<>();
        String[] focusedHolder = new String[1];
        boolean[] sensitiveHolder = new boolean[1];
        boolean[] playerHolder = new boolean[1];

        try {
            traverseNode(root, texts, clickables, focusedHolder, sensitiveHolder, playerHolder, 0);
        } finally {
            root.recycle();
        }

        return new PerceptionSnapshot(pkg, texts, clickables, focusedHolder[0], sensitiveHolder[0], playerHolder[0], musicActive);
    }

    public static PerceptionSnapshot capture() {
        return capture(null);
    }

    private static void traverseNode(AccessibilityNodeInfo node, List<String> texts,
                                     List<ClickableElement> clickables, String[] focusedHolder,
                                     boolean[] sensitiveHolder, boolean[] playerHolder, int depth) {
        if (node == null || depth > 15 || texts.size() > 40) return;

        // Livello 4: Protezione Privacy
        if (node.isPassword()) {
            sensitiveHolder[0] = true;
            return;
        }

        // Rilevamento Player Video (ExoPlayer, SurfaceView, VideoView, React Native/WebView Player)
        String resId = node.getViewIdResourceName();
        String cls = node.getClassName() != null ? node.getClassName().toString() : "";
        if (resId != null) {
            String resLower = resId.toLowerCase();
            if (resLower.contains("playerview") || resLower.contains("exo_") ||
                resLower.contains("player-container") || resLower.contains("react-player-root") ||
                resLower.contains("videoplayer") || resLower.contains("playback")) {
                playerHolder[0] = true;
            }
        }
        if (cls.contains("SurfaceView") || cls.contains("VideoView")) {
            playerHolder[0] = true;
        }

        // Testo o ContentDescription
        CharSequence textCs = node.getText();
        CharSequence descCs = node.getContentDescription();
        String nodeText = null;

        if (textCs != null && textCs.length() > 0) {
            nodeText = textCs.toString().trim();
        } else if (descCs != null && descCs.length() > 0) {
            nodeText = descCs.toString().trim();
        }

        if (nodeText != null && !nodeText.isEmpty() && !texts.contains(nodeText)) {
            texts.add(nodeText);
        }

        // Focus
        if (node.isFocused() && nodeText != null) {
            focusedHolder[0] = nodeText;
        }

        // Cliccabilità
        if (node.isClickable() && clickables.size() < 25) {
            Rect bounds = new Rect();
            node.getBoundsInScreen(bounds);
            clickables.add(new ClickableElement(nodeText, cls, resId, bounds));
        }

        int count = node.getChildCount();
        for (int i = 0; i < count; i++) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child != null) {
                traverseNode(child, texts, clickables, focusedHolder, sensitiveHolder, playerHolder, depth + 1);
                child.recycle();
            }
        }
    }

    public static boolean evaluateSuccessCondition(PerceptionSnapshot snapshot, String conditionJsonStr) {
        if (snapshot == null) return false;
        if (conditionJsonStr == null || conditionJsonStr.trim().isEmpty()) {
            // Nessuna condizione esplicita: RIFIUTATA la validazione automatica (non è verificabile)
            Log.w(TAG, "evaluateSuccessCondition: conditionJsonStr mancante o vuoto -> VERIFICA FALLITA (UNVERIFIED)");
            return false;
        }

        try {
            JSONObject cond = new JSONObject(conditionJsonStr);
            String type = cond.optString("type", "");

            switch (type) {
                case "player_active": {
                    String expectedPkg = cond.optString("pkg", "");
                    String expectedText = cond.optString("channel_text", cond.optString("expected_text", ""));

                    // Se l'interfaccia è sul Launcher o Home, la riproduzione non è attiva
                    if (snapshot.foregroundPackage.contains("launcher") || snapshot.foregroundPackage.contains("customhome") || snapshot.foregroundPackage.isEmpty()) {
                        Log.i(TAG, "evaluate player_active -> false (foreground è launcher/home: " + snapshot.foregroundPackage + ")");
                        return false;
                    }

                    boolean pkgMatches = expectedPkg.isEmpty() || snapshot.foregroundPackage.contains(expectedPkg);
                    boolean isPlaying = snapshot.isPlayerActive || snapshot.isMusicActive;

                    boolean contentMatches = true;
                    if (!expectedText.isEmpty()) {
                        contentMatches = snapshot.containsText(expectedText, false);
                    }

                    boolean ok = pkgMatches && isPlaying && contentMatches;
                    Log.i(TAG, "evaluate player_active (expectedPkg=" + expectedPkg + ", currentPkg=" + snapshot.foregroundPackage
                            + ", expectedText=" + expectedText + "): isPlayerView=" + snapshot.isPlayerActive + ", isAudioMusic=" + snapshot.isMusicActive + " -> " + ok);
                    return ok;
                }
                case "contains_text": {
                    String val = cond.optString("value", "");
                    boolean res = snapshot.containsText(val, false);
                    Log.i(TAG, "evaluate contains_text (\"" + val + "\") -> " + res);
                    return res;
                }
                case "pkg_is": {
                    String val = cond.optString("value", "");
                    boolean res = snapshot.foregroundPackage.equals(val);
                    Log.i(TAG, "evaluate pkg_is (\"" + val + "\", current=" + snapshot.foregroundPackage + ") -> " + res);
                    return res;
                }
                case "focused_is": {
                    String val = cond.optString("value", "");
                    boolean res = snapshot.focusedElementText != null && snapshot.focusedElementText.equalsIgnoreCase(val);
                    return res;
                }
                case "any_of_texts": {
                    JSONArray arr = cond.optJSONArray("values");
                    if (arr != null) {
                        for (int i = 0; i < arr.length(); i++) {
                            if (snapshot.containsText(arr.getString(i), false)) {
                                Log.i(TAG, "evaluate any_of_texts matched: \"" + arr.getString(i) + "\"");
                                return true;
                            }
                        }
                    }
                    return false;
                }
                default:
                    Log.w(TAG, "Tipo condizione sconosciuto: " + type + " -> VERIFICA RIFIUTATA");
                    return false;
            }
        } catch (Exception e) {
            Log.e(TAG, "Errore parsing condizione JSON: " + e.getMessage() + " -> VERIFICA FALLITA", e);
            return false;
        }
    }
}
