package android.view.accessibility;

public class AccessibilityEvent {
    public static final int TYPE_WINDOW_STATE_CHANGED = 32;

    private int eventType;
    private CharSequence packageName;

    public AccessibilityEvent(int eventType, CharSequence packageName) {
        this.eventType = eventType;
        this.packageName = packageName;
    }

    public int getEventType() {
        return eventType;
    }

    public CharSequence getPackageName() {
        return packageName;
    }
}
