package android.content.pm;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

public class PackageManager {
    // Installed packages for host tests only (no external Android runtime).
    private final Set<String> installed = new LinkedHashSet<>(Arrays.asList(
            "com.google.android.youtube.tv",
            "com.android.tv.settings",
            "it.mediaset.infinitytv",
            "org.example.thirdparty",
            "org.example.leanbackonly",
            "org.example.duplicateone",
            "org.example.duplicatetwo"
    ));

    public List<ApplicationInfo> getInstalledApplications(int flags) {
        List<ApplicationInfo> out = new ArrayList<>();
        for (String pkg : installed) {
            out.add(new ApplicationInfo(pkg));
        }
        return out;
    }

    public Object getLaunchIntentForPackage(String pkg) {
        return installed.contains(pkg) && !"org.example.leanbackonly".equals(pkg) ? new Object() : null;
    }

    public Object getLeanbackLaunchIntentForPackage(String pkg) {
        return installed.contains(pkg) ? new Object() : null;
    }

    public CharSequence getApplicationLabel(ApplicationInfo app) {
        if (app == null || app.packageName == null) return "";
        switch (app.packageName) {
            case "org.example.thirdparty": return "Nova Player";
            case "org.example.leanbackonly": return "Leanback Gallery";
            case "org.example.duplicateone":
            case "org.example.duplicatetwo": return "App Duplicata";
            case "com.google.android.youtube.tv": return "YouTube";
            case "it.mediaset.infinitytv": return "Mediaset Infinity";
            case "com.android.tv.settings": return "Impostazioni";
            default: return app.packageName;
        }
    }
}
