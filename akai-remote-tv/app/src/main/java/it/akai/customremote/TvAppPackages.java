package it.akai.customremote;

import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

/**
 * TvAppPackages: Identificativi di package censiti ufficialmente tramite
 * inventario hardware ADB (read-only) della Smart TV AKAI.
 *
 * Separa rigorosamente i package conosciuti dal catalogo/controller (KNOWN_PACKAGE_IDS)
 * dai soli package la cui presenza fisica è stata accertata all'audit hardware TV (INSTALLED_AT_AUDIT).
 */
public final class TvAppPackages {
    private TvAppPackages() {}

    // Identificativi noti di sistema e streaming
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

    // Tutti gli ID noti e gestiti dal controller
    public static final Set<String> KNOWN_PACKAGE_IDS = Collections.unmodifiableSet(
        new HashSet<>(Arrays.asList(
            PKG_YOUTUBE,
            PKG_NETFLIX,
            PKG_PRIME,
            PKG_PLAYSTORE,
            PKG_RAIPLAY,
            PKG_MEDIASET,
            PKG_BROWSER_TVBRO,
            PKG_HOME_V8,
            PKG_HOME_V7
        ))
    );

    // Solo i package accertati presenti a bordo TV all'audit hardware (#6728868316):
    // YouTube TV, Play Store, RaiPlay, Mediaset Infinity, Home v8 e fallback v7.
    // Netflix, Prime Video e TV Bro erano assenti all'audit.
    public static final Set<String> INSTALLED_AT_AUDIT = Collections.unmodifiableSet(
        new HashSet<>(Arrays.asList(
            PKG_YOUTUBE,
            PKG_PLAYSTORE,
            PKG_RAIPLAY,
            PKG_MEDIASET,
            PKG_HOME_V8,
            PKG_HOME_V7
        ))
    );

    // Retrocompatibilità per test preesistenti
    public static final Set<String> CENSUSED_INSTALLED_PACKAGES = INSTALLED_AT_AUDIT;

    public static boolean isKnownPackage(String pkg) {
        return pkg != null && KNOWN_PACKAGE_IDS.contains(pkg);
    }

    public static boolean isInstalledAtAudit(String pkg) {
        return pkg != null && INSTALLED_AT_AUDIT.contains(pkg);
    }

    public static boolean isCensusedInstalled(String pkg) {
        return isInstalledAtAudit(pkg);
    }
}
