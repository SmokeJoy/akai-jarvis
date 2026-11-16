package android.view.accessibility;

import android.graphics.Rect;

public class AccessibilityNodeInfo {
    public CharSequence getPackageName() { return null; }
    public CharSequence getClassName() { return null; }
    public CharSequence getText() { return null; }
    public CharSequence getContentDescription() { return null; }
    public String getViewIdResourceName() { return null; }
    public boolean isClickable() { return false; }
    public boolean isFocused() { return false; }
    public boolean isPassword() { return false; }
    public void getBoundsInScreen(Rect outBounds) {}
    public int getChildCount() { return 0; }
    public AccessibilityNodeInfo getChild(int index) { return null; }
    public void recycle() {}
}
