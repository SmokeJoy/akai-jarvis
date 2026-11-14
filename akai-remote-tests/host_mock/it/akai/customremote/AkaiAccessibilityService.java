package it.akai.customremote;

import android.content.Context;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;
import java.util.List;

public class AkaiAccessibilityService {
    public static AkaiAccessibilityService getInstance() { return null; }
    public Context getApplicationContext() { return null; }
    public AccessibilityNodeInfo getRootInActiveWindow() { return null; }
    public List<AccessibilityWindowInfo> getWindows() { return null; }
}
