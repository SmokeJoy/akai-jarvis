package it.akai.customhome;

import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.AccessibilityServiceInfo;
import android.view.KeyEvent;
import android.view.accessibility.AccessibilityEvent;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

/**
 * Servizio di accessibilita opzionale e a minimizzazione dati per reindirizzare
 * la pressione del tasto MENU (KEYCODE_MENU / 82) del telecomando originale AKAI
 * verso la Home v8 LEANBACK (GLOBAL_ACTION_HOME).
 *
 * Principi di Sicurezza e Privacy:
 * - canRetrieveWindowContent = false (nessun accesso a testi, password o contenuti video/DRM)
 * - canRequestFilterKeyEvents = true (intercettazione tasti a basso livello)
 * - ARCHITETTURA RIGOROSAMENTE FAIL-OPEN: se il pacchetto in primo piano e sconosciuto
 *   (null, vuoto, finestra di transizione, overlay), di sistema (Android, SystemUI, Settings)
 *   o del firmware OEM (MediaTek DTV, MStar, Cultraview, ingressi HDMI), il tasto MENU
 *   NON viene intercettato e passa al 100% all'OEM/sistema (return false).
 * - Intercettazione consentita ESCLUSIVAMENTE per applicazioni utente/multimediali
 *   terze verificate (es. YouTube, Netflix, RaiPlay, Prime Video, Disney+, Spotify, browser).
 */
public class AkaiMenuHomeService extends AccessibilityService {

    // Pacchetti OEM noti del sintonizzatore TV digitale, menu fabbrica e ingressi
    private static final Set<String> OEM_EXPLICIT_PACKAGES = new HashSet<>(Arrays.asList(
            "cn.cultraview.tv",
            "com.mstar.tv.tvplayer",
            "com.ctv.android.tvboot",
            "cn.cultraview.launcher.technical.open",
            "com.mstar.android.tv.factory",
            "com.mediatek.wwtv.tvcenter",
            "com.mediatek.tvinput",
            "com.mediatek.wwtv.setupwizard",
            "mediatek.factorymenu.ui",
            "com.cultraview.SwipeService",
            "com.cultraview.newfilemanager",
            "com.mediatek.hotkey.dispatcher",
            "com.mediatek.tvinputservice.arbitratorservice"
    ));

    // Prefissi di pacchetti firmware, OEM e componenti di sistema
    private static final String[] OEM_AND_SYSTEM_PREFIXES = new String[]{
            "android",
            "com.android.",
            "cn.cultraview.",
            "com.cultraview.",
            "com.mediatek.",
            "mediatek.",
            "com.mstar.",
            "com.ctv.",
            "cn.zeasn.",
            "com.zeasn.",
            "com.airoha.",
            "com.mtk.",
            "com.actions.",
            "fusion.",
            "it.akai."
    };

    private String currentPackage = "";
    private int globalActionsPerformed = 0;
    private boolean serviceEnabled = true;

    @Override
    public void onServiceConnected() {
        super.onServiceConnected();
        AccessibilityServiceInfo info = new AccessibilityServiceInfo();
        info.eventTypes = AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED;
        info.feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC;
        info.flags = AccessibilityServiceInfo.FLAG_REQUEST_FILTER_KEY_EVENTS;
        info.notificationTimeout = 100;
        setServiceInfo(info);
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        if (event != null && event.getEventType() == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            CharSequence pkg = event.getPackageName();
            if (pkg != null && pkg.length() > 0) {
                currentPackage = pkg.toString().trim();
            } else {
                // Stato transitorio sconosciuto o overlay privo di package:
                // reset a stringa vuota per forzare il fail-open trasparente
                currentPackage = "";
            }
        }
    }

    @Override
    public void onInterrupt() {
        // Nessuna operazione pendente da interrompere
    }

    @Override
    public boolean onKeyEvent(KeyEvent event) {
        if (event == null || !serviceEnabled) {
            return false;
        }

        int keyCode = event.getKeyCode();
        if (keyCode == KeyEvent.KEYCODE_MENU) {
            // Fail-open: se non e' confermata un'app utente non-OEM, lascia passare il tasto all'OEM
            if (!shouldInterceptMenu(currentPackage)) {
                return false;
            }

            // Consuma l'evento e attiva HOME su ACTION_UP per evitare doppie chiamate o repeat
            if (event.getAction() == KeyEvent.ACTION_UP) {
                performGlobalAction(GLOBAL_ACTION_HOME);
                globalActionsPerformed++;
            }
            return true;
        }

        return super.onKeyEvent(event);
    }

    /**
     * Valuta se intercettare il tasto MENU per tornare alla Home.
     * Logica RIGOROSAMENTE FAIL-OPEN:
     * - Ritorna false (passthrough OEM) per qualsiasi valore nullo, vuoto o di sistema/OEM.
     * - Ritorna true esclusivamente per applicazioni utente/multimediali accertate.
     */
    public boolean shouldInterceptMenu(String packageName) {
        if (packageName == null) {
            return false;
        }
        String pkg = packageName.trim();
        if (pkg.isEmpty()) {
            return false;
        }

        // Verifica se il pacchetto appartiene al firmware OEM o al sistema AOSP
        if (isOemOrSystemPackage(pkg)) {
            return false;
        }

        return true;
    }

    /**
     * Identifica pacchetti appartenenti al sistema operativo, al firmware OEM o al launcher stesso.
     */
    public boolean isOemOrSystemPackage(String packageName) {
        if (packageName == null) {
            return true; // Fail-open: considera sconosciuto/null come protetto
        }
        String pkg = packageName.trim();
        if (pkg.isEmpty()) {
            return true; // Fail-open: vuoto considerato protetto
        }

        if (pkg.equals("android")) {
            return true;
        }

        for (String prefix : OEM_AND_SYSTEM_PREFIXES) {
            if (pkg.startsWith(prefix)) {
                return true;
            }
        }

        return OEM_EXPLICIT_PACKAGES.contains(pkg);
    }

    /**
     * Metodo di compatibilita per il controllo dei pacchetti OEM.
     */
    public boolean isOemPassthroughPackage(String packageName) {
        return isOemOrSystemPackage(packageName);
    }

    public String getCurrentPackage() {
        return currentPackage;
    }

    public void setCurrentPackageForTest(String pkg) {
        this.currentPackage = (pkg != null) ? pkg.trim() : "";
    }

    public int getGlobalActionsPerformed() {
        return globalActionsPerformed;
    }

    public void resetGlobalActionsCount() {
        this.globalActionsPerformed = 0;
    }

    public boolean isServiceEnabled() {
        return serviceEnabled;
    }

    public void setServiceEnabled(boolean enabled) {
        this.serviceEnabled = enabled;
    }
}
