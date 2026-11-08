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

    // Allowlist rigorosa delle sole applicazioni utente / streaming verificate
    // su cui il tasto MENU viene reindirizzato verso la Home v8.
    // Qualsiasi pacchetto non presente in questa lista passa all'OEM (Strict Fail-Open).
    private static final Set<String> VERIFIED_USER_APP_PACKAGES = new HashSet<>(Arrays.asList(
            "com.google.android.youtube.tv",
            "com.google.android.youtube",
            "com.netflix.ninja",
            "it.rainet.androidtv",
            "it.rainet.raiplay",
            "it.mediaset.vod",
            "com.disney.disneyplus",
            "com.amazon.amazonvideo.livingroom",
            "com.spotify.tv.android",
            "org.videolan.vlc",
            "org.xbmc.kodi",
            "cm.aptoide.pt",
            "com.phlox.tvwebbrowser",
            "org.mozilla.firefox",
            "tv.pluto.android",
            "com.dazn",
            "com.discovery.discoveryplus.androidtv",
            "com.apple.atve.androidtv.appletv",
            "com.tim.timvision",
            "com.nowtv.it"
    ));

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
            // Fail-open: se non e' confermata un'app utente verificata in allowlist,
            // lascia passare il tasto all'OEM (return false)
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
     * Valuta se intercettare il tasto MENU per tornare alla Home v8.
     * LOGICA RIGOROSAMENTE BASATA SU ALLOWLIST (FAIL-OPEN ASSOLUTO):
     * - Restituisce true ESCLUSIVAMENTE per le applicazioni utente/streaming esplicitamente verificate.
     * - Restituisce false per qualsiasi pacchetto sconosciuto (es. com.vendor.unknownmenu),
     *   overlay terzi (es. com.example.overlay), finestre di sistema, firmware OEM, DTV o ingressi HDMI.
     */
    public boolean shouldInterceptMenu(String packageName) {
        if (packageName == null) {
            return false;
        }
        String pkg = packageName.trim();
        if (pkg.isEmpty()) {
            return false;
        }

        // 1. Controllo Allowlist: se non e' un'app utente verificata, FAIL-OPEN (lascia passare al 100%)
        if (!VERIFIED_USER_APP_PACKAGES.contains(pkg)) {
            return false;
        }

        // 2. Controllo di sicurezza aggiuntivo contro collisioni con firmware OEM o sistema
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
     * Consente la registrazione dinamica di un'app utente verificata.
     */
    public static boolean isVerifiedUserApp(String packageName) {
        if (packageName == null) return false;
        return VERIFIED_USER_APP_PACKAGES.contains(packageName.trim());
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
