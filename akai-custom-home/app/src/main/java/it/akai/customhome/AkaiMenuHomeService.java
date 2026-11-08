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
 * Privacy e Sicurezza:
 * - canRetrieveWindowContent = false (nessun accesso a testi, password o contenuti video/DRM)
 * - canRequestFilterKeyEvents = true (intercettazione tasti a basso livello)
 * - Filtro anti-collisione OEM: non intercetta il tasto MENU quando l'utente si trova
 *   nel sintonizzatore TV digitale terrestre (DTV) o nelle impostazioni di fabbrica.
 */
public class AkaiMenuHomeService extends AccessibilityService {

    // Pacchetti OEM protetti in cui il tasto MENU deve funzionare normalmente
    private static final Set<String> OEM_PASSTHROUGH_PACKAGES = new HashSet<>(Arrays.asList(
            "cn.cultraview.tv",
            "com.mstar.tv.tvplayer",
            "com.ctv.android.tvboot",
            "cn.cultraview.launcher.technical.open",
            "com.mstar.android.tv.factory"
    ));

    private String currentPackage = "";
    private int globalActionsPerformed = 0;

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
            if (pkg != null) {
                currentPackage = pkg.toString();
            }
        }
    }

    @Override
    public void onInterrupt() {
        // Nessuna operazione di interruzione richiesta
    }

    @Override
    public boolean onKeyEvent(KeyEvent event) {
        if (event == null) {
            return false;
        }

        int keyCode = event.getKeyCode();
        if (keyCode == KeyEvent.KEYCODE_MENU) {
            // Verifica se l'app in primo piano e una schermata OEM protetta
            if (isOemPassthroughPackage(currentPackage)) {
                // Lascia passare il tasto MENU all'applicazione OEM
                return false;
            }

            // Consuma l'evento e richiama la HOME su ACTION_UP per evitare doppie attivazioni
            if (event.getAction() == KeyEvent.ACTION_UP) {
                performGlobalAction(GLOBAL_ACTION_HOME);
                globalActionsPerformed++;
            }
            return true;
        }

        return super.onKeyEvent(event);
    }

    public boolean isOemPassthroughPackage(String packageName) {
        if (packageName == null || packageName.isEmpty()) {
            return false;
        }
        return OEM_PASSTHROUGH_PACKAGES.contains(packageName);
    }

    public String getCurrentPackage() {
        return currentPackage;
    }

    public void setCurrentPackageForTest(String pkg) {
        this.currentPackage = pkg;
    }

    public int getGlobalActionsPerformed() {
        return globalActionsPerformed;
    }

    public void resetGlobalActionsCount() {
        this.globalActionsPerformed = 0;
    }
}
