package android.accessibilityservice;

import android.content.Context;
import android.view.KeyEvent;
import android.view.accessibility.AccessibilityEvent;

public abstract class AccessibilityService extends Context {
    public static final int GLOBAL_ACTION_BACK = 1;
    public static final int GLOBAL_ACTION_HOME = 2;
    public static final int GLOBAL_ACTION_RECENTS = 3;
    public static final int GLOBAL_ACTION_NOTIFICATIONS = 4;
    public static final int GLOBAL_ACTION_QUICK_SETTINGS = 5;
    public static final int GLOBAL_ACTION_POWER_DIALOG = 6;

    private AccessibilityServiceInfo serviceInfo;
    private int lastGlobalAction = 0;

    public void setServiceInfo(AccessibilityServiceInfo info) {
        this.serviceInfo = info;
    }

    public AccessibilityServiceInfo getServiceInfo() {
        return serviceInfo;
    }

    public boolean performGlobalAction(int action) {
        this.lastGlobalAction = action;
        return true;
    }

    public int getLastGlobalAction() {
        return lastGlobalAction;
    }

    public void onServiceConnected() {}
    public abstract void onAccessibilityEvent(AccessibilityEvent event);
    public abstract void onInterrupt();

    public boolean onKeyEvent(KeyEvent event) {
        return false;
    }
}
