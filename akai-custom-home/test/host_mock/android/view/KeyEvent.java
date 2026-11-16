package android.view;

public class KeyEvent {
    public static final int ACTION_DOWN = 0;
    public static final int ACTION_UP = 1;

    public static final int KEYCODE_UNKNOWN = 0;
    public static final int KEYCODE_BACK = 4;
    public static final int KEYCODE_DPAD_UP = 19;
    public static final int KEYCODE_DPAD_DOWN = 20;
    public static final int KEYCODE_DPAD_LEFT = 21;
    public static final int KEYCODE_DPAD_RIGHT = 22;
    public static final int KEYCODE_DPAD_CENTER = 23;
    public static final int KEYCODE_VOLUME_UP = 24;
    public static final int KEYCODE_ENTER = 66;
    public static final int KEYCODE_MENU = 82;

    private final int action;
    private final int keyCode;
    private final int repeatCount;
    private boolean longPress;
    private boolean canceled;
    private boolean tracking;

    public KeyEvent(int action, int keyCode) {
        this(action, keyCode, 0, false, false);
    }

    public KeyEvent(int action, int keyCode, int repeatCount) {
        this(action, keyCode, repeatCount, false, false);
    }

    public KeyEvent(int action, int keyCode, int repeatCount, boolean longPress, boolean canceled) {
        this.action = action;
        this.keyCode = keyCode;
        this.repeatCount = repeatCount;
        this.longPress = longPress;
        this.canceled = canceled;
    }

    public int getAction() { return action; }
    public int getKeyCode() { return keyCode; }
    public int getRepeatCount() { return repeatCount; }
    public boolean isLongPress() { return longPress; }
    public boolean isCanceled() { return canceled; }

    public void setLongPress(boolean lp) { this.longPress = lp; }
    public void setCanceled(boolean c) { this.canceled = c; }
    public void startTracking() { this.tracking = true; }
    public boolean isTracking() { return tracking; }
}
