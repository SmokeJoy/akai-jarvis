package android.accessibilityservice;

public class AccessibilityServiceInfo {
    public static final int FEEDBACK_GENERIC = 0x00000010;
    public static final int FLAG_REQUEST_FILTER_KEY_EVENTS = 0x00000020;
    public static final int CAPABILITY_CAN_REQUEST_FILTER_KEY_EVENTS = 0x00000008;

    public int eventTypes;
    public int feedbackType;
    public int flags;
    public long notificationTimeout;
}
