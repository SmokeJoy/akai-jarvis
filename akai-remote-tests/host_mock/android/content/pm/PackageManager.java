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
            "org.example.thirdparty"
    ));

    public List<ApplicationInfo> getInstalledApplications(int flags) {
        List<ApplicationInfo> out = new ArrayList<>();
        for (String pkg : installed) {
            out.add(new ApplicationInfo(pkg));
        }
        return out;
    }

    public Object getLaunchIntentForPackage(String pkg) {
        return installed.contains(pkg) ? new Object() : null;
    }
}
