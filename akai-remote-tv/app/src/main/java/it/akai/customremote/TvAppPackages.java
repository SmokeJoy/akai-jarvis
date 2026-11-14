package it.akai.customremote;

import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

/**
 * TvAppPackages: Identificativi di package censiti ufficialmente tramite
 * inventario hardware ADB (read-only) della Smart TV AKAI.
 *
 * Utilizzato da TvController, launcher shortcuts e suite di test per garantire
 * corrispondenza esatta 1:1 con i componenti installati a bordo.
 */
public final class TvAppPackages {
    private TvAppPackages() {}

    // Package censiti e verificati sulla Smart TV AKAI
    public static final String PKG_YOUTUBE = "com.google.android.youtube.tv";
    public static final String PKG_NETFLIX = "com.netflix.ninja";
    public static final String PKG_PRIME = "com.amazon.amazonvideo.livingroom";
    public static final String PKG_PLAYSTORE = "com.android.vending";
    public static final String PKG_RAIPLAY = "it.rainet.androidtv";
    public static final String PKG_MEDIASET = "it.mediaset.infinitytv";

    // Browser TV Bro (target Fase 2 - non ancora installato sul dispositivo)
    public static final String PKG_BROWSER_TVBRO = "com.phlox.tvwebbrowser";

    // Launcher custom
    public static final String PKG_HOME_V8 = "it.akai.customhome.v8";
    public static final String PKG_HOME_V7 = "it.akai.customhome";

    // Insieme immutabile dei package censiti effettivamente presenti a bordo TV
    public static final Set<String> CENSUSED_INSTALLED_PACKAGES = Collections.unmodifiableSet(
        new HashSet<>(Arrays.asList(
            PKG_YOUTUBE,
            PKG_NETFLIX,
            PKG_PRIME,
            PKG_PLAYSTORE,
            PKG_RAIPLAY,
            PKG_MEDIASET,
            PKG_HOME_V8,
            PKG_HOME_V7
        ))
    );

    /**
     * Verifica se un package risulta presente nell'inventario hardware reale della TV.
     */
    public static boolean isCensusedInstalled(String pkg) {
        return pkg != null && CENSUSED_INSTALLED_PACKAGES.contains(pkg);
    }
}
