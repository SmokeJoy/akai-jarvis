package it.akai.customremote;

import android.accessibilityservice.AccessibilityService;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.os.Bundle;
import android.util.Log;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;

import java.util.List;

public class AkaiAccessibilityService extends AccessibilityService {
    private static final String TAG = "AKAI_Accessibility";
    private static AkaiAccessibilityService sInstance = null;
    private volatile String lastWindowPackage = null;
    private volatile String lastWindowClass = null;
    private volatile long lastWindowEventAtMs = 0L;
    private volatile long lastContentEventAtMs = 0L;

    public static AkaiAccessibilityService getInstance() {
        return sInstance;
    }

    public String getLastWindowPackage() {
        return lastWindowPackage;
    }

    public String getLastWindowClass() {
        return lastWindowClass;
    }

    public long getLastWindowEventAtMs() {
        return lastWindowEventAtMs;
    }

    public long getLastContentEventAtMs() {
        return lastContentEventAtMs;
    }

    // =========================================================================
    // PERCEZIONE SCHERMO & CLOSED-LOOP AI
    // =========================================================================

    public String getCurrentForegroundPackage() {
        AccessibilityNodeInfo root = getRootInActiveWindow();
        if (root == null) return "unknown";
        try {
            CharSequence pkg = root.getPackageName();
            return pkg != null ? pkg.toString() : "unknown";
        } finally {
            root.recycle();
        }
    }

    public String getScreenHierarchySummary() {
        AccessibilityNodeInfo root = getRootInActiveWindow();
        if (root == null) return "Nessuna finestra attiva accessibile.";

        StringBuilder sb = new StringBuilder();
        try {
            CharSequence pkg = root.getPackageName();
            sb.append("Pacchetto in primo piano: ").append(pkg != null ? pkg : "unknown").append("\n");
            sb.append("Elementi di testo visibili a schermo:\n");

            java.util.List<String> texts = new java.util.ArrayList<>();
            collectNodeTexts(root, texts, 0);

            for (String t : texts) {
                sb.append(" - \"").append(t).append("\"\n");
            }
            if (texts.isEmpty()) {
                sb.append(" (Nessun testo statico o accessibile rilevato)\n");
            }
        } finally {
            root.recycle();
        }
        return sb.toString();
    }

    private void collectNodeTexts(AccessibilityNodeInfo node, java.util.List<String> list, int depth) {
        if (node == null || depth > 12 || list.size() > 40) return;

        CharSequence text = node.getText();
        if (text != null && text.length() > 0) {
            String s = text.toString().trim();
            if (!s.isEmpty() && !list.contains(s)) {
                list.add(s);
            }
        }

        CharSequence desc = node.getContentDescription();
        if (desc != null && desc.length() > 0) {
            String s = desc.toString().trim();
            if (!s.isEmpty() && !list.contains(s)) {
                list.add(s);
            }
        }

        int count = node.getChildCount();
        for (int i = 0; i < count; i++) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child != null) {
                collectNodeTexts(child, list, depth + 1);
                child.recycle();
            }
        }
    }

    public boolean clickNodeByText(String targetText, boolean exact) {
        if (targetText == null || targetText.trim().isEmpty()) return false;
        String query = targetText.trim().toLowerCase();

        AccessibilityNodeInfo root = getRootInActiveWindow();
        if (root == null) return false;

        try {
            return searchAndClick(root, query, exact);
        } finally {
            root.recycle();
        }
    }

    private boolean searchAndClick(AccessibilityNodeInfo node, String query, boolean exact) {
        if (node == null) return false;

        CharSequence nodeText = node.getText();
        CharSequence nodeDesc = node.getContentDescription();

        boolean match = false;
        if (nodeText != null) {
            String t = nodeText.toString().trim().toLowerCase();
            match = exact ? t.equals(query) : t.contains(query);
        }
        if (!match && nodeDesc != null) {
            String d = nodeDesc.toString().trim().toLowerCase();
            match = exact ? d.equals(query) : d.contains(query);
        }

        if (match) {
            // Se il nodo stesso è cliccabile, cliccalo
            if (node.isClickable()) {
                Log.i(TAG, "Clicking matched node: " + (nodeText != null ? nodeText : nodeDesc));
                return node.performAction(AccessibilityNodeInfo.ACTION_CLICK);
            }
            // Altrimenti risali ai genitori cliccabili (spesso in Leanback CardView/ItemView)
            AccessibilityNodeInfo parent = node.getParent();
            while (parent != null) {
                if (parent.isClickable()) {
                    Log.i(TAG, "Clicking clickable parent of matched node: " + (nodeText != null ? nodeText : nodeDesc));
                    boolean clicked = parent.performAction(AccessibilityNodeInfo.ACTION_CLICK);
                    parent.recycle();
                    return clicked;
                }
                AccessibilityNodeInfo grandParent = parent.getParent();
                parent.recycle();
                parent = grandParent;
            }
        }

        // Cerca ricorsivamente nei figli
        int count = node.getChildCount();
        for (int i = 0; i < count; i++) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child != null) {
                boolean clicked = searchAndClick(child, query, exact);
                child.recycle();
                if (clicked) return true;
            }
        }

        return false;
    }

    @Override
    protected void onServiceConnected() {
        super.onServiceConnected();
        sInstance = this;
        Log.i(TAG, "AkaiAccessibilityService connected and ready!");
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        if (event == null) {
            return;
        }
        int eventType = event.getEventType();
        if (eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED) {
            lastContentEventAtMs = System.currentTimeMillis();
        } else if (eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            long now = System.currentTimeMillis();
            lastContentEventAtMs = now;
            CharSequence pkgCs = event.getPackageName();
            CharSequence clsCs = event.getClassName();
            String pkg = pkgCs != null ? pkgCs.toString().trim() : "";
            String cls = clsCs != null ? clsCs.toString().trim() : "";
            if (!pkg.isEmpty() && !cls.isEmpty() && !cls.contains("Toast")) {
                lastWindowPackage = pkg;
                lastWindowClass = cls;
                lastWindowEventAtMs = now;
            }
        }
    }

    @Override
    public void onInterrupt() {
        Log.w(TAG, "AkaiAccessibilityService interrupted");
    }

    @Override
    public void onDestroy() {
        super.onDestroy();
        lastWindowPackage = null;
        lastWindowClass = null;
        lastWindowEventAtMs = 0L;
        lastContentEventAtMs = 0L;
        if (sInstance == this) {
            sInstance = null;
        }
        Log.i(TAG, "AkaiAccessibilityService destroyed");
    }

    public boolean clickFocusedNode() {
        AccessibilityNodeInfo root = getRootInActiveWindow();
        if (root == null) return false;
        try {
            AccessibilityNodeInfo focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
            if (focused == null) {
                focused = root.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY);
            }
            if (focused != null) {
                boolean res = focused.performAction(AccessibilityNodeInfo.ACTION_CLICK);
                focused.recycle();
                return res;
            }
        } finally {
            root.recycle();
        }
        return false;
    }

    public boolean navigateFocus(int direction) {
        AccessibilityNodeInfo root = getRootInActiveWindow();
        if (root == null) return false;
        try {
            AccessibilityNodeInfo focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
            if (focused == null) {
                focused = root.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY);
            }
            if (focused != null) {
                AccessibilityNodeInfo next = focused.focusSearch(direction);
                focused.recycle();
                if (next != null) {
                    boolean res = next.performAction(AccessibilityNodeInfo.ACTION_FOCUS);
                    next.recycle();
                    return res;
                }
            }
        } finally {
            root.recycle();
        }
        return false;
    }

    public boolean setFocusedText(String text) {
        if (text == null) return false;

        Log.i(TAG, "Attempting to inject text: \"" + text + "\"");

        // 1. Cerca il nodo nella finestra attiva principale
        AccessibilityNodeInfo root = getRootInActiveWindow();
        AccessibilityNodeInfo targetNode = null;

        if (root != null) {
            targetNode = resolveEditableNode(root);
        }

        // 2. Se non trovato nella finestra attiva, cerca in tutte le finestre visibili
        if (targetNode == null) {
            try {
                List<AccessibilityWindowInfo> windows = getWindows();
                if (windows != null) {
                    for (AccessibilityWindowInfo window : windows) {
                        AccessibilityNodeInfo wRoot = window.getRoot();
                        if (wRoot != null) {
                            targetNode = resolveEditableNode(wRoot);
                            if (targetNode != null) {
                                break;
                            }
                            wRoot.recycle();
                        }
                    }
                }
            } catch (Exception e) {
                Log.w(TAG, "Error scanning windows: " + e.getMessage());
            }
        }

        if (targetNode == null) {
            Log.w(TAG, "No editable or focused search field found on screen");
            if (root != null) root.recycle();
            return false;
        }

        // Protezione sicurezza: MAI interagire con campi password
        if (targetNode.isPassword()) {
            Log.w(TAG, "Target node is a password field. Text injection blocked for security.");
            targetNode.recycle();
            if (root != null) root.recycle();
            return false;
        }

        boolean success = false;
        try {
            // Se il nodo non ha ancora il focus, richiedilo esplicitamente
            if (!targetNode.isFocused()) {
                targetNode.performAction(AccessibilityNodeInfo.ACTION_FOCUS);
                targetNode.performAction(AccessibilityNodeInfo.ACTION_CLICK);
            }

            // Metodo A: ACTION_SET_TEXT (Standard Android)
            Bundle args = new Bundle();
            args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text);
            success = targetNode.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args);
            Log.i(TAG, "ACTION_SET_TEXT result: " + success + " on node: " + targetNode.getClassName());

            // Metodo B: Fallback Clipboard + ACTION_PASTE (per Leanback StreamingTextView)
            if (!success) {
                ClipboardManager clipboard = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
                if (clipboard != null) {
                    ClipData clip = ClipData.newPlainText("akai_remote_text", text);
                    clipboard.setPrimaryClip(clip);
                    success = targetNode.performAction(AccessibilityNodeInfo.ACTION_PASTE);
                    Log.i(TAG, "ACTION_PASTE fallback result: " + success);
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "Error setting text on target node: " + e.getMessage());
        } finally {
            targetNode.recycle();
            if (root != null) root.recycle();
        }

        return success;
    }

    private AccessibilityNodeInfo resolveEditableNode(AccessibilityNodeInfo root) {
        if (root == null) return null;

        // Check 1: FOCUS_INPUT
        AccessibilityNodeInfo focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
        if (focused != null && isSuitableEditor(focused)) {
            Log.i(TAG, "Found target via FOCUS_INPUT: " + focused.getClassName());
            return focused;
        }
        if (focused != null) focused.recycle();

        // Check 2: FOCUS_ACCESSIBILITY
        AccessibilityNodeInfo aFocused = root.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY);
        if (aFocused != null && isSuitableEditor(aFocused)) {
            Log.i(TAG, "Found target via FOCUS_ACCESSIBILITY: " + aFocused.getClassName());
            return aFocused;
        }
        if (aFocused != null) aFocused.recycle();

        // Check 3: Visita ricorsiva dell'albero (trova nodi Leanback e campi con focus)
        return findFirstEditableInHierarchy(root);
    }

    private AccessibilityNodeInfo findFirstEditableInHierarchy(AccessibilityNodeInfo node) {
        if (node == null) return null;

        if (isSuitableEditor(node)) {
            // Se il nodo è un editor valido ed ha focus, è il candidato ideale
            if (node.isFocused()) {
                Log.i(TAG, "Found focused editor node: " + node.getClassName() + " (id=" + node.getViewIdResourceName() + ")");
                return AccessibilityNodeInfo.obtain(node);
            }
        }

        int childCount = node.getChildCount();
        for (int i = 0; i < childCount; i++) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child != null) {
                AccessibilityNodeInfo result = findFirstEditableInHierarchy(child);
                child.recycle();
                if (result != null) {
                    return result;
                }
            }
        }

        // Se nessun nodo con focus è stato trovato, verifica se il nodo stesso è un editor Leanback
        if (isSuitableEditor(node)) {
            Log.i(TAG, "Found unfocused editor node candidate: " + node.getClassName() + " (id=" + node.getViewIdResourceName() + ")");
            return AccessibilityNodeInfo.obtain(node);
        }

        return null;
    }

    private boolean isSuitableEditor(AccessibilityNodeInfo node) {
        if (node == null) return false;
        if (node.isPassword()) return false;

        if (node.isEditable()) return true;

        CharSequence className = node.getClassName();
        if (className != null) {
            String cName = className.toString();
            if (cName.contains("StreamingTextView") || cName.contains("EditText") || cName.contains("SearchEditText")) {
                return true;
            }
        }

        CharSequence resId = node.getViewIdResourceName();
        if (resId != null) {
            String rName = resId.toString().toLowerCase();
            if (rName.contains("search_text_editor") || rName.contains("search_src_text") || rName.contains("query") || rName.contains("search_bar")) {
                return true;
            }
        }

        return false;
    }
}
